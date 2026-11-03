#!/bin/bash
# =====================================================================
# git/hooks/lib/ai-guard.sh - shared logic for the AI-guard hooks
# ---------------------------------------------------------------------
# Keeps every trace of AI tooling out of git history:
#
#   ai_guard_strip <file>              remove AI trailers in place
#   ai_guard_violations <text>         offending message lines
#   ai_guard_coauthor_violations <text> any Co-Authored-By left over
#   ai_guard_ident_violations          author/committer identity issues
#   ai_guard_staged_ai_files           AI artifacts staged for commit
#   ai_guard_push_commits ...          commits new to this push
#   ai_guard_delegate <name> ...       chain to the repo's own hook
#
# Never modifies author/committer/identity — only blocks invalid ops.
# Bash 3.2, no dependencies.
#
# Maintenance mode: AI_GUARD_MAINTENANCE=1 skips the guard (delegation
# still runs). It exists ONLY for conscious maintenance of the dev
# environment itself — never for day-to-day work in client or personal
# repos — and every use prints a loud warning so it cannot slip by
# unnoticed.
#
# Artifact allowlist: a repo explicitly authorized to version AI
# artifacts opts in via local git config (never versioned):
#   git config ai-guard.allowArtifacts true
# =====================================================================

# Names of AI tools, in any grammatical position. Used for identity and
# bot checks (names/emails), where false positives are near-impossible.
AI_GUARD_TOOLS='claude|cursor|chatgpt|gpt-[0-9]|openai|anthropic|copilot|gemini|codeium|cline|roo[- ]?code|windsurf|deepseek|qwen|codex|devin|aider|tabnine|amazon[- ]?q|jetbrains[- ]?ai|sourcegraph|cody|continue\.dev'

# Trailer/signature lines that are removed silently. One ERE, applied
# case-insensitively per line.
AI_GUARD_STRIP_RE="^[[:space:]]*((🤖[[:space:]]*)?generated with|generated-by:|assisted-by:|co-authored-by:.*($AI_GUARD_TOOLS|\\[bot\\]|noreply@anthropic|noreply@openai))"

# Free-text mentions that BLOCK the operation. "cursor" alone is a
# legitimate UI word (pt/en), so only unambiguous tool combinations
# match for it. Same reasoning excludes bare "continue"/"cody"/"roo".
AI_GUARD_BLOCK_RE='(claude|copilot|chatgpt|gpt-[0-9]|openai|anthropic|gemini|codeium|cline|roo[- ]code|windsurf|deepseek|qwen|codex|devin|aider|cursor[[:space:]]*(ai|agent|ide)|cursor\.(com|sh)|ai[- ]generated|ai[- ]assisted|generated (with|by) ai|gerad[oa] (por|com) ia|assistid[oa] por ia|powered by (ai|claude|cursor|copilot))'

# Identity patterns that can never appear as author or committer:
# tool names, GitHub bots/apps, actions, AI vendor noreply addresses.
AI_GUARD_IDENT_RE="($AI_GUARD_TOOLS|\\[bot\\]|github-actions|dependabot|bot@|noreply@anthropic|noreply@openai|users\\.noreply\\.github\\.com.*\\[bot\\])"

# AI artifacts that must never be versioned (any repo, client or
# personal). Matched against staged paths, case-insensitively.
AI_GUARD_FILES_RE='(^|/)(\.claude|\.cursor|\.cursorrules|\.cursorignore|\.clinerules|\.windsurfrules|\.aider[^/]*|\.continue|\.roo|\.agents|_bmad|\.mcp\.json|CLAUDE\.md|AGENTS\.md|GEMINI\.md|claude[-_]?(memory|settings|session)[^/]*|\.ai[-_]?cache)(/|$)|(^|/)\.github/(copilot[^/]*|instructions[^/]*|prompts|chatmodes)(/|$)'

# ai_guard_strip <file>
# Deletes strip-matching lines from a commit-message file, then trims
# trailing blank lines. In-place, no-op when nothing matches.
ai_guard_strip() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  grep -qiE "$AI_GUARD_STRIP_RE" "$file" || return 0
  tmp="${file}.ai-guard.$$"
  grep -viE "$AI_GUARD_STRIP_RE" "$file" |
    awk '{ lines[NR] = $0 } END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }' > "$tmp" && mv "$tmp" "$file"
}

