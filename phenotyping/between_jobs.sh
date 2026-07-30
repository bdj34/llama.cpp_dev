#!/usr/bin/env bash
# Write each reviewer job's consensus file as soon as BOTH small models have finished that task,
# so the reviewer only reads the IDs they disagreed on. Safe to run repeatedly -- every block
# no-ops unless the script is there, both jobs are complete, and the file is not already written.
# Meant to run alongside the queue, e.g. from your own crontab:
#   */5 * * * * /ABS/PATH/phenotyping/between_jobs.sh >> /ABS/PATH/phenotyping/runtime/interim.log 2>&1
set -uo pipefail

PY_DIR="$HOME/llama.cpp_dev/phenotyping/python/between_jobs"
RESULTS="/data/models/results"
INPUTS="/data/models/inputs"

# Source data transferred from VINCI. SET THESE for this box.
BUCKETS="/data/models/ibd_csv_data/note_buckets"
PATH_CSV="/data/models/ibd_csv_data/pathReports/colo_pathReports_IBDPts_2026-07-15.csv.gz"
CPT_CSV="/data/models/ibd_csv_data/CPT/colo_CPT_IBDPts_2026-07-15.csv.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# job_done <outdir> <idfile> -- true when every ID in idfile already appears in outdir's
# output_*.txt. Same read as run_one.sh: the ID is the LAST tab field, or the one before a
# NO_GRAMMAR sentinel. An Error row counts as done, exactly as normal resume treats it.
job_done() {
    local outdir="$1" idfile="$2" remaining
    [ -f "$idfile" ] || return 1
    shopt -s nullglob; local outs=( "$outdir"/output_*.txt ); shopt -u nullglob
    [ "${#outs[@]}" -gt 0 ] || return 1
    remaining="$(awk -F'\t' '
        FNR==NR { ids[$0]=1; next }
        { id = ($NF=="NO_GRAMMAR") ? $(NF-1) : $NF; if (id in ids) seen[id]=1 }
        END { n=0; for (k in ids) if (!(k in seen)) n++; print n }
    ' "$idfile" "${outs[@]}")"
    [ "$remaining" -eq 0 ]
}

# has_consensus <outdir> -- true once skip_consensus_*.py has written its file there.
has_consensus() {
    shopt -s nullglob; local f=( "$1"/output_consensus*.txt ); shopt -u nullglob
    [ "${#f[@]}" -gt 0 ]
}

# inputs_built <indir> -- true once a preprocessing step finished cleanly. The marker, not
# inputs_1.txt, is the sentinel: the extractors stream their output, so a killed run leaves a
# partial inputs file that would otherwise look complete and never be rebuilt.
inputs_built() { [ -f "$1/.built" ]; }

# Run python scripts when the inference is done
if [ -f "$PY_DIR/skip_consensus_crc.py" ] \
   && job_done "$RESULTS/crc_free_text/gemma4-26-A4-nonThinking/rep1"  "$INPUTS/crc_free_text/IDs_1.txt" \
   && job_done "$RESULTS/crc_free_text/qwen3.6-35-A3-nonThinking/rep2" "$INPUTS/crc_free_text/IDs_2.txt" \
   && ! has_consensus "$RESULTS/crc_free_text_rerun/gemma4-31B-thinking/rep3"; then
# run python script:
log "crc_free_text: both models done -> writing consensus"
python "$PY_DIR/skip_consensus_crc.py" --path1 /data/models/results/crc_free_text/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/crc_free_text/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/crc_free_text_rerun/gemma4-31B-thinking/rep3
fi

if [ -f "$PY_DIR/skip_consensus_ibd.py" ] \
   && job_done "$RESULTS/ibd/gemma4-26-A4-nonThinking/rep1"  "$INPUTS/ibd/IDs_1.txt" \
   && job_done "$RESULTS/ibd/qwen3.6-35-A3-nonThinking/rep2" "$INPUTS/ibd/IDs_2.txt" \
   && ! has_consensus "$RESULTS/ibd_rerun/gemma4-31B-thinking/rep3"; then
