#!/usr/bin/env bash
# Run inference for ONE (task, model, replicate). Idempotent and resumable.
#
#   ./run_one.sh <task> <model> <replicate> [T|F] [--gpu N]
#
# It (all under the machine-wide GPU lock, so two runs never double-process):
#   1. derives ALREADY-DONE IDs from the outDir's output_*.txt: the ID is read as the LAST tab field
#      of each row (or the one before a NO_GRAMMAR sentinel) -- exact, since the ID never has a tab.
#   2. filters the task's inputs_<r>.txt / IDs_<r>.txt down to the not-yet-done IDs.
#   3. records the exact command in invocation_<datetime>.txt, then runs llama-data-extraction on
#      just the remaining IDs (one process; placement is whatever the row's args say).
# Re-running after a crash/GPU-maintenance kill recomputes "remaining" and continues; if nothing
# remains it exits immediately.
#
# The 4th arg selects the retry VARIANT via the config key: F (default, or 3 args) = the normal row;
# T = a separate jobs.conf row (same task/model/replicate, retry=T) that reprocesses ONLY the
# error-only IDs, with whatever settings that row carries. Missing row for the exact (task, model,
# replicate, retry) key fails loudly. Successful IDs are left untouched.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ $# -ge 3 ] || die "usage: $0 <task> <model> <replicate> [T|F] [--gpu N]"
TASK="$1"; MODEL="$2"; REP="$3"; shift 3
RKEY="F"; GPUCARD=""
# Optional 4th POSITIONAL arg: the retry selector (T|F). Present only if it is not a flag.
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then RKEY="$1"; shift; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --gpu) GPUCARD="${2:-}"; shift ;;            # pin to ONE card (per-card worker mode)
        *)     die "unknown arg: $1" ;;
    esac; shift
done
# Canonicalize the retry selector -> T/F, and set RETRY (T = reprocess only this job's error IDs).
case "$RKEY" in [Tt]*) RKEY=T; RETRY=1 ;; *) RKEY=F; RETRY=0 ;; esac

# --- resolve the (task, model, replicate, retry) row from config -----------
gguf="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 5)" || die "no config row for (task=$TASK, model=$MODEL, replicate=$REP, retry=$RKEY) in $JOBS_CONF"
prompt_dir="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 6)"
promptfmt="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 7)"
grammar_name="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 8)"
input_dir="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 9)"
jargs="$(job_field "$TASK" "$MODEL" "$REP" "$RKEY" 10)"
for f in gguf:"$gguf" prompt_dir:"$prompt_dir" promptFormat:"$promptfmt" \
         grammar:"$grammar_name" input_dir:"$input_dir" args:"$jargs"; do
    [ -n "${f#*:}" ] || die "(task=$TASK, model=$MODEL, retry=$RKEY): ${f%%:*} is empty in $JOBS_CONF"
done

grammar="$GRAMMAR_DIR/$grammar_name"
sysprompt="$SYSPROMPT_DIR/$prompt_dir/$TASK.txt"
input="$input_dir/inputs_${REP}.txt"
idfile="$input_dir/IDs_${REP}.txt"
outdir="$RESULTS_ROOT/$TASK/$MODEL/rep${REP}"

# --- preflight (fail loudly before touching the GPU) -----------------------
[ -x "$LLAMA_BIN" ] || die "llama-data-extraction not found/executable: $LLAMA_BIN"
[ -f "$gguf" ]      || die "gguf not found: $gguf"
[ -f "$grammar" ]   || die "grammar not found: $grammar"
[ -f "$sysprompt" ] || die "system prompt not found: $sysprompt (task=$TASK prompt_dir=$prompt_dir)"
[ -f "$input" ]     || die "input not found: $input"
[ -f "$idfile" ]    || die "ID file not found: $idfile"
mkdir -p "$outdir"
work="$outdir/.work"; mkdir -p "$work"

# Single card is the default -- no model here needs both cards. `-sm none` prevents llama.cpp's
# layer-split across cards; the card is the per-card worker's (--gpu N) or card 0 otherwise. In
# per-card mode we also take a PER-CARD lock so the other card can run a different job concurrently.
PLACE=( -sm none -mg "${GPUCARD:-0}" )
[ -n "$GPUCARD" ] && GPU_LOCK="$COORD_DIR/.gpu.lock.$GPUCARD"