# ai_guard_violations <text>
# Prints lines that mention an AI tool. Git comment lines and anything
# below a scissors marker are ignored.
ai_guard_violations() {
  printf '%s\n' "$1" |
    awk '/^# -+ >8 -+/ { exit } !/^#/ { print }' |
    grep -iE "$AI_GUARD_BLOCK_RE"
}

# ai_guard_coauthor_violations <text>
# Any Co-Authored-By that survived the strip (i.e. not an AI one) still
# creates a second author on GitHub ("X and Y committed"). Multiple
# authorship is always blocked here; the only bypass is the environment's
# maintenance mode (AI_GUARD_MAINTENANCE=1), checked by the hooks.
ai_guard_coauthor_violations() {
  printf '%s\n' "$1" |
    awk '/^# -+ >8 -+/ { exit } !/^#/ { print }' |
    grep -iE '^[[:space:]]*co-authored-by:'
}

# ai_guard_ident_violations
# Inspects the EFFECTIVE author/committer of the commit being created
# (git var resolves env overrides like GIT_AUTHOR_NAME / --author).
# Blocks when:
#   - author or committer matches an AI tool / bot pattern;
#   - committer differs from the repo's configured user.name/user.email
#     (the committer is always the person at the keyboard).
# The author is allowed to differ from config as long as it is not an
# AI/bot: rebasing or cherry-picking a teammate's commit legitimately
# preserves their authorship. Never rewrites anything — only reports.
ai_guard_ident_violations() {
  local a c cfg_name cfg_email c_name c_email
  a=$(git var GIT_AUTHOR_IDENT 2>/dev/null) || return 0
  c=$(git var GIT_COMMITTER_IDENT 2>/dev/null) || return 0
  a=${a% [0-9]*}   # drop "timestamp tz"
  c=${c% [0-9]*}
  cfg_name=$(git config user.name 2>/dev/null)
  cfg_email=$(git config user.email 2>/dev/null)
  c_name=${c% <*}
  c_email=${c##*<}; c_email=${c_email%>}

  printf '%s\n' "$a" | grep -qiE "$AI_GUARD_IDENT_RE" &&
    echo "autor com identidade de ferramenta/bot: $a"
  printf '%s\n' "$c" | grep -qiE "$AI_GUARD_IDENT_RE" &&
    echo "committer com identidade de ferramenta/bot: $c"
  if [ -z "$cfg_name" ] || [ -z "$cfg_email" ]; then
    echo "user.name/user.email não configurados neste repositório"
  elif [ "$c_name" != "$cfg_name" ] || [ "$c_email" != "$cfg_email" ]; then
    echo "committer ($c) difere da identidade configurada ($cfg_name <$cfg_email>)"
  fi
  return 0
}

# ai_guard_staged_ai_files
# Prints staged paths that are AI artifacts. These live locally only
# (dev-env symlinks + .git/info/exclude); versioning one is always a
# mistake unless explicitly requested.
ai_guard_staged_ai_files() {
  git diff --cached --name-only --no-renames 2>/dev/null |
    grep -iE "$AI_GUARD_FILES_RE"
}

# ai_guard_maintenance
# True only when AI_GUARD_MAINTENANCE=1. Loud on purpose: maintenance
# of the environment itself is the single legitimate reason to bypass
# the guard, and an accidental leftover export must be impossible to
# miss.
ai_guard_maintenance() {
  [ "${AI_GUARD_MAINTENANCE:-0}" = "1" ] || return 1
  cat >&2 <<'EOF'
!!! [ai-guard] MODO MANUTENÇÃO ATIVO — proteções de IA IGNORADAS nesta
!!! operação. Uso legítimo: manutenção consciente do dev-env, nunca
!!! trabalho normal em repositório de cliente ou pessoal.
!!! Remova AI_GUARD_MAINTENANCE do ambiente ao terminar.
EOF
  return 0
}

# ai_guard_artifacts_allowed
# True when this repository was explicitly authorized to version AI
# artifacts (local git config, set per repo by the developer — the
# dev-env's own repo gets it via 'dev-env init').
ai_guard_artifacts_allowed() {
  [ "$(git config --bool ai-guard.allowartifacts 2>/dev/null)" = "true" ]
}

# ai_guard_star_count <text>
ai_guard_star_count() {
  local rest="$1" n=0
  while true; do
    case "$rest" in
      *'*'*) n=$((n + 1)); rest="${rest#*\*}" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$n"
}

