#!/usr/bin/env bash
# Single entrypoint for the phenotyping pipeline.
#
#   ./run_task.sh <task> [--resume|--from <step>|--slices N|--force|--dry-run|--retry-errors]
#
# Runs, for the given task: preprocess (streams from SQL + builds inputs) -> infer(pass x
# model) -> aggregate. Every step is guarded by a .done marker in runtime/<task>/, so a crash
# is recovered by re-running the same command (default behaviour == --resume).
#
#   --from <step>   clear markers from <step> onward and re-run from there
#                   (step in: preprocess infer aggregate)
#   --force         ignore all .done markers (re-run everything)
#   --dry-run       print the plan; run nothing
#   --retry-errors  re-run inference for IDs that ended as Error, then re-aggregate

set -uo pipefail   # NOT -e: per-step fault isolation is handled by run_step

# Print helpful error message if user runs with empty or unknown arguments
usage() { echo "usage: $0 <task> [--resume|--from <step>|--slices N|--force|--dry-run|--retry-errors]"; exit 2; }

# If the number of arguments is 0, return error message via usage fn above
[ $# -ge 1 ] || usage

# Assign the variable TASK to the first argument. shift makes the 2nd+ arg the 1st arg
TASK="$1"; shift

# Process the remaining args and assign the variables accordingly
FROM=""; UNTIL=""; SLICES_ARG=""; export FORCE=0 DRY_RUN=0; RETRY_ERRORS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --resume)        ;;                       # default; ";;" serves as 'break' out of case statement
        --from)          FROM="${2:-}"; shift ;;  # FROM is set to the arg after --from (or empty if none)
        --until)         UNTIL="${2:-}"; shift ;; # run through this step then stop (for prep-ahead)
        --slices)        SLICES_ARG="${2:-}"; shift ;; # partition cohort into N sliced pulls/inputs
        --force)         FORCE=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --retry-errors)  RETRY_ERRORS=1 ;;
        *) echo "unknown option: $1"; usage ;;
    esac
    shift
done

# Source lib.sh in same dir as this script by determining this script's dir (${BASH_SOURCE[0]}) AS IT WAS CALLED
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Set the task config file and error if none found
CONF="$PHENO_DIR/config/${TASK}.conf"
[ -f "$CONF" ] || die "no config for task '$TASK' ($CONF)"

# Define filenames and make directories
WORKDIR="$PHENO_DIR/runtime/$TASK"
mkdir -p "$WORKDIR/inputs" "$WORKDIR/llm_out"
export WORKDIR TASK
LOGFILE="$WORKDIR/run_$(date '+%Y%m%d_%H%M%S').log"; export LOGFILE

# Task config defines: SQL, MODELS=(...), PASSES=("name:grammar" ...), and preprocess_pass().
# shellcheck source=/dev/null
source "$CONF"
: "${SQL:?config must set SQL}"; : "${MODELS:?config must set MODELS}"; : "${PASSES:?config must set PASSES}"
declare -F preprocess_pass >/dev/null || die "config must define a preprocess_pass() function"

# Slice count: --slices arg, else the value persisted from the first run, else 1. Persisting
# keeps resumes consistent (infer must loop the same number of slices preprocess produced).
#
# The slice count partitions the WHOLE cohort, so it cannot change on a partial resume: the
# existing sliceK inputs belong to the old partition, and a new count would look for slice dirs
# that don't exist. So a changed count is a hard error unless --force, which wipes prior
# inputs/outputs/markers and restarts cleanly at the new count.
SLICES_FILE="$WORKDIR/.slices"
persisted=""; [ -f "$SLICES_FILE" ] && persisted="$(cat "$SLICES_FILE")"
if [ -n "$SLICES_ARG" ]; then
    SLICES="$SLICES_ARG"
    if [ -n "$persisted" ] && [ "$persisted" != "$SLICES" ]; then
        if [ "$FORCE" = 1 ]; then
            warn "re-slicing '$TASK' from $persisted to $SLICES; discarding previous inputs, outputs, and markers."
            rm -rf "$WORKDIR/inputs" "$WORKDIR/llm_out" "$WORKDIR"/.done_*
            mkdir -p "$WORKDIR/inputs" "$WORKDIR/llm_out"
        else
            die "task '$TASK' was started with $persisted slices but you requested $SLICES.
   Slicing partitions the whole cohort, so this can't be a partial resume.
   -> omit --slices to RESUME the existing $persisted-slice run, or
   -> add --force to RESTART cleanly at $SLICES slices (discards prior progress)."
        fi
    fi
elif [ -n "$persisted" ]; then
    SLICES="$persisted"
else
    SLICES=1
fi
[ "$SLICES" -ge 1 ] 2>/dev/null || die "--slices must be an integer >= 1 (got '$SLICES')"
echo "$SLICES" > "$SLICES_FILE"; export SLICES

STEPS=(preprocess infer aggregate)

