#!/usr/bin/env bash
# =====================================================================
# merge-guard.sh — hook de agente que intercepta merge de PR
# ---------------------------------------------------------------------
# Adaptador entre o hook de shell do agente e scripts/merge-gate.sh.
#
#   Claude Code: PreToolUse, matcher "Bash"   → merge-guard.sh --claude
#   Cursor:      beforeShellExecution          → merge-guard.sh --cursor
#
# Lê o JSON do hook no stdin e decide só para comandos que integram
# código numa branch:
#   - gh pr merge (inclusive --auto), gh api .../pulls/<n>/merge;
#   - git push com destino em branch oficial (main, master, dev,
#     develop, release/*, epic/*, project/*).
# Qualquer outro comando sai sem decisão: o fluxo normal de permissões
# do agente continua valendo.
#
# Decisões possíveis: deny ou ask. Este hook nunca concede permissão:
# CI verde e aprovações suficientes viram "ask", e a confirmação humana
# no prompt do agente é a autorização do merge.
#
# Falha segura (deny): política ausente, gate ausente, erro de leitura
# do GitHub, jq ausente, PR não identificado, forma de merge não
# reconhecida (texto que parece merge e não foi identificado: GraphQL,
# HTTP direto, alias do gh, script em arquivo, subshell).
#
# Exceção de aprovações: só quando a política do repositório prevê uma
# regra de exceção (4ª coluna do TSV) e o único BLOCKER é o número de
# aprovações. O hook abre um diálogo nativo do macOS (osascript) que
# exige digitar o número do PR. Sem diálogo confirmado: deny. Com
# diálogo confirmado: ask — a autorização do merge continua separada.
# O texto do comando nunca concede exceção.
#
# Instalação: o comando do hook nas configurações do agente precisa ser
# fail-closed também quando ESTE arquivo não existir (um hook que não
# roda não bloqueia nada). Comando de referência para o Claude Code
# (PreToolUse, matcher "Bash"; G e P são o diretório estável e a política):
#
#   G="$HOME/Developer/dev-env/scripts/merge-guard.sh"; P="<política.tsv>"; I=$(cat);
#   if [ -r "$G" ]; then printf '%s' "$I" | MERGE_GATE_POLICY_FILE="$P" bash "$G" --claude
#   || { echo "merge-guard falhou" >&2; exit 2; };
#   else case "$I" in *merge*|*push*) echo "merge-guard ausente: $G" >&2; exit 2;; esac; fi
#
# Status 2 bloqueia a chamada no Claude Code; qualquer outro status de
# erro deixa a chamada seguir.
# =====================================================================
set -u
set -f

SCRIPT_DIR=$(cd -P "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/merge-gate.sh"
OFFICIAL_RE='^(refs/heads/)?(main|master|dev|develop|release/.+|epic/.+|project/.+)$'
MERGE_LIKE_RE='pr[^A-Za-z0-9]{1,8}merge([^A-Za-z0-9-]|$)|pulls/[^[:space:]]*/merge([^A-Za-z0-9_]|$)|mergePullRequest|enablePullRequestAutoMerge'
EXCEPTION_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/merge-guard/exceptions.log"

mode="${1:-}"
case "$mode" in --claude|--cursor) ;; *) echo "uso: merge-guard.sh --claude|--cursor" >&2; exit 2 ;; esac

input=$(cat)

emit() {
  local decision="$1" reason="$2"
  if command -v jq >/dev/null 2>&1; then
    if [ "$mode" = --claude ]; then
      jq -n --arg d "$decision" --arg r "$reason" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
    else
      jq -n --arg d "$decision" --arg r "$reason" '{permission: $d, userMessage: $r, agentMessage: $r}'
    fi
  else
    reason=$(printf '%s' "$reason" | tr -d '"\\')
    if [ "$mode" = --claude ]; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$decision" "$reason"
    else
      printf '{"permission":"%s","userMessage":"%s","agentMessage":"%s"}\n' "$decision" "$reason" "$reason"
    fi
  fi
}

