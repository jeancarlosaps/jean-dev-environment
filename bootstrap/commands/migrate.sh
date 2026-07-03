#!/bin/bash
# =====================================================================
# commands/migrate.sh - move a project's REAL config into the dev-env
# ---------------------------------------------------------------------
# This is the only command that relocates the user's existing data, so
# it is deliberately conservative:
#
#   * NEVER merges. NEVER overwrites content already in ai/shared|profiles.
#   * On the first conflict it STOPS immediately and reports.
#   * A safety backup (copy) is made BEFORE every mv.
#   * --dry-run shows exactly what would move, where, and the policy.
#
# Per resolved link:
#   target is a symlink      -> nothing to migrate            (ignored)
#   target has no local data -> nothing to migrate            (ignored)
#   target is real data:
#       central is empty/absent -> backup, move in, link      (moved+linked)
#       central already has data -> CONFLICT, stop            (conflict)
#
# "central empty" = missing, an empty file, or a dir holding only the
# .gitkeep placeholder. Replacing a placeholder is not an overwrite.
#
# Globals from bin/dev-env: DEV_ENV_HOME DEV_ENV_STABLE MANIFEST
#                           PROFILE STATE_DIR LINK_BACKUP_ROOT DRY_RUN
# Depends on: log.sh, manifest.sh, link.sh (_link_run_ts), git.sh,
#             project.sh (_project_register)
# =====================================================================