# --until <step>: run through <step> then stop (used by queue.sh to prep-ahead the next task
# while the current one holds the GPU). stop_if_until is called after each step below.
if [ -n "$UNTIL" ]; then
    case " ${STEPS[*]} " in *" $UNTIL "*) ;; *) die "--until: unknown step '$UNTIL' (steps: ${STEPS[*]})";; esac
fi
stop_if_until() { [ -n "$UNTIL" ] && [ "$1" = "$UNTIL" ] && { log "reached --until $UNTIL; stopping."; exit 0; }; return 0; }

# --from: clear .done markers from the named step onward so they re-run.
if [ -n "$FROM" ]; then
    hit=0
    for s in "${STEPS[@]}"; do
        [ "$s" = "$FROM" ] && hit=1
        [ "$hit" = 1 ] && rm -f "$WORKDIR/.done_${s}" "$WORKDIR"/.done_infer_* 2>/dev/null
    done
    [ "$hit" = 1 ] || die "--from: unknown step '$FROM' (steps: ${STEPS[*]})"
fi

log "==== task=$TASK  workdir=$WORKDIR  models=(${MODELS[*]})  dry_run=$DRY_RUN ===="

# --- helpers to resolve a family list for a pass's models -------------------
families_for_models() {
    # Dedup families without associative arrays (portable to bash 3.2 on macOS).
    local out="" m fam
    for m in "${MODELS[@]}"; do
        fam="$(model_field "$m" 3)" || die "model '$m' not in models.conf"
        case ",$out," in
            *",$fam,"*) : ;;                      # already present
            *) out="${out:+$out,}$fam" ;;
        esac
    done
    echo "$out"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
[ -x "$LLAMA_BIN" ] || warn "llama-data-extraction not found/executable at $LLAMA_BIN (ok for --dry-run)"
for entry in "${PASSES[@]}"; do
    g="${entry##*:}"
    [ -f "$GRAMMAR_DIR/$g" ] || warn "grammar not found: $GRAMMAR_DIR/$g"
done
for m in "${MODELS[@]}"; do
    gguf="$(model_field "$m" 2)" || die "model '$m' not in models.conf"
    [ -f "$gguf" ] || warn "GGUF for '$m' not found at $gguf (fill real GPU-box path in models.conf)"
done

# --------------------------------------------------------------------------
# Step 1: preprocess = pull + build inputs. Notes are STREAMED from SQL directly into
# excerpt extraction (make_inputs.py --sql), so no notes.csv is ever written. This is the
# only DB touch, so it needs a valid Kerberos ticket.
# --------------------------------------------------------------------------
do_preprocess() {
    [ "$DRY_RUN" = 1 ] || require_ticket
    [ "$FORCE" = 1 ] && export FORCE_INPUTS=1   # config passes --force to make_inputs
    local fams; fams="$(families_for_models)"
    for entry in "${PASSES[@]}"; do
        local pass="${entry%%:*}"
        log "preprocess pass '$pass' families=$fams slices=$SLICES (streaming notes from SQL)"
        preprocess_pass "$pass" "$WORKDIR/inputs/$pass" "$fams" || return 1
    done
}
run_step preprocess do_preprocess || exit $?
stop_if_until preprocess

# --------------------------------------------------------------------------
# Step 3: infer — grouped by MODEL (load each GGUF once), inner loop over passes.
#   Per-(pass,model) marker so resume skips finished work.
# --------------------------------------------------------------------------
# Invoke llama-data-extraction for one input dir -> one out dir. Trailing args are GPU/extra flags.
#   _llama_run <gguf> <indir> <outdir> <grammar> <ctx> <par> <npred> <extra gpu args...>
_llama_run() {
    local gguf="$1" indir="$2" outdir="$3" grammar="$4" ctx="$5" par="$6" npred="$7"; shift 7
    mkdir -p "$outdir"
    local nseq; nseq="$(nlines "$indir/input.txt")"
    # shellcheck disable=SC2086
    "$LLAMA_BIN" \
        -m "$gguf" --promptFormat raw \
        --systemPromptFile "$indir/system.txt" --file "$indir/input.txt" --IDfile "$indir/ptIDs.txt" \
        --grammar-file "$GRAMMAR_DIR/$grammar" --outDir "$outdir" \
        --sequences "$nseq" --n-predict "$npred" --ctx-size "$ctx" --parallel "$par" \
        --temp 0 -fa on --n-gpu-layers 99 "$@"
}

# Split an input dir's input.txt/ptIDs.txt into <n> line-contiguous shards under <outprefix>/<i>/,
# copying the shared system.txt into each. Used for data-parallel (dual) GPU mode.
_shard_inputs() {
    local indir="$1" outprefix="$2" n="$3"
    local total per i start end
    total="$(nlines "$indir/input.txt")"
    per=$(( (total + n - 1) / n ))
    for (( i=0; i<n; i++ )); do
        local sd="$outprefix/$i"; mkdir -p "$sd"
        cp "$indir/system.txt" "$sd/system.txt"
        start=$(( i*per + 1 )); end=$(( (i+1)*per ))
        sed -n "${start},${end}p" "$indir/input.txt" > "$sd/input.txt"
        sed -n "${start},${end}p" "$indir/ptIDs.txt" > "$sd/ptIDs.txt"
    done
}