decide() {
  emit "$1" "$2"
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  case "$input" in
    *merge*|*push*) decide deny "merge-guard: jq ausente; operação de integração bloqueada" ;;
    *) exit 0 ;;
  esac
fi

if [ "$mode" = --claude ]; then
  command_line=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  command_line=$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)
fi
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$command_line" ] || exit 0

# Desligar hooks pelo shell desliga este guard. A edição do mesmo
# arquivo pelas ferramentas de edição do agente não passa por aqui.
case "$command_line" in
  *disableAllHooks*) decide deny "merge-guard: comando altera disableAllHooks; desligar hooks exige ação humana direta" ;;
esac

# file_mentions_merge <arquivo>: script local que contém merge.
file_mentions_merge() {
  local f="$1"
  case "$f" in /*) ;; *) [ -n "$cwd" ] && f="$cwd/$f" ;; esac
  [ -f "$f" ] && [ -r "$f" ] || return 1
  # -I: binário (ex.: o próprio executável do gh) não é script
  grep -IqE "$MERGE_LIKE_RE" "$f" 2>/dev/null
}

# alias_is_merge <nome>: alias do gh cuja expansão faz merge.
alias_is_merge() {
  command -v gh >/dev/null 2>&1 || return 1
  gh alias list 2>/dev/null | awk -F': ' -v n="$1" '$1 == n { print $2 }' | grep -qE "$MERGE_LIKE_RE|merge"
}

# Divide o comando em segmentos (;, &&, ||, |, &, quebra de linha).
# Aspas não são interpretadas: texto citado também é avaliado (falso
# positivo seguro).
segments=$(printf '%s\n' "$command_line" | awk '{ gsub(/&&|\|\||[;|&]/, "\n"); print }')

pr_number="" pr_repo="" head_sha="" kind="" admin=0 push_targets=""
merges=0 ambiguous=0 indirect=""

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | tr -d "\"'\\\\")
  # shellcheck disable=SC2086
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*) shift; continue ;; esac
    case "${1##*/}" in
      env|command|exec|eval|sudo|nohup|time|xargs|builtin|nice) shift ;;
      bash|sh|zsh|dash|ksh|source|.) shift; while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do shift; done ;;
      '('|'{'|'$('|'`') shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || continue

  # script local executado diretamente ou por interpretador
  case "${1##*/}" in
    python|python3|node|ruby|perl|osascript)
      [ $# -gt 1 ] && file_mentions_merge "$2" && indirect="script $2" ;;
    *)
      file_mentions_merge "$1" && indirect="script $1" ;;
  esac

  case "${1##*/}" in
    gh)
      shift
      repo_flag="" rest=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -R|--repo) repo_flag="${2:-}"; shift 2 ;;
          --repo=*) repo_flag="${1#--repo=}"; shift ;;
          *) rest="$rest $1"; shift ;;
        esac
      done
      # shellcheck disable=SC2086
      set -- $rest
      case "${1:-}" in
        pr|api|repo|issue|run|workflow|release|auth|alias|search|browse|status|label|secret|variable|cache|codespace|gist|org|project|ruleset|attestation|config|extension|gpg-key|ssh-key|completion|help|version|"") ;;
        *) alias_is_merge "$1" && indirect="alias do gh '$1'" ;;
      esac
      if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
        kind=pr; merges=$((merges + 1)); shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            --admin) admin=1; shift ;;
            --match-head-commit) head_sha="${2:-}"; shift 2 ;;
            --match-head-commit=*) head_sha="${1#*=}"; shift ;;
            -t|--subject|-b|--body|-F|--body-file|-A|--author-email) shift 2 ;;
            -*) shift ;;
            *)
              [ -z "$pr_number" ] || ambiguous=1
              case "$1" in
                https://github.com/*/pull/*)
                  pr_repo=$(printf '%s' "$1" | sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
                  pr_number=$(printf '%s' "$1" | sed -E 's#.*/pull/([0-9]+).*#\1#') ;;
                *) pr_number="$1" ;;
              esac
              shift ;;
          esac
        done
        [ -n "$pr_repo" ] || pr_repo="$repo_flag"
      elif [ "${1:-}" = api ]; then
        api_path=$(printf '%s' "$seg" | grep -oE 'repos/[^/ ]+/[^/ ]+/pulls/[0-9]+/merge([^A-Za-z_]|$)' | head -1)
        if [ -n "$api_path" ]; then
          kind=pr; merges=$((merges + 1))
          pr_repo=$(printf '%s' "$api_path" | cut -d/ -f2-3)
          pr_number=$(printf '%s' "$api_path" | cut -d/ -f5)
        fi
      fi
      ;;
    git)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in -C|-c) shift 2 ;; -*) shift ;; *) break ;; esac
      done
      [ "${1:-}" = push ] || continue
      shift
      positional=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --tags|--follow-tags) shift ;;
          -o|--push-option|--repo|--receive-pack|--exec) shift 2 ;;
          -*) shift ;;
          *) positional="$positional $1"; shift ;;
        esac
      done
      # shellcheck disable=SC2086
      set -- $positional
      [ $# -gt 0 ] && shift   # remote
      if [ $# -eq 0 ]; then
        branch=""
        if [ -n "$cwd" ] && [ -d "$cwd" ]; then
          branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
        fi
        [ -n "$branch" ] && push_targets="$push_targets $branch"
      else
        for spec in "$@"; do
          spec=${spec#+}
          dst=${spec##*:}
          [ -n "$dst" ] || continue
          [ "$dst" = HEAD ] && [ -n "$cwd" ] && dst=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || echo HEAD)
          push_targets="$push_targets $dst"
        done
      fi
      ;;
  esac
done <<EOF
$segments
EOF

UNRECOGNIZED="use um merge por comando: gh pr merge <n> -R owner/repo --match-head-commit <sha>"

[ -z "$indirect" ] || decide deny "merge-guard: merge por $indirect não é avaliável; $UNRECOGNIZED"

# Toda ocorrência com cara de merge no texto precisa ser um merge
# identificado acima; sobra = forma não reconhecida.
hits=$(printf '%s\n' "$command_line" | grep -oE "$MERGE_LIKE_RE" | wc -l | tr -d ' ')
[ "$hits" -le "$merges" ] || decide deny "merge-guard: comando de merge em forma não reconhecida (GraphQL, HTTP, subshell ou texto); $UNRECOGNIZED"

for dst in $push_targets; do
  case "$dst" in refs/tags/*) continue ;; esac
  if printf '%s\n' "$dst" | grep -qE "$OFFICIAL_RE"; then
    decide ask "merge-guard: push direto para a branch oficial '$dst'. Branch oficial só recebe código via PR; confirme apenas com autorização humana expressa para esta operação (ex.: criação da branch)."
  fi
done

[ "$kind" = pr ] || exit 0

[ "$merges" -le 1 ] || decide deny "merge-guard: mais de um merge no mesmo comando; $UNRECOGNIZED"
[ "$ambiguous" -eq 0 ] || decide deny "merge-guard: argumentos ambíguos para identificar o PR; passe o corpo por --body-file e $UNRECOGNIZED"
[ "$admin" -eq 0 ] || decide deny "merge-guard: --admin contorna a proteção do repositório; bypass exige autorização e execução humana direta"
case "$pr_number" in ''|*[!0-9]*) decide deny "merge-guard: PR não identificado; $UNRECOGNIZED" ;; esac
case "$pr_repo" in */*) ;; *) decide deny "merge-guard: repositório não explícito; $UNRECOGNIZED" ;; esac

[ -r "$GATE" ] || decide deny "merge-guard: gate ausente em $GATE; merge bloqueado"

set -- "$pr_number" -R "$pr_repo" --format json
[ -n "$head_sha" ] && set -- "$@" --expect-head "$head_sha"

gate_err=$(mktemp "${TMPDIR:-/tmp}/merge-guard.XXXXXX")
report=$(bash "$GATE" "$@" 2>"$gate_err")
status=$?
gate_msg=$(tail -1 "$gate_err" 2>/dev/null)
rm -f "$gate_err"
if [ "$status" -gt 1 ] || ! printf '%s' "$report" | jq -e '.findings and (.blockers | type == "number")' >/dev/null 2>&1; then
  decide deny "merge-guard: gate não concluiu a avaliação (status $status: ${gate_msg:-sem mensagem}); merge bloqueado"
fi

summary=$(printf '%s' "$report" | jq -r '
  "\(.repo)#\(.number) HEAD \(.head[0:10]) base \(.base); aprovações válidas \(.approvals.valid | length)/\(.approvals.required). "
  + ([.findings[] | select(.severity != "INFO") | "[\(.severity)] \(.rule): \(.evidence)"] | join(" | "))')
AUTH_NOTE="Isto não é autorização: confirme só com autorização humana expressa para o merge deste PR neste HEAD."

# confirm_exception: diálogo nativo; ecoa "ok" só com o número do PR
# digitado e o botão de autorização, sem timeout.
confirm_exception() {
  local rule="$1" text answer
  command -v osascript >/dev/null 2>&1 || return 1
  text="Exceção à política de aprovações

$(printf '%s' "$report" | jq -r '"\(.repo)#\(.number) · HEAD \(.head[0:10]) · base \(.base)\nAprovações válidas: \(.approvals.valid | length) de \(.approvals.required) exigidas."')

Regra de exceção: $rule

Confirmar a exceção NÃO autoriza o merge; a autorização é pedida depois.
Digite o número do PR para confirmar a exceção."
  text=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g')
  answer=$(osascript \
    -e "display dialog \"$text\" default answer \"\" buttons {\"Recusar\", \"Autorizar exceção\"} default button \"Recusar\" cancel button \"Recusar\" with title \"merge-guard\" with icon caution giving up after 120" \
    2>/dev/null) || return 1
  case "$answer" in *"gave up:true"*) return 1 ;; esac
  case "$answer" in *"button returned:Autorizar exceção"*) ;; *) return 1 ;; esac
  [ "$(printf '%s' "$answer" | sed -n 's/.*text returned:\([^,]*\).*/\1/p')" = "$pr_number" ] || return 1
  return 0
}

if [ "$status" -ne 0 ]; then
  eligible=$(printf '%s' "$report" | jq -r '.approvals.exceptionEligible')
  if [ "$eligible" = true ]; then
    rule=$(printf '%s' "$report" | jq -r '.approvals.exceptionRule')
    if confirm_exception "$rule"; then
      mkdir -p "$(dirname "$EXCEPTION_LOG")" 2>/dev/null &&
        printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "$(printf '%s' "$report" | jq -r '"\(.repo)#\(.number)\t\(.head)"')" \
          "$(printf '%s' "$report" | jq -r '"\(.approvals.valid | length)/\(.approvals.required)"')" \
          "$rule" >> "$EXCEPTION_LOG" 2>/dev/null
      decide ask "merge-guard: EXCEÇÃO de aprovações confirmada no diálogo nativo. $summary $AUTH_NOTE"
    fi
    decide deny "merge-guard: BLOQUEADO. Exceção possível ($rule), mas não confirmada no diálogo nativo. $summary"
  fi
  decide deny "merge-guard: BLOQUEADO. $summary"
fi
decide ask "merge-guard: sem BLOCKER técnico. $summary $AUTH_NOTE"
