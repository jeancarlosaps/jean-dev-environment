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
#   7. machine links from the manifest (machine:), relative to $HOME;
#      managed links that left the manifest are retired safely
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
.mcp.json
CLAUDE.md
AGENTS.md
GEMINI.md
.cursorrules"

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

# Machine-level links (manifest `machine:` section), applied with the same
# engine as project links: idempotent, --dry-run aware, and a real file
# at the target is never replaced (conflict policy from the manifest).
# Targets this machine received are recorded in state/machine-links so a
# link removed from the manifest can be retired later — but only while
# it is still a symlink into the dev-env; anything else is left alone.
_init_machine_links() {
  local record="$STATE_DIR/machine-links" declared="" rc=0
  local n i rel_src rel_tgt req cfl tgt prev
  if manifest_has_machine "$MANIFEST"; then
    if ! manifest_load "$MANIFEST" "$MANIFEST_MACHINE"; then
      log_error "could not resolve machine links from the manifest"
      return 1
    fi
    n=$(manifest_link_count)
    i=1
    while [ "$i" -le "$n" ]; do
      rel_src=$(manifest_link_field "$i" source)
      rel_tgt=$(manifest_link_field "$i" target)
      req=$(manifest_link_field "$i" required)
      cfl=$(manifest_link_field "$i" conflict)
      tgt="$HOME/$rel_tgt"
      link_apply "$DEV_ENV_STABLE/$rel_src" "$tgt" "$req" "$cfl" || rc=1
      if [ -e "$tgt" ] && [ ! -L "$tgt" ]; then
        log_warn "   ~/$rel_tgt is your own file and was kept; to use the managed"
        log_warn "   link, move your file away and re-run 'dev-env init'"
      fi
      declared="$declared$rel_tgt
"
      i=$((i + 1))
    done
    manifest_unload
  fi

  # retire links this machine received earlier but the manifest dropped
  if [ -f "$record" ]; then
    while IFS= read -r prev; do
      [ -n "$prev" ] || continue
      printf '%s' "$declared" | grep -qxF "$prev" && continue
      tgt="$HOME/$prev"
      if [ -L "$tgt" ]; then
        case "$(readlink "$tgt")" in
          "$DEV_ENV_STABLE"/*|"$DEV_ENV_HOME"/*)
            mutate rm -f "$tgt"
            [ "${DRY_RUN:-0}" = "1" ] || log_ok "🧹 removed obsolete machine link: ~/$prev"
            continue ;;
        esac
      fi
      [ -e "$tgt" ] && log_warn "obsolete machine entry ~/$prev is not a dev-env link; left untouched"
    done < "$record"
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_dry "record machine links -> state/machine-links"
  else
    mkdir -p "$STATE_DIR" && printf '%s' "$declared" > "$record"
  fi
  return "$rc"
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
  _init_machine_links || rc=1
  _init_ai_guard_allow_self
  if [ "$rc" -eq 0 ]; then
    log_ok "init complete"
  else
    log_warn "init finished with warnings (see above)"
  fi
  return "$rc"
}
