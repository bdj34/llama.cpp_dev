#!/usr/bin/env bash
# Shared config + helpers for the phenotyping INFERENCE queue.
#
# Preprocessing is a SEPARATE step (python/extract_*.py already produced the inputs_<r>.txt /
# IDs_<r>.txt files). This half only runs llama-data-extraction, and every bit of resume state
# is derived from what is on disk under RESULTS_ROOT -- there are no markers to keep in sync.

PHENO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$PHENO_DIR/.." && pwd)"

# All overridable via the environment (handy for testing / non-standard layouts).
LLAMA_BIN="${LLAMA_BIN:-$REPO_DIR/build/bin/llama-data-extraction}"
GRAMMAR_DIR="${GRAMMAR_DIR:-$REPO_DIR/grammars}"
SYSPROMPT_DIR="${SYSPROMPT_DIR:-$REPO_DIR/system_prompts}"
RESULTS_ROOT="${RESULTS_ROOT:-/data/models/results_test}"     # HARDCODE CHANGE THIS TO REQUIRED OUTDIR. outDir = RESULTS_ROOT/<task>/<model>/rep<r>

CONF_DIR="$PHENO_DIR/config"
JOBS_CONF="${JOBS_CONF:-$CONF_DIR/jobs.conf}"

# Small coordination state: the GPU lock and the queue manifest live here (NOT the big results).
COORD_DIR="$PHENO_DIR/runtime"
mkdir -p "$COORD_DIR"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

# Per-job config lookup:  job_field <task> <model> <replicate> <retry T|F> <col-1based>
# Rows (one per JOB): "task | model | replicate | retry | gguf | prompt_dir | promptFormat | grammar
# | input_dir | args". The KEY is (task, model, replicate, retry), so a normal (F) and a retry (T)
# row for the same job coexist. retry is canonicalized (anything starting T/t -> T, else F), so
# T/TRUE and F/FALSE/blank all work. '#' comments and short lines skipped. Exit 3 if no match.
job_field() {
    awk -F'|' -v t="$1" -v m="$2" -v rep="$3" -v r="$4" -v col="$5" '
        function canon(x){ return (toupper(substr(x,1,1))=="T") ? "T" : "F" }
        /^[[:space:]]*#/ { next } NF < 4 { next }
        { tk=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",tk)
          mk=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",mk)
          rk=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rk)
          yk=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",yk)
          if (tk==t && mk==m && rk==rep && canon(yk)==canon(r)) { v=$col; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; found=1; exit } }
        END { if (!found) exit 3 }
    ' "$JOBS_CONF"
}

# Print "task model replicate retry" for every job row in jobs.conf (used by queue.sh add-all).
job_keys() {
    awk -F'|' '/^[[:space:]]*#/ { next } NF < 4 { next }
        { for (i=1;i<=4;i++) gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); print $1, $2, $3, $4 }' "$JOBS_CONF"
}

# Machine-wide GPU serialization: run <cmd...> while holding an exclusive lock so two inferences
# never overlap (even a hand-launched run_one alongside the queue). Prefer flock (auto-releases if
# the holder dies); fall back to an atomic mkdir lock that clears itself if the owner PID is gone.
GPU_LOCK="${GPU_LOCK:-$COORD_DIR/.gpu.lock}"
with_gpu_lock() {
    if command -v flock >/dev/null 2>&1; then                            # flock available (Linux): use it
        # Subshell holds fd 200 on the lock file, takes an exclusive (blocking) lock, runs the
        # command, then releases automatically when the subshell exits -- even on a crash.
        ( exec 200>"$GPU_LOCK"; flock -x 200; "$@" ); return $?
    fi
    # No flock: emulate with an atomic lock DIRECTORY (mkdir succeeds for exactly one caller).
    local d="${GPU_LOCK}.d" owner rc                                     # d = lock dir; track holder PID + exit code
    until mkdir "$d" 2>/dev/null; do                                     # loop until WE create (own) the lock dir
        owner="$(cat "$d/pid" 2>/dev/null || true)"                     # PID of whoever currently holds it
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$d"; continue; fi  # holder dead -> clear stale lock, retry now
        sleep 2                                                          # holder alive -> wait, then retry
    done
    echo $$ > "$d/pid"                                                   # we own it: record our PID so others detect if WE die
    "$@"; rc=$?                                                          # run the command, capture its exit code
    rm -rf "$d"                                                          # release the lock
    return $rc                                                          # propagate the command's exit code
}

# Non-blocking claim: run <cmd...> holding <lockfile>; if it is already held, return 111 WITHOUT
# running (the caller skips to the next job). Used by per-card workers so two cards never run the
# same job. Prefer flock (auto-releases on death); fall back to atomic mkdir with PID-liveness.
with_job_lock_nb() {
    local lock="$1"; shift                                              # $1 = lock file; the rest is the command
    local rc                                                            # will hold the command's exit code
    if command -v flock >/dev/null 2>&1; then                          # flock available: non-blocking try
        exec 8>"$lock"                                                 # open fd 8 on the lock file
        if flock -n 8; then "$@" 8>&-; rc=$?; exec 8>&-; return $rc; fi # got it: run cmd (8>&- so children don't inherit the lock), close fd, return rc
        exec 8>&-; return 111                                         # already held: close fd, signal "skip" (111)
    fi
    # No flock: atomic lock DIRECTORY, non-blocking.
    local d="${lock}.d" owner                                          # d = lock dir; track holder PID
    if ! mkdir "$d" 2>/dev/null; then                                 # couldn't claim -> it's already held...
        owner="$(cat "$d/pid" 2>/dev/null || true)"                  # ...read the holder's PID
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$d"; else return 111; fi  # dead -> clear stale; alive -> skip (111)
        mkdir "$d" 2>/dev/null || return 111                         # retry once after clearing; lost a race -> skip (111)
    fi
    echo $$ > "$d/pid"                                                # we hold it: record our PID
    "$@"; rc=$?                                                       # run the command, capture its exit code
    rm -rf "$d"                                                       # release the lock
    return $rc                                                       # propagate the command's exit code
}
