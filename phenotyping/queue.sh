#!/usr/bin/env bash
# Dead-simple, crash-proof inference queue.
#
# A JOB is one line "<task> <model> <replicate>" in a static manifest. Every job is idempotent and
# resumable (run_one.sh derives remaining work from the results dir), so the queue is just the
# manifest plus worker(s) that walk it. Re-running a worker -- by hand or from cron after GPU
# maintenance -- resumes from disk. No markers, no requeue bookkeeping.
#
# Every job runs on ONE card. One worker is pinned per card; the workers run DIFFERENT jobs at once
# (both GPUs busy), and a freed card immediately claims the next unclaimed job. Cards default to
# "0,1" (override with the CARDS env var or --cards, e.g. --cards 0 for a single-GPU box).
#
#   ./queue.sh add <task> <model> <replicate> [T|F]  append a job (retry T/F, default F; starts workers)
#   ./queue.sh add-all [--force]                   enqueue jobs.conf rows (--force: rewrite manifest to match jobs.conf, dropping stale keys)
#   ./queue.sh start [--cards 0,1]                  clear stop + launch one worker per card (default 0,1)
#   ./queue.sh stop                                stop after the current job (also blocks cron)
#   ./queue.sh kill [-y]                           IMMEDIATE stop: kill workers + inference NOW (prompts y/N; -y skips)
#   ./queue.sh reap [N]                            cron watchdog: kill stuck worker(s) if NO inference runs for N checks (default 3)
#   ./queue.sh list                                show the manifest
#   ./queue.sh errors                              report error-only IDs per job
#   ./queue.sh worker <card>                       (internal) per-card worker loop
#
# Self-resume without root -- your OWN crontab (no sudo). Use 'worker' (not 'start') so a pending
# 'stop' is respected; a worker no-ops if one is already running / everything is done. One line per card:
#   */5 * * * * /ABS/phenotyping/queue.sh worker 0  >> /ABS/phenotyping/runtime/cron.log 2>&1
#   */5 * * * * /ABS/phenotyping/queue.sh worker 1  >> /ABS/phenotyping/runtime/cron.log 2>&1
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
RUNNER="${QUEUE_RUNNER:-$DIR/run_one.sh}"

# Make dir to track the queue
QDIR="$COORD_DIR/_queue"; mkdir -p "$QDIR"
JOBS="$QDIR/jobs.txt"; STOP="$QDIR/stop"; WLOG="$QDIR/worker.log"; WLOCK="$QDIR/worker.lock"; JDIR="$QDIR/jobs.d"
touch "$JOBS"

usage() {
    grep '^#' "$DIR/queue.sh" | sed -n '3,28p' | sed 's/^# \{0,1\}//'
    exit 2
}