run_one_infer() {
    local pass="$1" grammar="$2" model="$3" slice="$4"
    local fam gguf ctx par npred gpu extra
    fam="$(model_field "$model" 3)"; gguf="$(model_field "$model" 2)"
    ctx="$(model_field "$model" 4)"; par="$(model_field "$model" 5)"
    npred="$(model_field "$model" 6)"; gpu="$(model_field "$model" 7)"; extra="$(model_field "$model" 8)"
    [ "$npred" -gt 0 ] 2>/dev/null || die "model '$model' must set n_predict>0 in models.conf (caps grammar runaways)"

    local indir="$WORKDIR/inputs/$pass/$fam/slice${slice}"
    local outbase="$WORKDIR/llm_out/$pass/$model/slice${slice}"

    case "$gpu" in
        dual)
            # Data-parallel: split inputs in half, run GPU 0 and GPU 1 in parallel.
            log "[$model] dual (data-parallel) across GPU 0 and GPU 1"
            _shard_inputs "$indir" "$outbase/_shard" 2
            # shellcheck disable=SC2086
            _llama_run "$gguf" "$outbase/_shard/0" "$outbase/gpu0" "$grammar" "$ctx" "$par" "$npred" -sm none -mg 0 $extra & local p0=$!
            # shellcheck disable=SC2086
            _llama_run "$gguf" "$outbase/_shard/1" "$outbase/gpu1" "$grammar" "$ctx" "$par" "$npred" -sm none -mg 1 $extra & local p1=$!
            wait "$p0"; local r0=$?; wait "$p1"; local r1=$?
            log "[$model] dual done: gpu0 exit=$r0 gpu1 exit=$r1"
            [ "$r0" -eq 0 ] && [ "$r1" -eq 0 ]
            ;;
        split|split:*)
            local sm="layer"; [ "$gpu" != "split" ] && sm="${gpu#split:}"
            log "[$model] split one model across GPUs (-sm $sm)"
            # shellcheck disable=SC2086
            _llama_run "$gguf" "$indir" "$outbase" "$grammar" "$ctx" "$par" "$npred" -sm "$sm" $extra
            ;;
        single:*)
            local g="${gpu#single:}"
            log "[$model] single GPU $g (-sm none -mg $g)"
            # shellcheck disable=SC2086
            _llama_run "$gguf" "$indir" "$outbase" "$grammar" "$ctx" "$par" "$npred" -sm none -mg "$g" $extra
            ;;
        *)
            die "unknown gpu mode '$gpu' for model '$model' (use single:N | split[:row|:tensor] | dual)"
            ;;
    esac
}
do_infer() {
    for model in "${MODELS[@]}"; do
        for entry in "${PASSES[@]}"; do
            local pass="${entry%%:*}" grammar="${entry##*:}" k
            # Per-slice inference with per-(pass,model,slice) .done markers -> resumable at
            # slice granularity (a crash on a huge cohort resumes at the current slice).
            for (( k=0; k<SLICES; k++ )); do
                run_step "infer_${pass}_${model}_s${k}" run_one_infer "$pass" "$grammar" "$model" "$k" || return 1
            done
        done
    done
}

# Hard GPU mutex around inference: even outside queue.sh (e.g. two run_task.sh launched by
# hand, or an orphaned task after a worker kill), no two inferences ever share the GPUs.
# flock auto-releases when its holder dies, so a crash can't deadlock it. On hosts without
# flock (e.g. macOS dev), the queue's single-worker design provides the serialization.
GPU_LOCK="${GPU_LOCK:-$PHENO_DIR/runtime/.gpu.lock}"
do_infer_locked() {
    command -v flock >/dev/null 2>&1 || { do_infer; return $?; }
    exec 201>"$GPU_LOCK"
    log "waiting for GPU lock ($GPU_LOCK) ..."
    flock -x 201
    log "GPU lock acquired"
    do_infer; local rc=$?
    exec 201>&-   # release so the next task can start immediately
    return $rc
}
run_step infer do_infer_locked || exit $?
stop_if_until infer

# --------------------------------------------------------------------------
# Step 4: aggregate -> results.csv
# --------------------------------------------------------------------------
do_aggregate() {
    local passes_csv models_csv
    passes_csv="$(IFS=,; for e in "${PASSES[@]}"; do echo -n "${e%%:*},"; done | sed 's/,$//')"
    models_csv="$(IFS=,; echo "${MODELS[*]}")"
    python3 "$PHENO_DIR/python/aggregate.py" \
        --task "$TASK" --llm-out "$WORKDIR/llm_out" \
        --passes "$passes_csv" --models "$models_csv" \
        --out "$WORKDIR/results.csv"
}
run_step aggregate do_aggregate || exit $?

log "==== done: $WORKDIR/results.csv ===="
[ "$RETRY_ERRORS" = 1 ] && warn "--retry-errors not yet implemented; grammar runaways are already auto-retried in-tool."