log "ibd: both models done -> writing consensus"
python "$PY_DIR/skip_consensus_ibd.py" --path1 /data/models/results/ibd/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/ibd/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/ibd_rerun/gemma4-31B-thinking/rep3
fi

# colonoscopy timing runs BOTH models on rep 1 (chunk mode), so both read IDs_1.txt
if [ -f "$PY_DIR/skip_consensus_colonoscopy_timing.py" ] \
   && job_done "$RESULTS/colonoscopy_timing/gemma4-26-A4-nonThinking/rep1"  "$INPUTS/colonoscopy_timing/IDs_1.txt" \
   && job_done "$RESULTS/colonoscopy_timing/qwen3.6-35-A3-nonThinking/rep1" "$INPUTS/colonoscopy_timing/IDs_1.txt" \
   && ! has_consensus "$RESULTS/colonoscopy_timing_rerun/gemma4-31B-thinking/rep1"; then
log "colonoscopy_timing: both models done -> writing consensus"
python "$PY_DIR/skip_consensus_colonoscopy_timing.py" --path1 /data/models/results/colonoscopy_timing/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/colonoscopy_timing/qwen3.6-35-A3-nonThinking/rep1 --out-dir /data/models/results/colonoscopy_timing_rerun/gemma4-31B-thinking/rep1
fi

if [ -f "$PY_DIR/skip_consensus_colectomy.py" ] \
   && job_done "$RESULTS/colectomy/gemma4-26-A4-nonThinking/rep1"  "$INPUTS/colectomy/IDs_1.txt" \
   && job_done "$RESULTS/colectomy/qwen3.6-35-A3-nonThinking/rep2" "$INPUTS/colectomy/IDs_2.txt" \
   && ! has_consensus "$RESULTS/colectomy_rerun/gemma4-31B-thinking/rep3"; then
log "colectomy: both models done -> writing consensus"
python "$PY_DIR/skip_consensus_colectomy.py" --path1 /data/models/results/colectomy/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/colectomy/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/colectomy_rerun/gemma4-31B-thinking/rep3
fi

# colonoscopy_report_yn -> colonoscopy_details_extraction. Turn the gate's Yes answers into a whitelist, then
# assemble one input per colonoscopy EVENT from the whitelisted reports + the pathology and CPT
# CSVs. Unlike the consensus blocks this one takes tens of minutes, so it holds a lock: cron
# fires every 5 minutes and the sentinel is only written at the end.
YN_OUT="$RESULTS/colonoscopy_report_yn/gemma4-26-A4-nonThinking/rep1"
EVENT_IN="$INPUTS/colonoscopy_details_extraction"
if [ -f "$PY_DIR/extract_colonoscopy_event.py" ] \
   && job_done "$YN_OUT" "$INPUTS/colonoscopy_report_yn/IDs_1.txt" \
   && ! inputs_built "$EVENT_IN"; then
(
    flock -n 9 || { log "colonoscopy_details_extraction: build already running, skipping"; exit 0; }
    log "colonoscopy_report_yn: gate done -> building whitelist + colonoscopy_details_extraction inputs"
    mkdir -p "$EVENT_IN"
    awk -F'\t' '$1=="Answer: Yes" { print ($NF=="NO_GRAMMAR" ? $(NF-1) : $NF) }' \
        "$YN_OUT"/output_*.txt | sort -u > "$EVENT_IN/whitelist.txt"
    log "  whitelist: $(wc -l < "$EVENT_IN/whitelist.txt") of $(cat "$YN_OUT"/output_*.txt | wc -l) gate answers"
    python "$PY_DIR/extract_colonoscopy_event.py" \
        --buckets   "$BUCKETS" \
        --path-csv  "$PATH_CSV" \
        --cpt-csv   "$CPT_CSV" \
        --whitelist "$EVENT_IN/whitelist.txt" \
        --out-dir   "$EVENT_IN" \
      && touch "$EVENT_IN/.built" \
      && log "colonoscopy_details_extraction: inputs built"
) 9>"$INPUTS/.colonoscopy_details_extraction.lock"
fi