# Is the central destination free to receive data (not real content)?
_migrate_central_available() {
  local central="$1" item base
  [ -e "$central" ] || return 0            # absent
  if [ -d "$central" ]; then
    for item in "$central"/* "$central"/.*; do
      [ -e "$item" ] || continue           # unmatched glob
      base=$(basename "$item")
      case "$base" in .|..|.gitkeep) continue ;; esac
      return 1                             # real content present
    done
    return 0                               # only placeholder / empty
  fi
  [ -s "$central" ] && return 1 || return 0  # file: non-empty = conflict
}

# Safety backup (COPY, not move) before relocating. Shares the per-run
# timestamp folder with link.sh so one run groups its backups together.
_migrate_backup() {
  local path="$1" root dir dest base n
  root="${LINK_BACKUP_ROOT:-$PWD/backups}"
  dir="$root/$(_link_run_ts)"
  base=$(basename "$path")
  dest="$dir/$base"
  n=1
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$dir/$base.$n"; n=$((n + 1))
  done
  mutate mkdir -p "$dir"
  # -R recurse, -p preserve mode/timestamps/ownership (and, on macOS,
  # ACLs and extended attributes) so the backup is a faithful copy.
  mutate cp -Rp "$path" "$dest"
  LOG_BACKED_UP=$((LOG_BACKED_UP + 1))
  log_ok "🛟 backed up $path -> ${dest#$root/}"
}

# Move real data into the (empty/absent) central location.
_migrate_move() {
  local src="$1" central="$2" parent
  parent=$(dirname "$central")
  [ -d "$parent" ] || mutate mkdir -p "$parent"
  if [ -d "$central" ]; then
    mutate rm -f "$central/.gitkeep"
    mutate rmdir "$central"
  elif [ -e "$central" ]; then
    mutate rm -f "$central"
  fi
  mutate mv "$src" "$central"
}

cmd_migrate() {
  local arg="$1"
  if [ -z "$arg" ]; then
    log_error "usage: dev-env migrate <path> [--profile <name>]"
    return 2
  fi
  if [ ! -d "$arg" ]; then
    log_error "project path is not a directory: $arg"
    return 2
  fi
  local proj
  proj=$(cd "$arg" 2>/dev/null && pwd -P) || { log_error "cannot resolve: $arg"; return 2; }
  if [ ! -d "$DEV_ENV_STABLE" ]; then
    log_error "stable path missing: ${DEV_ENV_STABLE/#$HOME/~} — run 'dev-env init' first"
    return 1
  fi

  local profile="${PROFILE:-default}"
  log_step "dev-env migrate (profile: $profile)"
  log_info "project: ${proj/#$HOME/~}"
  [ "${DRY_RUN:-0}" = "1" ] && log_info "mode: dry-run (no changes will be made)"

  if ! manifest_load "$MANIFEST" "$profile"; then
    log_error "could not resolve profile '$profile'"
    return 1
  fi

  local n i rel_src rel_tgt req cfl central src_stable tgt
  local moved=0 linked=0 conflicts=0 ignored=0
  log_reset_counters
  n=$(manifest_link_count)

  i=1
  while [ "$i" -le "$n" ]; do
    rel_src=$(manifest_link_field "$i" source)
    rel_tgt=$(manifest_link_field "$i" target)
    req=$(manifest_link_field "$i" required)
    cfl=$(manifest_link_field "$i" conflict)
    central="$DEV_ENV_HOME/$rel_src"
    src_stable="$DEV_ENV_STABLE/$rel_src"
    tgt="$proj/$rel_tgt"

    if [ -L "$tgt" ]; then
      log_info "· $rel_tgt already a symlink, nothing to migrate"
      ignored=$((ignored + 1)); i=$((i + 1)); continue
    fi
    if [ ! -e "$tgt" ]; then
      log_info "· $rel_tgt has no local data, nothing to migrate"
      ignored=$((ignored + 1)); i=$((i + 1)); continue
    fi

    if ! _migrate_central_available "$central"; then
      conflicts=$((conflicts + 1))
      log_error "CONFLICT: central already has content -> $rel_src"
      log_error "  local data: $tgt"
      log_error "  refusing to overwrite or merge; stopping now."
      manifest_unload
      _migrate_summary "$moved" "$linked" "$conflicts" "$ignored"
      return 1
    fi

    # available -> backup (copy) BEFORE moving, then move, then link
    if [ "${DRY_RUN:-0}" = "1" ]; then
      log_dry "would migrate $rel_tgt: $tgt -> $central (central empty, policy: move+link)"
    fi
    _migrate_backup "$tgt"
    _migrate_move "$tgt" "$central"
    moved=$((moved + 1))
    log_ok "📦 moved $rel_tgt -> ai/${central#*/ai/}"

    # after the move the project slot is empty -> a plain link creation
    local parent; parent=$(dirname "$tgt")
    [ -d "$parent" ] || mutate mkdir -p "$parent"
    mutate ln -s "$src_stable" "$tgt"
    linked=$((linked + 1))
    log_ok "🔗 linked $rel_tgt -> $src_stable"

    i=$((i + 1))
  done
  manifest_unload

  # We only reach this point if the loop completed with NO conflict
  # (a conflict returns early, before any registration). Order is:
  #   backup -> move -> symlink  (per link, above)
  #   -> .git/info/exclude -> projects.json  (below, once, last)
  # So the registry only ever lists projects whose migration finished
  # in full — never a partially-officialized state.
  local args="" rel
  if manifest_load "$MANIFEST" "$profile"; then
    local m j; m=$(manifest_link_count); j=1
    while [ "$j" -le "$m" ]; do
      rel=$(manifest_link_field "$j" target)
      args="$args $rel"; j=$((j + 1))
    done
    manifest_unload
  fi
  # shellcheck disable=SC2086
  git_exclude_ensure "$proj" $args
  _project_register "$proj"

  _migrate_summary "$moved" "$linked" "$conflicts" "$ignored"
  return 0
}

_migrate_summary() {
  local moved="$1" linked="$2" conflicts="$3" ignored="$4"
  printf '\n%s\n' "${LOG_C_BLUE}── migration summary ───────────────────${LOG_C_RESET}"
  printf '  moved:     %s\n' "$moved"
  printf '  linked:    %s\n' "$linked"
  if [ "$conflicts" -gt 0 ]; then
    printf '  %sconflicts: %s%s\n' "$LOG_C_RED" "$conflicts" "$LOG_C_RESET"
  else
    printf '  conflicts: 0\n'
  fi
  printf '  ignored:   %s\n' "$ignored"
  printf '  backups:   %s\n' "$LOG_BACKED_UP"
}