# ai_guard_ref_matches <ref> <pattern>
# A single * matches across slashes, including the empty string.
ai_guard_ref_matches() {
  local ref="$1" pattern="$2"
  local prefix suffix rest
  case "$pattern" in
    *'*'*)
      prefix="${pattern%%\**}"
      suffix="${pattern#*\*}"
      case "$ref" in
        "$prefix"*"$suffix") ;;
        *) return 1 ;;
      esac
      rest="${ref#"$prefix"}"
      if [ -n "$suffix" ]; then
        rest="${rest%"$suffix"}"
      fi
      [ "$ref" = "${prefix}${rest}${suffix}" ]
      ;;
    *)
      [ "$ref" = "$pattern" ]
      ;;
  esac
}

# ai_guard_refspec_dest <ref> <src> <dst>
# Prints the local destination when <ref> matches the fetch source.
# Returns 1 when this pattern does not apply. A single * matches across
# slashes, including the empty string, and may be followed by a suffix.
ai_guard_refspec_dest() {
  local ref="$1" src="$2" dst="$3"
  local prefix suffix rest dpre dsuf
  case "$src" in
    *'*'*)
      ai_guard_ref_matches "$ref" "$src" || return 1
      prefix="${src%%\**}"
      suffix="${src#*\*}"
      rest="${ref#"$prefix"}"
      if [ -n "$suffix" ]; then
        rest="${rest%"$suffix"}"
      fi
      dpre="${dst%%\**}"
      dsuf="${dst#*\*}"
      printf '%s\n' "${dpre}${rest}${dsuf}"
      ;;
    *)
      [ "$ref" = "$src" ] || return 1
      printf '%s\n' "$dst"
      ;;
  esac
}

# ai_guard_url_key <url>
# Drops a trailing slash and a trailing .git so equivalent addresses compare.
ai_guard_url_key() {
  local u="$1"
  u="${u%/}"
  case "$u" in
    *.git) u="${u%.git}" ;;
  esac
  printf '%s\n' "$u"
}

