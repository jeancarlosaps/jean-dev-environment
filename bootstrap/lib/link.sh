#!/bin/bash
# =====================================================================
# lib/link.sh - symlink engine (filesystem only)
# ---------------------------------------------------------------------
# Pure filesystem layer. It knows NOTHING about YAML, the manifest,
# profiles, extends or defaults. It receives already-resolved data as
# plain positional arguments:
#
#     link_apply <source> <target> <required> <conflict>
#
#   source    absolute path to the real content inside the dev-env
#   target    absolute path of the link to create in the project
#   required  true|false   (source missing: fail if true, skip if false)
#   conflict  backup|skip|fail  (target is real data)
#
# The caller (command layer) is responsible for passing ABSOLUTE paths.
#
# Configuration (globals set by the caller):
#   DRY_RUN            "1" -> mutations become no-ops; flow is identical
#   LINK_BACKUP_ROOT   where timestamped backups go (default: ./backups)
#
# Counters live in lib/log.sh: LOG_CREATED / LOG_REPAIRED / LOG_SKIPPED
# / LOG_BACKED_UP / LOG_FAILED.
#
# Bash 3.2 compatible. No declare -A, no mapfile.
# =====================================================================

# One backup folder per run, computed lazily on first backup so that a
# run with nothing to back up never creates an empty folder.
LINK_RUN_TS=""

_link_run_ts() {
  [ -n "$LINK_RUN_TS" ] || LINK_RUN_TS=$(date +%Y%m%d-%H%M%S)
  printf '%s' "$LINK_RUN_TS"
}

# Run a mutating command, or just describe it under --dry-run.
# The DECISION always happens; only the mutation is gated here.
_link_mutate() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "$*"
  else
    "$@"
  fi
}

# Report a mutation that ACTUALLY happened. Success messages and
# counters describe real side effects only, so under --dry-run this is a
# no-op: the mutation itself was already announced by _link_mutate as the
# exact command it would run, and the final report can never be mistaken
# for a real run.
#   _link_done <created|repaired|backed_up> <message>
_link_done() {
  local what="$1"; shift
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  case "$what" in
    created)   LOG_CREATED=$((LOG_CREATED + 1)) ;;
    repaired)  LOG_REPAIRED=$((LOG_REPAIRED + 1)) ;;
    backed_up) LOG_BACKED_UP=$((LOG_BACKED_UP + 1)) ;;
  esac
  log_ok "$*"
}

# Resolve a path to its canonical absolute physical path.
# Follows the full symlink chain, then canonicalizes the parent dir
# with pwd -P. Pure bash 3.2 + readlink/cd/pwd (macOS standard tools).
#
# The 40-hop guard prevents an infinite loop on a cyclic chain
# (A -> B -> A). 40 is a SAFETY ceiling, not a functional limit: no
# legitimate setup nests symlinks that deep. Do NOT "optimize" this
# number down without understanding it exists solely to break cycles.
# On hitting the ceiling the function FAILS LOUDLY (stderr + return 1)
# and prints nothing, so a partially-resolved path is never returned
# and can never be mistaken for a real destination.
_link_canonical() {
  local p="$1" dir base t pd guard=0
  while [ -L "$p" ]; do
    if [ "$guard" -ge 40 ]; then
      printf '✗ symlink chain too deep (cycle?): %s\n' "$1" >&2
      return 1
    fi
    t=$(readlink "$p")
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    guard=$((guard + 1))
  done
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P )
  else
    dir=$(dirname "$p"); base=$(basename "$p")
    pd=$( cd "$dir" 2>/dev/null && pwd -P ) || pd="$dir"
    printf '%s/%s\n' "$pd" "$base"
  fi
}

# Move a real file/dir into a timestamped backup folder.
# Never overwrites, never reuses, never deletes: on name collision it
# appends an incrementing suffix.
# Pure: everything it needs is passed in ($path) or is module config
# (LINK_BACKUP_ROOT). No dependency on any caller's local variables.
_link_backup() {
  local path="$1"
  local root dir dest base n
  root="${LINK_BACKUP_ROOT:-$PWD/backups}"
  dir="$root/$(_link_run_ts)"
  base=$(basename "$path")
  dest="$dir/$base"

  n=1
  while [ -e "$dest" ] || [ -L "$dest" ]; do
    dest="$dir/$base.$n"
    n=$((n + 1))
  done

  _link_mutate mkdir -p "$dir"
  _link_mutate mv "$path" "$dest"
  _link_done backed_up "🛟 backed up $path -> ${dest#$root/}"
}

# Create the symlink (ensures the parent directory exists first).
_link_create() {
  local source="$1" target="$2"
  local parent
  parent=$(dirname "$target")
  [ -d "$parent" ] || _link_mutate mkdir -p "$parent"
  _link_mutate ln -s "$source" "$target"
}

# ---------------------------------------------------------------------
# link_apply <source> <target> <required> <conflict>
# ---------------------------------------------------------------------
# The 5 cases:
#   5  source missing         -> fail (required) or skip (optional)
#   1  correct symlink        -> skip
#   2  wrong/broken symlink   -> recreate (source is guaranteed present)
#   3  real file/dir at target-> apply conflict policy
#   4  nothing at target      -> create symlink
# A broken link is never created.
# ---------------------------------------------------------------------
link_apply() {
  local source="$1" target="$2" required="$3" conflict="$4"
  local target_display="$target"

  # --- Case 5: source does not exist -------------------------------
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    if [ "$required" = "false" ]; then
      log_warn "⏭  optional source missing, skipping: $source"
      LOG_SKIPPED=$((LOG_SKIPPED + 1))
      return 0
    fi
    log_error "source does not exist: $source"
    LOG_FAILED=$((LOG_FAILED + 1))
    return 1
  fi

  # --- target is a symlink -----------------------------------------
  if [ -L "$target" ]; then
    # Case 1: correct when it resolves to the SAME physical destination
    # as the source. Compared canonically, so absolute / relative / ~
    # spellings and intermediate symlinks (e.g. ~/Developer/dev-env) all
    # count as equal. Only a genuinely different destination triggers
    # a recreate.
    if [ -e "$target" ] && \
       [ "$(_link_canonical "$target")" = "$(_link_canonical "$source")" ]; then
      log_info "✓ up to date: $target_display"
      LOG_SKIPPED=$((LOG_SKIPPED + 1))
      return 0
    fi
    # Case 2: broken or points elsewhere -> recreate (removing a
    # symlink destroys no real data, so no backup is needed)
    _link_mutate rm -f "$target"
    _link_create "$source" "$target"
    _link_done repaired "♻️  recreated link: $target_display -> $source"
    return 0
  fi

  # --- Case 3: target is real data (file or dir) -------------------
  if [ -e "$target" ]; then
    case "$conflict" in
      fail)
        log_error "target exists and conflict=fail: $target_display"
        LOG_FAILED=$((LOG_FAILED + 1))
        return 1
        ;;
      skip)
        log_warn "⏭  target exists, conflict=skip: $target_display"
        LOG_SKIPPED=$((LOG_SKIPPED + 1))
        return 0
        ;;
      backup)
        _link_backup "$target"
        _link_create "$source" "$target"
        _link_done created "🔗 linked (after backup): $target_display -> $source"
        return 0
        ;;
      *)
        log_error "unknown conflict policy: $conflict"
        LOG_FAILED=$((LOG_FAILED + 1))
        return 1
        ;;
    esac
  fi

  # --- Case 4: nothing at target -----------------------------------
  _link_create "$source" "$target"
  _link_done created "🔗 linked: $target_display -> $source"
  return 0
}
