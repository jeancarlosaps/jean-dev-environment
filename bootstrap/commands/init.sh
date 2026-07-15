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
#   6. point git's global core.hooksPath at <repo>/git/hooks (AI guard)
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

# Global hooksPath -> the AI-guard hooks. Same philosophy as the master
# symlink: if it already points elsewhere, warn and leave it untouched.
_init_git_hooks() {
  local hooks="$DEV_ENV_STABLE/git/hooks" current
  current=$(git config --global core.hooksPath 2>/dev/null || true)
  if [ "$current" = "$hooks" ]; then
    log_info "✓ global core.hooksPath already correct: ${hooks/#$HOME/~}"
    return 0
  fi
  if [ -n "$current" ]; then
    log_error "core.hooksPath already set elsewhere: $current"
    log_warn "leaving it untouched; resolve manually"
    return 1
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "git config --global core.hooksPath ${hooks/#$HOME/~}"
    return 0
  fi
  git config --global core.hooksPath "$hooks"
  log_ok "🪝 global core.hooksPath -> ${hooks/#$HOME/~} (AI guard active)"
}

# The dev-env repo is authorized to version AI artifacts (they ARE its
# content). Authorization is per-repo local git config — never a path
# or name check — so any other repo needs the same explicit opt-in:
#   git config ai-guard.allowArtifacts true
_init_ai_guard_allow_self() {
  local current
  current=$(git -C "$DEV_ENV_HOME" config --bool ai-guard.allowartifacts 2>/dev/null || true)
  if [ "$current" = "true" ]; then
    log_info "✓ dev-env repo already authorized for AI artifacts"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "git -C <dev-env> config ai-guard.allowArtifacts true"
    return 0
  fi
  git -C "$DEV_ENV_HOME" config ai-guard.allowArtifacts true
  log_ok "🔓 dev-env repo authorized to version its own AI content"
}

# git only falls back to ~/.config/git/ignore when core.excludesfile is
# unset; a legacy excludesfile silently disables everything we write
# there. Detect and warn (never rewrite the user's config).
_init_git_excludes_check() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore" current
  current=$(git config --global core.excludesfile 2>/dev/null || true)
  case "$current" in
    ""|"$xdg"|"~/.config/git/ignore")
      return 0 ;;
  esac
  log_warn "core.excludesfile aponta para ${current/#$HOME/~};"
  log_warn "o ignore global do dev-env (~/.config/git/ignore) NÃO terá efeito."
  log_warn "consolide os padrões em um único arquivo ou remova a config legada."
}

cmd_init() {
  log_step "dev-env init"
  local rc=0
  _init_master_symlink || rc=1
  _init_structure
  _init_manifest || rc=1
  _init_git_ignore
  _init_git_excludes_check
  _init_path
  _init_git_hooks || rc=1
  _init_ai_guard_allow_self
  if [ "$rc" -eq 0 ]; then
    log_ok "init complete"
  else
    log_warn "init finished with warnings (see above)"
  fi
  return "$rc"
}