# ai_guard_looks_like_destination <token>
# True for URLs, scp-style addresses and paths. A plain remote name is false.
ai_guard_looks_like_destination() {
  case "$1" in
    *://*|*@*:*|/*|./*|../*|*/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ai_guard_remote_url_keys <name>
# Prints every configured fetch and push URL, one normalized key per line.
ai_guard_remote_url_keys() {
  local name="$1" line key
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(ai_guard_url_key "$line")
    [ -n "$key" ] || continue
    printf '%s\n' "$key"
  done <<EOF
$(git remote get-url --all "$name" 2>/dev/null || true)
$(git remote get-url --all --push "$name" 2>/dev/null || true)
EOF
}

# ai_guard_remote_names <token> <url>
# Prints every configured remote for this push, including aliases that share
# a fetch or push URL. A plain remote name is kept and the comparison
# continues. An address that matches no remote is rejected. Returns 1 in
# that case.
ai_guard_remote_names() {
  local token="$1" url="$2"
  local name="" key="" matched=0 keys="" listed=""
  keys=$(mktemp "${TMPDIR:-/tmp}/ai-guard-url-keys.XXXXXX") || return 1
  key=$(ai_guard_url_key "$url")
  [ -n "$key" ] && printf '%s\n' "$key" >>"$keys"
  if ai_guard_looks_like_destination "$token"; then
    key=$(ai_guard_url_key "$token")
    [ -n "$key" ] && printf '%s\n' "$key" >>"$keys"
  elif [ -n "$token" ] && git config --get-regexp "^remote\\.${token}\\." >/dev/null 2>&1; then
    ai_guard_remote_url_keys "$token" >>"$keys"
    printf '%s\n' "$token"
    listed="${listed}
${token}"
    matched=1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s\n' "$listed" | grep -Fxq -- "$name" && continue
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if grep -Fxq -- "$key" "$keys"; then
        printf '%s\n' "$name"
        listed="${listed}
${name}"
        matched=1
        break
      fi
    done <<EOF
$(ai_guard_remote_url_keys "$name")
EOF
  done <<EOF
$(git remote)
EOF
  rm -f "$keys"
  [ "$matched" -eq 1 ] && return 0
  if ai_guard_looks_like_destination "$token"; then
    echo "estado inconsistente: remoto do push não identificado" >&2
    return 1
  fi
  printf '%s\n' "$token"
  return 0
}

# ai_guard_tracking_refs <remote_name> <remote_ref>
# Prints the local tracking refs that correspond to this destination.
# Uses remote.<name>.fetch when it exists. Without that config, only a
# refs/heads/* push falls back to refs/remotes/<remote>/<branch>. A tag
# never selects a branch-tracking ref just because the short names match.
# Returns 1 when a configured refspec cannot be interpreted.
ai_guard_tracking_refs() {
  local remote_name="$1" remote_ref="$2"
  local specs="" spec src dst dest src_stars dst_stars
  if ! specs=$(git config --get-all "remote.${remote_name}.fetch" 2>/dev/null); then
    specs=""
  fi
  if [ -z "$specs" ]; then
    case "$remote_ref" in
      refs/heads/*)
        [ -n "$remote_name" ] || return 0
        printf 'refs/remotes/%s/%s\n' "$remote_name" "${remote_ref#refs/heads/}"
        ;;
    esac
    return 0
  fi
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    case "$spec" in
      ^*) continue ;;
    esac
    spec="${spec#+}"
    case "$spec" in
      *:*) ;;
      *)
        echo "estado inconsistente: refspec de fetch sem destino (${spec})" >&2
        return 1
        ;;
    esac
    src="${spec%%:*}"
    dst="${spec#*:}"
    [ -n "$dst" ] || continue
    src_stars=$(ai_guard_star_count "$src")
    dst_stars=$(ai_guard_star_count "$dst")
    if [ "$src_stars" -gt 1 ] || [ "$dst_stars" -gt 1 ] || [ "$src_stars" -ne "$dst_stars" ]; then
      echo "estado inconsistente: refspec de fetch com curinga inválido (${spec})" >&2
      return 1
    fi
    dest=$(ai_guard_refspec_dest "$remote_ref" "$src" "$dst") || continue
    [ -n "$dest" ] || continue
    printf '%s\n' "$dest"
  done <<EOF
$specs
EOF
}

# ai_guard_prepare_push <remote_name> <remote_url> <stdin> <skipfile> <authfile>
# Records the tracking refs of every update in this push and the remote
# SHAs received on stdin. Those SHAs are the server state and replace the
# local tracking objects of the same destinations. Returns 1 when the
# remote or a fetch refspec cannot be resolved.
ai_guard_prepare_push() {
  local remote_name="$1" remote_url="$2" input="$3" skipfile="$4" authfile="$5"
  local names="" name="" local_ref="" local_sha="" remote_ref="" remote_sha=""
  : >"$skipfile"
  : >"$authfile"
  if ! names=$(ai_guard_remote_names "$remote_name" "$remote_url"); then
    return 1
  fi
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    case "$remote_sha" in
      ''|*[!0]*)
        [ -n "$remote_sha" ] && printf '%s\n' "$remote_sha" >>"$authfile"
        ;;
    esac
    case "$local_sha" in
      *[!0]*) ;;
      *) continue ;;
    esac
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if ! ai_guard_tracking_refs "$name" "$remote_ref" >>"$skipfile"; then
        return 1
      fi
    done <<EOF
$names
EOF
  done <<EOF
$input
EOF
}

# ai_guard_append_published <outfile>
# Appends ref, object and symref for refs/remotes and for fetch destinations
# stored outside refs/heads. refs/heads stays out: those commits are not
# published. Returns 1 when a fetch refspec cannot be interpreted.
ai_guard_append_published() {
  local outfile="$1"
  local errfile listfile remote specs spec src dst prefix ref sha symref
  errfile=$(mktemp "${TMPDIR:-/tmp}/ai-guard-published.XXXXXX") || return 1
  listfile=$(mktemp "${TMPDIR:-/tmp}/ai-guard-published-list.XXXXXX") || {
    rm -f "$errfile"
    return 1
  }
  if ! git for-each-ref --format='%(refname) %(objectname) %(symref)' refs/remotes >>"$outfile" 2>"$errfile"; then
    echo "estado inconsistente: não foi possível ler as refs remotas conhecidas" >&2
    cat "$errfile" >&2
    rm -f "$errfile" "$listfile"
    return 1
  fi
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    if ! specs=$(git config --get-all "remote.${remote}.fetch" 2>/dev/null); then
      specs=""
    fi
    [ -n "$specs" ] || continue
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      case "$spec" in
        ^*) continue ;;
      esac
      spec="${spec#+}"
      case "$spec" in
        *:*) ;;
        *)
          echo "estado inconsistente: refspec de fetch sem destino (${spec})" >&2
          rm -f "$errfile" "$listfile"
          return 1
          ;;
      esac
      src="${spec%%:*}"
      dst="${spec#*:}"
      [ -n "$dst" ] || continue
      case "$dst" in
        refs/heads|refs/heads/*) continue ;;
      esac
      if [ "$(ai_guard_star_count "$src")" -gt 1 ] || [ "$(ai_guard_star_count "$dst")" -gt 1 ] || \
        [ "$(ai_guard_star_count "$src")" -ne "$(ai_guard_star_count "$dst")" ]; then
        echo "estado inconsistente: refspec de fetch com curinga inválido (${spec})" >&2
        rm -f "$errfile" "$listfile"
        return 1
      fi
      case "$dst" in
        *'*'*) prefix="${dst%%\**}" ;;
        *) prefix="$dst" ;;
      esac
      [ -n "$prefix" ] || {
        echo "estado inconsistente: refspec de fetch amplo demais (${spec})" >&2
        rm -f "$errfile" "$listfile"
        return 1
      }
      case "$prefix" in
        refs/heads|refs/heads/*) continue ;;
      esac
      if ! git for-each-ref --format='%(refname) %(objectname) %(symref)' "$prefix" >"$listfile" 2>"$errfile"; then
        echo "estado inconsistente: não foi possível ler o espelho ${prefix}" >&2
        cat "$errfile" >&2
        rm -f "$errfile" "$listfile"
        return 1
      fi
      while read -r ref sha symref; do
        [ -n "$ref" ] || continue
        case "$ref" in
          refs/heads|refs/heads/*) continue ;;
        esac
        ai_guard_ref_matches "$ref" "$dst" || continue
        printf '%s %s %s\n' "$ref" "$sha" "$symref" >>"$outfile"
      done <"$listfile"
    done <<EOF
$specs
EOF
  done <<EOF
$(git remote)
EOF
  rm -f "$errfile" "$listfile"
  return 0
}

# ai_guard_push_commits <remote_name> <local_ref> <local_sha> <remote_ref> <remote_sha> [remote_url] [skipfile] [authfile]
# Prints commits introduced by this ref update. A commit is included only
# when it is reachable from local_sha and not reachable from the remote
# SHAs received on stdin for this push, nor from any other published ref.
# Tracking refs of every destination in the push are not exclusions: the
# stdin SHAs are the server state, including when another update in the
# same push still has a stale local copy. Fetch destinations outside
# refs/remotes count as published. refs/heads does not. A remote_sha made
# only of zeros means the destination ref does not exist yet. Does not use
# HEAD~1. Returns 1, with no SHAs on stdout, when the range cannot be
# determined.
ai_guard_push_commits() {
  local remote_name="$1" local_ref="$2" local_sha="$3" remote_ref="$4" remote_sha="$5"
  local remote_url="${6:-}" shared_skip="${7:-}" shared_auth="${8:-}"
  local ref="" sha="" symref="" errfile="" outfile="" skipfile="" status=0
  local names="" name="" auth="" own_skip=0
  local -a exclude

  case "$remote_sha" in
    ''|*[!0]*) ;;
    *) remote_sha="" ;;
  esac

  errfile=$(mktemp "${TMPDIR:-/tmp}/ai-guard-push-err.XXXXXX") || return 1
  outfile=$(mktemp "${TMPDIR:-/tmp}/ai-guard-push-out.XXXXXX") || {
    rm -f "$errfile"
    return 1
  }
  if [ -n "$shared_skip" ]; then
    skipfile="$shared_skip"
  else
    skipfile=$(mktemp "${TMPDIR:-/tmp}/ai-guard-push-skip.XXXXXX") || {
      rm -f "$errfile" "$outfile"
      return 1
    }
    own_skip=1
    if ! names=$(ai_guard_remote_names "$remote_name" "$remote_url"); then
      rm -f "$errfile" "$outfile" "$skipfile"
      return 1
    fi
    : >"$skipfile"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if ! ai_guard_tracking_refs "$name" "$remote_ref" >>"$skipfile"; then
        rm -f "$errfile" "$outfile" "$skipfile"
        return 1
      fi
    done <<EOF
$names
EOF
  fi

  : >"$outfile"
  if ! ai_guard_append_published "$outfile" 2>"$errfile"; then
    [ -s "$errfile" ] && cat "$errfile" >&2
    rm -f "$errfile" "$outfile"
    [ "$own_skip" -eq 1 ] && rm -f "$skipfile"
    return 1
  fi

  exclude=()
  [ -n "$remote_sha" ] && exclude+=("$remote_sha")
  if [ -n "$shared_auth" ]; then
    while IFS= read -r auth; do
      [ -n "$auth" ] || continue
      exclude+=("$auth")
    done <"$shared_auth"
  fi
  while read -r ref sha symref; do
    [ -n "$ref" ] || continue
    [ -n "$sha" ] || continue
    if [ -s "$skipfile" ] && grep -Fxq -- "$ref" "$skipfile"; then
      continue
    fi
    if [ -n "$symref" ] && [ -s "$skipfile" ] && grep -Fxq -- "$symref" "$skipfile"; then
      continue
    fi
    exclude+=("$sha")
  done <"$outfile"

  : >"$errfile"
  if [ "${#exclude[@]}" -eq 0 ]; then
    git rev-list "$local_sha" >"$outfile" 2>"$errfile"
  else
    git rev-list "$local_sha" --not "${exclude[@]}" >"$outfile" 2>"$errfile"
  fi
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ ! -s "$errfile" ]; then
      echo "ref remota ausente ou estado inconsistente ao listar commits novos de ${local_ref}" >&2
    else
      cat "$errfile" >&2
    fi
    rm -f "$errfile" "$outfile"
    [ "$own_skip" -eq 1 ] && rm -f "$skipfile"
    return 1
  fi

  cat "$outfile"
  rm -f "$errfile" "$outfile"
  [ "$own_skip" -eq 1 ] && rm -f "$skipfile"
  return 0
}

# ai_guard_delegate <hook-name> [args...]
# Chains to the repository's own hook (corporate hooks live in
# .git/hooks; with a global core.hooksPath git would not run them, so
# we do). stdin is inherited — callers that consumed stdin must re-feed
# it themselves instead of using this helper.
ai_guard_delegate() {
  local name="$1"; shift
  local gitdir repo_hook
  gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 0
  repo_hook="$gitdir/hooks/$name"
  if [ -x "$repo_hook" ]; then
    "$repo_hook" "$@"
    return $?
  fi
  return 0
}

ai_guard_block_message() {
  local hook="$1" title="$2" lines="$3"
  cat >&2 <<EOF

✗ [$hook] $title:

$lines

Política: todo histórico Git deve parecer trabalho manual do
desenvolvedor — sem ferramentas de IA, bots, coautoria ou identidade
divergente. Corrija e tente de novo.
(AI_GUARD_MAINTENANCE=1 existe apenas para manutenção consciente do
próprio ambiente — nunca para contornar o guard em trabalho normal.)
EOF
}
