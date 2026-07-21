#!/usr/bin/env bash
# Foolproof FIFO task queue for the phenotyping pipeline.
#
# Runs tasks ONE AT A TIME (each task already maximizes GPU use via split/dual), so the GPU is
# never contended. Enqueue as many tasks as you like; a single background worker runs them in
# order, starting the next the instant the current one finishes.
#
#   ./queue.sh add <task> --out-root DIR [flags]   enqueue ONE task (--out-root REQUIRED), e.g.
#                                       ./queue.sh add colectomy --out-root /data --slices 6
#   several at once: quote each entry, e.g.
#     ./queue.sh add "colectomy --out-root /data" "ibd --out-root /data --slices 4"
#   ./queue.sh list                     show the running task + pending queue
#   ./queue.sh stop                     stop the worker after the current task finishes
#   ./queue.sh worker                   (internal) the worker loop
#
# Foolproof properties:
#   * enqueue/dequeue and worker-singleton are guarded by a lock (flock if available, else an
#     atomic mkdir lock with dead-pid cleanup) -> no races even if you run `add` concurrently.
#   * exactly one worker ever runs (pid liveness check under the lock).
#   * if the worker/box dies mid-task, the task it was running is re-queued on restart and
#     resumes from its last .done marker (run_task.sh is itself resumable) -> nothing is lost.
#   * the worker survives terminal close (nohup).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Queue metadata is small global coordination state -> fixed in-repo location (per-task DATA
# goes to each task's required --out-root, which may differ between tasks).
QDIR="$DIR/runtime/_queue"; mkdir -p "$QDIR"
QUEUE="$QDIR/queue.txt"; RUNNING="$QDIR/running.txt"
LOCK="$QDIR/queue.lock"; WPID="$QDIR/worker.pid"; WLOG="$QDIR/worker.log"; STOP="$QDIR/stop"
RUNNER="${QUEUE_RUNNER:-$DIR/run_task.sh}"   # overridable for testing
PREP_AHEAD="${QUEUE_PREP_AHEAD:-1}"          # 1 = prep next task's pull+preprocess during current's GPU run
touch "$QUEUE" "$RUNNING"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] queue: $*"; }

# --- locking: prefer flock (auto-releases on crash); fall back to atomic mkdir ---------------
with_lock() {  # with_lock <cmd...>
    if command -v flock >/dev/null 2>&1; then
        ( exec 200>"$LOCK"; flock -x 200; "$@" )
    else
        local d="${LOCK}.d" owner
        until mkdir "$d" 2>/dev/null; do
            owner="$(cat "$d/pid" 2>/dev/null || true)"
            if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$d"; continue; fi
            sleep 0.2
        done
        echo $$ > "$d/pid"
        "$@"; local rc=$?
        rm -rf "$d"
        return $rc
    fi
}

worker_alive() { [ -s "$WPID" ] && kill -0 "$(cat "$WPID" 2>/dev/null)" 2>/dev/null; }

# --- internal helpers run UNDER the lock ----------------------------------------------------
_enqueue() { for t in "$@"; do echo "$t" >> "$QUEUE"; done; }

_start_worker_if_needed() {
    if worker_alive; then return 0; fi
    rm -f "$STOP"
    nohup "$DIR/queue.sh" worker >>"$WLOG" 2>&1 &
    echo $! > "$WPID"
}

# Peek the next task without removing it (for prep-ahead). Empty => "".
_peek_next() { [ -s "$QUEUE" ] && head -n1 "$QUEUE" || true; }

# Pop the next task (prints it, removes it from the queue, records it as running). Empty => "".
_pop_next() {
    local next=""
    if [ -s "$QUEUE" ]; then
        next="$(head -n1 "$QUEUE")"
        tail -n +2 "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    fi
    printf '%s' "$next" > "$RUNNING"
    printf '%s' "$next"
}

# On worker (re)start, re-queue any task that was mid-run (front of queue) so it resumes.
_requeue_interrupted() {
    local r; r="$(cat "$RUNNING" 2>/dev/null || true)"
    if [ -n "$r" ]; then
        { echo "$r"; cat "$QUEUE"; } > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
        : > "$RUNNING"
    fi
}

