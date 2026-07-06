#!/usr/bin/env bash
# Shared helpers for the phenotyping pipeline. Sourced by run_task.sh.
# Intentionally NOT `set -e` at file scope: per-step fault isolation is handled by run_step.

# ---------------------------------------------------------------------------
# Paths (relative to the phenotyping/ dir, which is PHENO_DIR)
# ---------------------------------------------------------------------------
PHENO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$PHENO_DIR/.." && pwd)"
LLAMA_BIN="${LLAMA_BIN:-$REPO_DIR/build/bin/llama-data-extraction}"
GRAMMAR_DIR="${GRAMMAR_DIR:-$REPO_DIR/grammars}"
MODELS_CONF="$PHENO_DIR/config/models.conf"

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------
# LOGFILE is set by run_task.sh once the task workdir exists.
log()  { local m="[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "$m"; [ -n "${LOGFILE:-}" ] && echo "$m" >> "$LOGFILE"; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Kerberos: ensure a valid ticket for the SQL pull (the only DB touch).
# ---------------------------------------------------------------------------
require_ticket() {
    if klist -s 2>/dev/null; then
        log "Kerberos ticket valid."
    else
        warn "No valid Kerberos ticket. Running kticket (interactive)..."
        kticket || die "kticket failed; cannot reach SQL Server."
    fi
}

# ---------------------------------------------------------------------------
# models.conf lookup.  model_field <name> <col-index (1-based)>
# Columns: 1=name 2=gguf 3=family 4=ctx 5=parallel 6=n_predict 7=gpu 8=extra
# ---------------------------------------------------------------------------
model_field() {
    local want="$1" col="$2"
    awk -F'|' -v want="$want" -v col="$col" '
        /^[[:space:]]*#/ { next } NF < 6 { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
          if ($1 == want) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $col); print $col; found=1; exit } }
        END { if (!found) exit 3 }
    ' "$MODELS_CONF"
}
model_exists() { model_field "$1" 1 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Step runner with .done checkpointing and fault isolation.
#   run_step <step-name> <cmd...>
# Skips if $WORKDIR/.done_<step-name> exists (unless FORCE=1). On success, touches
# the marker. On failure, logs and returns non-zero so run_task.sh stops; re-running
# resumes at this step. --from <step> is handled by run_task.sh clearing later markers.
# ---------------------------------------------------------------------------
run_step() {
    local step="$1"; shift
    local marker="$WORKDIR/.done_${step}"
    if [ -f "$marker" ] && [ "${FORCE:-0}" != "1" ]; then
        log "SKIP  [$step] (already done: $marker)"
        return 0
    fi
    log "START [$step] $*"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "DRY   [$step] would run: $*"
        return 0
    fi
    if "$@"; then
        : > "$marker"
        log "DONE  [$step]"
        return 0
    else
        local rc=$?
        warn "FAIL  [$step] (exit $rc). Fix the cause and re-run './run_task.sh $TASK' to resume here."
        return $rc
    fi
}

# ---------------------------------------------------------------------------
# Count lines (sequences) in a file, 0 if missing.
# ---------------------------------------------------------------------------
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
