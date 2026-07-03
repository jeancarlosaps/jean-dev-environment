#!/bin/bash
# =====================================================================
# commands/init.sh - one-time-per-machine setup
# ---------------------------------------------------------------------
# Idempotent. Safe to re-run. Never overwrites existing data.
#
#   1. master symlink  ~/Developer/dev-env -> <repo>
#   2. ensure ai/ structure exists
#   3. validate the manifest
#   4. wire git's global ignore (~/.config/git/ignore)
#   5. put <repo>/bin on PATH via a marked block in ~/.zshrc
#
# Globals expected from bin/dev-env:
#   DEV_ENV_HOME   absolute path of the repo (real)
#   DEV_ENV_STABLE stable alias path (~/Developer/dev-env)
#   MANIFEST       path to manifest/links.yaml
#   DRY_RUN        0|1
# =====================================================================

# entries that must never be tracked/removed inside client repos
INIT_IGNORE_ENTRIES=".agents
.claude
.cursor
_bmad
.mcp.json"

_init_master_symlink() {
  local link="$DEV_ENV_STABLE" target="$DEV_ENV_HOME"
  if [ -L "$link" ]; then
    if [ "$(_link_canonical "$link")" = "$(_link_canonical "$target")" ]; then
      log_info "✓ master symlink already correct: ${link/#$HOME/~}"
      return 0
    fi
    log_error "master path exists and points elsewhere: ${link/#$HOME/~} -> $(readlink "$link")"
    log_warn "leaving it untouched; resolve manually to avoid data loss"
    return 1
  fi
  if [ -e "$link" ]; then
    log_error "master path exists as real data (not a symlink): ${link/#$HOME/~}"
    log_warn "leaving it untouched"
    return 1
  fi
  local parent
  parent=$(dirname "$link")
  [ -d "$parent" ] || mutate mkdir -p "$parent"
  mutate ln -s "$target" "$link"
  log_ok "🔗 master symlink: ${link/#$HOME/~} -> $target"
}

_init_structure() {
  local d
  for d in .agents .claude .cursor _bmad mcp prompts snippets templates knowledge docs; do
    [ -d "$DEV_ENV_HOME/ai/shared/$d" ] || mutate mkdir -p "$DEV_ENV_HOME/ai/shared/$d"
  done
  log_ok "📁 ai/shared structure ensured"
}

_init_manifest() {
  if manifest_validate "$MANIFEST"; then
    log_ok "📜 manifest valid: ${MANIFEST/#$DEV_ENV_HOME\//}"
  else
    log_error "manifest is invalid — fix it before continuing"
    return 1
  fi
}

_init_git_ignore() {
  # word-split the entry list without relying on shell splitting rules
  local args="" e
  while IFS= read -r e; do
    [ -n "$e" ] && args="$args $e"
  done <<EOF
$INIT_IGNORE_ENTRIES
EOF
  # shellcheck disable=SC2086
  git_ignore_global_ensure $args
}

# Managed PATH block, delimited so it can be updated/removed cleanly and
# never duplicated. If the markers already exist, the block is replaced
# in place instead of appending a second one.
_init_path() {
  local rc="$HOME/.zshrc" bindir="$DEV_ENV_STABLE/bin"
  local open="# >>> dev-env >>>" close="# <<< dev-env <<<"
  local desired existing tmp
  desired=$(printf '%s\nexport PATH="%s:$PATH"\n%s' "$open" "$bindir" "$close")

  if [ -f "$rc" ] && grep -qF "$open" "$rc" 2>/dev/null; then
    # extract current block to see if an update is even needed
    existing=$(awk -v o="$open" -v c="$close" '
      $0 == o { inb = 1 } inb { print } $0 == c { inb = 0 }' "$rc")
    if [ "$existing" = "$desired" ]; then
      log_info "✓ PATH block already present and current in ~/.zshrc"
      return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
      log_dry "update dev-env PATH block in ~/.zshrc"
      return 0
    fi
    tmp=$(mktemp -t devenv_zshrc.XXXXXX) || return 1
    awk -v o="$open" -v c="$close" -v repl="$desired" '
      $0 == o { print repl; skip = 1; next }
      skip && $0 == c { skip = 0; next }
      skip { next }
      { print }' "$rc" > "$tmp" && mv "$tmp" "$rc"
    log_ok "🧭 updated dev-env PATH block in ~/.zshrc"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "append dev-env PATH block -> ~/.zshrc"
    return 0
  fi
  printf '\n%s\n' "$desired" >> "$rc"
  log_ok "🧭 added dev-env/bin to PATH in ~/.zshrc (open a new shell to use 'dev-env')"
}

cmd_init() {
  log_step "dev-env init"
  local rc=0
  _init_master_symlink || rc=1
  _init_structure
  _init_manifest || rc=1
  _init_git_ignore
  _init_path
  if [ "$rc" -eq 0 ]; then
    log_ok "init complete"
  else
    log_warn "init finished with warnings (see above)"
  fi
  return "$rc"
}