# ------------------------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
    add)
        [ $# -ge 1 ] || { echo "usage: $0 add <task> [flags] | $0 add <task1> <task2> ..."; exit 2; }
        orig="$*"   # saved for logging; the validator below consumes the positional params
        # If any arg is a flag (starts with -), the whole line is ONE "task + flags" entry
        # (e.g. `add colectomy --slices 6`). Otherwise each bare name is a separate task
        # (e.g. `add colectomy ibd crc`).
        has_flag=0; for a in "$@"; do case "$a" in -*) has_flag=1 ;; esac; done
        if [ "$has_flag" = 1 ]; then
            # Single task + flags. Validate: first arg is the task, the rest are flags/values
            # only. A second bare (task-like) argument is almost always a mistake (e.g.
            # `add colectomy --slices 6 ibd`) — catch it here with a helpful message.
            entry="$*"; tname="$1"; shift
            case "$tname" in -*) echo "queue: 'add' — first argument must be a task name, got flag '$tname'."; exit 2 ;; esac
            while [ $# -gt 0 ]; do
                case "$1" in
                    --from|--until|--slices|--out-root|--notes) shift; [ $# -gt 0 ] && shift ;;   # value-taking flag: skip flag + value
                    -*) shift ;;                                              # boolean/other flag
                    *)  echo "queue: ambiguous 'add' — flags are present, so only ONE task is allowed, but found an extra task '$1'."
                        echo "       When using flags, add tasks one at a time, e.g.:"
                        echo "         $0 add $tname --slices N"
                        echo "         $0 add $1 --slices M"
                        exit 2 ;;
                esac
            done
            case "$entry" in *--out-root*) ;; *) echo "queue: task must include --out-root DIR (missing in '$entry'). run_task.sh requires it."; exit 2 ;; esac
            with_lock _enqueue "$entry"  # single entry, args preserved
        else
            # bare names: each still needs --out-root, so each must be a quoted "task --out-root DIR"
            for t in "$@"; do
                case "$t" in *--out-root*) ;; *) echo "queue: each task must include --out-root DIR (missing in '$t'). run_task.sh requires it."; exit 2 ;; esac
            done
            with_lock _enqueue "$@"      # one entry per task
        fi
        # NOTE: do NOT requeue-interrupted here — if a worker is alive, RUNNING holds the
        # legitimately-running task. A fresh worker requeues an interrupted task on startup.
        with_lock _start_worker_if_needed
        log "enqueued: $orig"
        "$0" list
        ;;

    list)
        r="$(cat "$RUNNING" 2>/dev/null || true)"
        if worker_alive; then w="worker: running (pid $(cat "$WPID"))"; else w="worker: stopped"; fi
        echo "$w"
        [ -n "$r" ] && echo "running: $r" || echo "running: (none)"
        echo "pending:"; nl -ba "$QUEUE" 2>/dev/null | sed 's/^/  /' ; [ -s "$QUEUE" ] || echo "  (empty)"
        ;;

    stop)
        : > "$STOP"
        log "stop requested; worker will exit after the current task finishes."
        ;;

    worker)
        log "worker started (pid $$)"
        with_lock _requeue_interrupted
        while true; do
            [ -f "$STOP" ] && { log "stop flag set; exiting."; rm -f "$STOP"; break; }
            task="$(with_lock _pop_next)"
            if [ -z "$task" ]; then log "queue empty; worker exiting."; break; fi

            # Prep-ahead (depth 1): while THIS task holds the GPU, run the NEXT task's
            # pull+preprocess in the background so it can infer the instant the GPU frees.
            # Prep-ahead never touches the GPU (--until preprocess stops before infer).
            nxt=""; prep_pid=""
            if [ "$PREP_AHEAD" != "0" ]; then nxt="$(with_lock _peek_next)"; fi
            if [ -n "$nxt" ]; then
                log "prep-ahead: $nxt (pull+preprocess) while $task runs"
                # A queue entry is "task [args]" (e.g. "colectomy --slices 6"); split into words.
                read -ra na <<< "$nxt"
                ( "$RUNNER" "${na[@]}" --until preprocess ) >>"$QDIR/prep.log" 2>&1 &
                prep_pid=$!
            fi

            log "==> starting task: $task"
            read -ra ta <<< "$task"
            "$RUNNER" "${ta[@]}"; rc=$?
            log "<== finished task: $task (exit $rc)"

            # Ensure prep-ahead finished before we pop $nxt (so its prep is .done). Non-fatal.
            if [ -n "$prep_pid" ]; then wait "$prep_pid" 2>/dev/null; log "prep-ahead of $nxt finished (exit $?)"; fi

            with_lock bash -c ': > "'"$RUNNING"'"'   # clear running marker
        done
        rm -f "$WPID"
        ;;

    *)
        echo "usage: $0 {add <task...>|list|stop}"; exit 2 ;;
esac