# Append one llama-data-extraction command's `printf %q` line to the invocation record.
_record() { printf '%q ' "$@" >> "$INVOC"; printf '\n' >> "$INVOC"; }

do_job() {
    # 1. already-done IDs.
    shopt -s nullglob; local outs=( "$outdir"/output_*.txt ); shopt -u nullglob
    if [ "${#outs[@]}" -gt 0 ]; then
        # The ID is the LAST tab field, except a NO_GRAMMAR lenient row appends the sentinel AFTER
        # the ID (<response>\t<ID>\tNO_GRAMMAR) so then it's the field before it. Reading from the
        # right is exact: the ID never contains a tab, and only NO_GRAMMAR responses can, and those
        # always end with the sentinel -- so $(NF-1) is still the ID.
        awk -F'\t' -v retry="$RETRY" '
            FNR==NR { ids[$0]=1; next }
            { iserr = ($1=="Error")
              id = ($NF=="NO_GRAMMAR") ? $(NF-1) : $NF
              if (id in ids) { seen[id]=1; if (!iserr) succ[id]=1 } }
            END { if (retry) { for (k in succ) print k } else { for (k in seen) print k } }
        ' "$idfile" "${outs[@]}" > "$work/done.ids"
    else
        : > "$work/done.ids"
    fi

    # 2. filter to remaining (each ID line paired with its aligned input line).
    : > "$work/remaining.ids"; : > "$work/remaining.input"
    awk -v donef="$work/done.ids" -v inf="$input" \
        -v remids="$work/remaining.ids" -v remin="$work/remaining.input" '
        BEGIN { while ((getline x < donef) > 0) done[x]=1 }
        { if ((getline inp < inf) <= 0) inp="";
          if (!($0 in done)) { print $0 > remids; print inp > remin } }
    ' "$idfile"

    local n_total n_remaining
    n_total="$(wc -l < "$idfile" | tr -d ' ')"
    n_remaining="$(wc -l < "$work/remaining.ids" | tr -d ' ')"
    if [ "$n_remaining" -eq 0 ]; then
        log "[$TASK/$MODEL/rep$REP] nothing to do: all $n_total IDs already done"
        return 100   # distinct code so a per-card worker can tell "done" from "did work"
    fi
    log "[$TASK/$MODEL/rep$REP] $n_remaining of $n_total IDs remaining$([ "$RETRY" = 1 ] && echo ' (retry-errors)')"

    # invocation record ("what we ran"); tool records resolved sampler values into metadata_*.txt.
    local ts; ts="$(date '+%Y%m%d_%H%M%S')_$$"
    INVOC="$outdir/invocation_${ts}.txt"
    { printf '# %s\n# task=%s model=%s replicate=%s  (%s of %s IDs this run)\n' \
             "$(date)" "$TASK" "$MODEL" "$REP" "$n_remaining" "$n_total"; } > "$INVOC"

    # One process on ONE card. PLACE (-sm none -mg CARD) is appended last so it sets single-card
    # placement -- the per-card worker's card via --gpu, or card 0 when run by hand -- overriding args.
    # shellcheck disable=SC2206
    local cmd=( "$LLAMA_BIN" -m "$gguf" -sysf "$sysprompt" --promptFormat "$promptfmt"
        --grammar-file "$grammar" --file "$work/remaining.input" --IDfile "$work/remaining.ids"
        --outDir "$outdir" --sequences "$n_remaining" $jargs ${PLACE[@]+"${PLACE[@]}"} )
    _record "${cmd[@]}"
    log "[$TASK/$MODEL/rep$REP] launching -> $outdir"
    "${cmd[@]}" </dev/null; local rc=$?
    [ "$rc" -eq 0 ] && log "[$TASK/$MODEL/rep$REP] batch done (exit 0)" \
                    || warn "[$TASK/$MODEL/rep$REP] exited $rc (finished IDs kept; resumes next run)"
    return "$rc"
}

log "[$TASK/$MODEL/rep$REP] waiting for GPU lock ..."
with_gpu_lock do_job
exit $?
