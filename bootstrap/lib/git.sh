#!/bin/bash
# =====================================================================
# lib/git.sh - git ignore wiring (idempotent)
# ---------------------------------------------------------------------
# Two concerns, both non-destructive and repeatable:
#
#   git_ignore_global_ensure <entry>...
#       Make sure ~/.config/git/ignore (git's default global ignore)
#       exists and contains each entry. Never rewrites existing lines.
#
#   git_exclude_ensure <project> <entry>...
#       Append entries to <project>/.git/info/exclude so the client's
#       tracked .gitignore is never touched. No-op if not a git repo.
#
# Missing entries are computed up front, so the dry-run prints a single
# grouped line instead of one per entry. Behaviour is unchanged.
#
# Depends on: lib/log.sh (log_*, DRY_RUN)
# =====================================================================

# Newline-separated list of entries in "$@" that are not yet present
# (exact match) in $file. Prints the missing ones, one per line.
_git_missing_entries() {
  local file="$1"; shift
  local e
  for e in "$@"; do
    if [ -f "$file" ] && grep -qxF "$e" "$file" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$e"
  done
}

# Append each missing entry to $file (creating file + parent dir once).
# Real mutation only; callers gate dry-run and do the logging.
_git_append_missing() {
  local file="$1"; shift   # remaining args = missing entries
  local dir e
  dir=$(dirname "$file")
  [ -d "$dir" ] || mkdir -p "$dir"
  for e in "$@"; do
    printf '%s\n' "$e" >> "$file"
  done
}

# git_ignore_global_ensure <entry>...
git_ignore_global_ensure() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
  local missing n
  missing=$(_git_missing_entries "$file" "$@")
  n=$(printf '%s' "$missing" | grep -c . )

  if [ "$n" -eq 0 ]; then
    log_info "✓ global git ignore already covers all entries"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "would add $n entr$( [ "$n" -eq 1 ] && echo y || echo ies ) to ${file/#$HOME/~}"
    return 0
  fi
  # shellcheck disable=SC2086
  _git_append_missing "$file" $missing
  log_ok "🌐 global git ignore updated ($n): ${file/#$HOME/~}"
}

# git_exclude_ensure <project> <entry>...
git_exclude_ensure() {
  local project="$1"; shift
  local exclude="$project/.git/info/exclude"
  if [ ! -d "$project/.git" ]; then
    log_info "· not a git repo, skipping info/exclude: ${project/#$HOME/~}"
    return 0
  fi
  local missing n
  missing=$(_git_missing_entries "$exclude" "$@")
  n=$(printf '%s' "$missing" | grep -c . )

  if [ "$n" -eq 0 ]; then
    log_info "✓ .git/info/exclude already covers all entries"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "would add $n entr$( [ "$n" -eq 1 ] && echo y || echo ies ) to .git/info/exclude"
    return 0
  fi
  # shellcheck disable=SC2086
  _git_append_missing "$exclude" $missing
  log_ok "🚫 .git/info/exclude updated ($n): keeps client .gitignore untouched"
}