cmd="${1:-}"; shift || true
case "$cmd" in
    add)
        [ $# -ge 3 ] || die "usage: $0 add <task> <model> <replicate> [T|F]"
        printf '%s %s %s %s\n' "$1" "$2" "$3" "${4:-F}" >> "$JOBS"     # 4th = retry (default F)
        log "queued: $1 $2 $3 ${4:-F}"
        "$0" start
        ;;

    add-all)
        # Enqueue every job row in jobs.conf. Default: append only new keys (idempotent).
        # --force: rewrite the manifest to EXACTLY jobs.conf's current keys -- drops stale ones
        # (removed rows / changed replicates) and adds new. Args are read from jobs.conf at run
        # time, so this resyncs WHICH jobs exist, not their args, and does NOT re-run a settled
        # job (that needs a worker restart: 'stop' then 'start').
        [ -f "$JOBS_CONF" ] || die "no config file: $JOBS_CONF"
        n=0
        if [ "${1:-}" = "--force" ]; then
            tmp="$JOBS.tmp.$$"; : > "$tmp"
            while read -r t m r y; do
                [ -n "${t:-}" ] || continue
                printf '%s %s %s %s\n' "$t" "$m" "$r" "$y" >> "$tmp"; n=$((n + 1))
            done < <(job_keys)
            mv "$tmp" "$JOBS"                                   # atomic swap; safe vs a running worker
            log "add-all --force: manifest rewritten to $n job(s) from $JOBS_CONF"
        else
            while read -r t m r y; do
                [ -n "${t:-}" ] || continue
                grep -qxF "$t $m $r $y" "$JOBS" 2>/dev/null && continue
                printf '%s %s %s %s\n' "$t" "$m" "$r" "$y" >> "$JOBS"; n=$((n + 1))
            done < <(job_keys)
            log "add-all: enqueued $n new job(s) from $JOBS_CONF"
        fi
        log "run './queue.sh start' to begin (uses both cards; set CARDS (bash variable) or --cards (arg) to change)."
        "$0" list
        ;;

    start)
        rm -f "$STOP"
        cards="${CARDS:-0,1}"                       # default to both cards; CARDS env or --cards to change
        [ "${1:-}" = "--cards" ] && cards="${2:-}"
        [ -n "$cards" ] || die "no cards to start (set CARDS or pass --cards)"
        IFS=',' read -ra CARR <<< "$cards"
        for c in "${CARR[@]}"; do nohup "$DIR/queue.sh" worker "$c" >>"$WLOG" 2>&1 & done
        log "workers started for cards [$cards] (log: $WLOG)"
        ;;

    stop)
        : > "$STOP"
        log "stop flag set; workers exit after the current job and cron no-ops until 'start'."
        ;;

    kill)
        # IMMEDIATE stop: set the stop flag, then kill the worker loops and the running inference.
        # Prompts y/N first (skip with -y/--yes). In-flight patients are lost; finished IDs are on
        # disk, so jobs resume on the next 'start'. Use this instead of 'stop' when you cannot wait
        # for the current inference to finish.
        if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
            printf 'Kill ALL workers and the running inference NOW? In-flight work is lost (finished IDs kept). [y/N] '
            IFS= read -r _ans </dev/tty 2>/dev/null || _ans=""
            case "$_ans" in
                [Yy]|[Yy][Ee][Ss]) ;;
                *) log "kill: aborted, nothing changed."; exit 0 ;;
            esac
        fi
        : > "$STOP"                                                       # block cron + prevent relaunch
        if pkill -f 'queue\.sh worker' 2>/dev/null; then log "kill: worker loops terminated."; else log "kill: no worker loops were running."; fi
        binname="$(basename "$LLAMA_BIN")"
        if pkill -9 -f "$binname" 2>/dev/null; then log "kill: inference ($binname) terminated."; else log "kill: no inference was running."; fi
        sleep 1
        if pgrep -f 'queue\.sh worker' >/dev/null 2>&1 || pgrep -f "$binname" >/dev/null 2>&1; then
            warn "kill: some processes are still alive:"
            { pgrep -af 'queue\.sh worker'; pgrep -af "$binname"; } 2>/dev/null >&2
        else
            log "kill: all stopped. Stop flag is set -- run './queue.sh start' to resume."
        fi
        ;;

    reap)
        # Watchdog for a WEDGED queue: if worker loop(s) are alive but NO llama-data-extraction is
        # running for N consecutive checks, a worker is stuck holding a card with nothing to show
        # for it -- kill the worker(s) so the next cron 'worker' tick starts fresh ones and reclaims
        # the card. Run from cron alongside 'worker'. N = arg 1 (default 3). The consecutive-miss
        # counter persists across cron invocations in $QDIR/reap.misses. NOTE: this is GLOBAL -- any
        # inference on any card resets it, so a card stuck while the other card runs is only reaped
        # once that other card goes idle too.
        N="${1:-3}"
        binname="$(basename "$LLAMA_BIN")"
        statef="$QDIR/reap.misses"
        if [ -f "$STOP" ]; then rm -f "$statef"; exit 0; fi                          # stop flag set -> hands off
        pgrep -f 'queue\.sh worker' >/dev/null 2>&1 || { rm -f "$statef"; exit 0; }  # no workers -> nothing to watch
        if pgrep -f "$binname" >/dev/null 2>&1; then rm -f "$statef"; exit 0; fi     # inference running -> healthy
        misses=$(( $(cat "$statef" 2>/dev/null || echo 0) + 1 ))
        echo "$misses" > "$statef"
        if [ "$misses" -ge "$N" ]; then
            warn "reap: worker(s) alive but no $binname for $misses consecutive checks -> killing worker(s) (cron restarts them)."
            pkill -f 'queue\.sh worker' 2>/dev/null; sleep 2; pkill -9 -f 'queue\.sh worker' 2>/dev/null
            rm -f "$statef"
        else
            log "reap: worker(s) alive, no $binname running ($misses/$N)."
        fi
        ;;

    list)
        echo "manifest ($JOBS):"
        [ -s "$JOBS" ] && nl -ba "$JOBS" || echo "  (empty)"
        ;;

    errors)
        # One outDir per (task,model,replicate) -- the retry (T) and normal (F) rows share it -- so
        # report each once (drop the retry field, then unique).
        while read -r t m r; do
            [ -n "${t:-}" ] || continue
            od="$RESULTS_ROOT/$t/$m/rep${r}"
            shopt -s nullglob; o=( "$od"/output_*.txt ); shopt -u nullglob
            if [ "${#o[@]}" -eq 0 ]; then echo "$t $m rep$r: (no outputs yet)"; continue; fi
            n="$(awk -F'\t' '$1=="Error"{print $2}' "${o[@]}" | sort -u | wc -l | tr -d ' ')"
            echo "$t $m rep$r: $n error-only IDs"
        done < <(awk '{print $1, $2, $3}' "$JOBS" | sort -u)
        ;;

    worker)
        # Per-card worker: pinned to CARD, runs jobs on that card, claiming each so no two cards run
        # the same job. Loops until every job is settled, so a freed card immediately grabs the next.
        CARD="${1:-}"
        [ -n "$CARD" ] || die "worker requires a card: $0 worker <N> (use start/--cards to pick cards)"
        tag="worker (card $CARD)"
        [ -f "$STOP" ] && { log "$tag: stop flag set; not starting."; exit 0; }
        if command -v flock >/dev/null 2>&1; then       # singleton per card; extra invocations just exit
            exec 9>"${WLOCK}.$CARD"
            flock -n 9 || { log "$tag: already running; exiting."; exit 0; }
        fi
        mkdir -p "$JDIR"
        log "$tag: started (pid $$)"
        # DONE is a monotonically-growing set of settled job keys. Because a settled job is never
        # rechecked, two workers can't livelock skipping each other, and the loop exits once nothing
        # is pending. A run_one call processes ALL of a job's remaining IDs, so one successful run
        # settles it; only a job busy on the OTHER card (111) stays pending, retried when it frees.
        # (This also bounds a retry job -- it reprocesses its errors once per run, never in a loop.)
        DONE=" "
        while true; do
            [ -f "$STOP" ] && { log "$tag: stop flag set; exiting."; break; }
            pending=0
            while read -r t m r y _; do
                [ -n "${t:-}" ] || continue
                [ -f "$STOP" ] && break
                y="${y:-F}"                                                          # 4th field = retry (default F)
                jkey="$(printf '%s_%s_rep%s_%s' "$t" "$m" "$r" "$y" | tr -c 'A-Za-z0-9_.-' '_')"   # F/T are distinct jobs
                case "$DONE" in *" $jkey "*) continue ;; esac
                pending=1
                # 9>&- closes the worker-singleton lock fd for run_one and the inference it spawns,
                # so a hung inference cannot keep worker.lock.<card> held after this worker exits
                # (which would make the next 'start' say "already running" with no live worker).
                with_job_lock_nb "$JDIR/$jkey.lock" "$RUNNER" "$t" "$m" "$r" "$y" --gpu "$CARD" </dev/null 9>&-
                rc=$?
                if [ "$rc" -eq 111 ]; then :                                        # busy on the other card -> retry when it frees
                else DONE="$DONE$jkey "                                             # 0 (did work), 100 (nothing to do), or error -> settled
                     [ "$rc" -ne 0 ] && [ "$rc" -ne 100 ] && warn "$tag: '$t $m rep$r $y' rc=$rc -> left for manual/cron rerun"
                fi
            done < "$JOBS"
            [ "$pending" -eq 0 ] && { log "$tag: all jobs settled; exiting."; break; }
            sleep 2
        done
        ;;

    *) usage ;;
esac
