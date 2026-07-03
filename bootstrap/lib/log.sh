#!/bin/bash
# =====================================================================
# lib/log.sh - consistent logging + report counters
# ---------------------------------------------------------------------
# Pure bash 3.2. No associative arrays. Colors auto-disable when the
# output is not a TTY (e.g. piped or in CI).
# =====================================================================

# --- colors (disabled when not a terminal) ---------------------------
if [ -t 1 ]; then
  LOG_C_RESET=$'\033[0m'
  LOG_C_DIM=$'\033[2m'
  LOG_C_RED=$'\033[31m'
  LOG_C_GREEN=$'\033[32m'
  LOG_C_YELLOW=$'\033[33m'
  LOG_C_BLUE=$'\033[34m'
else
  LOG_C_RESET=''; LOG_C_DIM=''; LOG_C_RED=''
  LOG_C_GREEN=''; LOG_C_YELLOW=''; LOG_C_BLUE=''
fi

# --- report counters -------------------------------------------------
LOG_CREATED=0
LOG_SKIPPED=0
LOG_REPAIRED=0
LOG_BACKED_UP=0
LOG_FAILED=0

log_reset_counters() {
  LOG_CREATED=0; LOG_SKIPPED=0; LOG_REPAIRED=0; LOG_BACKED_UP=0; LOG_FAILED=0
}

# --- message helpers -------------------------------------------------
log_info()  { printf '%s\n' "${LOG_C_BLUE}•${LOG_C_RESET} $*"; }
log_ok()    { printf '%s\n' "${LOG_C_GREEN}✓${LOG_C_RESET} $*"; }
log_warn()  { printf '%s\n' "${LOG_C_YELLOW}!${LOG_C_RESET} $*" >&2; }
log_error() { printf '%s\n' "${LOG_C_RED}✗${LOG_C_RESET} $*" >&2; }
log_dim()   { printf '%s\n' "${LOG_C_DIM}$*${LOG_C_RESET}"; }
log_step()  { printf '\n%s\n' "${LOG_C_BLUE}▸ $*${LOG_C_RESET}"; }

# dry-run marker
log_dry()   { printf '%s\n' "${LOG_C_DIM}[dry-run]${LOG_C_RESET} $*"; }

# Run a mutating command, or just describe it under --dry-run.
# Shared by every layer so the decision flow stays identical and only
# the side effect is gated. (link.sh keeps its own equivalent to avoid
# a cross-dependency on this file's internals.)
mutate() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "$*"
  else
    "$@"
  fi
}

# --- final report ----------------------------------------------------
log_report() {
  printf '\n%s\n' "${LOG_C_BLUE}── report ──────────────────────────────${LOG_C_RESET}"
  printf '  created:   %s\n' "$LOG_CREATED"
  printf '  repaired:  %s\n' "$LOG_REPAIRED"
  printf '  skipped:   %s\n' "$LOG_SKIPPED"
  printf '  backed-up: %s\n' "$LOG_BACKED_UP"
  if [ "$LOG_FAILED" -gt 0 ]; then
    printf '  %sfailed:    %s%s\n' "$LOG_C_RED" "$LOG_FAILED" "$LOG_C_RESET"
  else
    printf '  failed:    0\n'
  fi
}
