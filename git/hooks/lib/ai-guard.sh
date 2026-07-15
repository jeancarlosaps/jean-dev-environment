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
# authorship is blocked by default; explicit request = AI_GUARD_SKIP=1.
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
