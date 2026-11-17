#!/usr/bin/env bash
# =====================================================================
# merge-guard.sh — hook de agente que intercepta merge de PR
# ---------------------------------------------------------------------
# Adaptador entre o hook de shell do agente e scripts/merge-gate.sh.
#
#   Claude Code: PreToolUse, matcher "Bash"   → merge-guard.sh --claude
#   Cursor:      beforeShellExecution          → merge-guard.sh --cursor
#
# Lê o JSON do hook no stdin. O comando é analisado por
# scripts/merge-guard-parse.py (tokenização com aspas preservadas) e o
# hook decide só para comandos que integram código numa branch:
#   - gh pr merge (inclusive --auto) e gh api .../pulls/<n>/merge;
#   - git push com destino em branch oficial (main, master, dev,
#     develop, release/*, epic/*, project/*) ou destino indeterminado.
# Qualquer outro comando sai sem decisão: o fluxo normal de permissões
# do agente continua valendo.
#
# Decisões possíveis: deny ou ask. Este hook nunca concede permissão:
# CI verde e aprovações suficientes viram "ask", e a confirmação humana
# no prompt do agente é a autorização do merge. Toda condição de deny é
# avaliada antes de qualquer ask.
#
# Merge exige HEAD fixado com SHA completo: --match-head-commit <sha>
# no gh pr merge, ou -f sha=<sha> no endpoint REST. Assim o GitHub
# recusa o merge se o PR mudar entre a avaliação e a execução.
#
# Falha segura (deny): política ausente, gate ou parser ausentes, erro
# de leitura do GitHub, jq ou python3 ausentes, PR ou HEAD não
# identificados, forma de merge não avaliável (GraphQL, HTTP direto,
# alias do gh, script em arquivo, texto em subshell), --admin em
# qualquer forma, --no-verify, merge e push no mesmo comando.
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
PARSER="$SCRIPT_DIR/merge-guard-parse.py"
OFFICIAL_RE='^(main|master|dev|develop|release/.+|epic/.+|project/.+)$'
EXCEPTION_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/merge-guard/exceptions.log"
UNRECOGNIZED="use um merge por comando: gh pr merge <n> -R owner/repo --match-head-commit <sha completo>"

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

# Sem jq não há como separar o comando do restante do evento: o teste
# usa o JSON inteiro (mais conservador).
if command -v jq >/dev/null 2>&1; then
  if [ "$mode" = --claude ]; then
    command_line=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  else
    command_line=$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)
  fi
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
else
  command_line="$input" cwd=""
fi
[ -n "$command_line" ] || exit 0

# Sem jq, python3 ou parser não há leitura confiável do comando: nega o
# que pode integrar código e deixa o resto seguir.
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || [ ! -r "$PARSER" ]; then
  case "$command_line" in
    *merge*|*push*|*disableAllHooks*) decide deny "merge-guard: jq, python3 ou o parser indisponível; operação de integração bloqueada" ;;
    *) exit 0 ;;
  esac
fi

# Desligar hooks pelo shell desliga este guard. A edição do mesmo
# arquivo pelas ferramentas de edição do agente não passa por aqui.
case "$command_line" in
  *disableAllHooks*) decide deny "merge-guard: comando altera disableAllHooks; desligar hooks exige ação humana direta" ;;
esac

analysis=$(GUARD_CMD="$command_line" GUARD_CWD="$cwd" python3 "$PARSER" 2>/dev/null)
if ! printf '%s' "$analysis" | jq -e '.merges and .pushes' >/dev/null 2>&1; then
  case "$command_line" in
    *merge*|*push*) decide deny "merge-guard: análise do comando falhou; operação de integração bloqueada" ;;
    *) exit 0 ;;
  esac
fi

field() { printf '%s' "$analysis" | jq -r "$1"; }

parse_error=$(field '.error')
if [ -n "$parse_error" ]; then
  case "$command_line" in
    *merge*|*push*) decide deny "merge-guard: $parse_error; operação de integração bloqueada" ;;
    *) exit 0 ;;
  esac
fi

[ "$(field '.no_verify')" = false ] || decide deny "merge-guard: --no-verify é proibido; hook bloqueou: diagnosticar, não contornar"

indirect=$(field '.indirect | join(", ")')
[ -z "$indirect" ] || decide deny "merge-guard: merge por $indirect não é avaliável; $UNRECOGNIZED"

merges=$(field '.merges | length')
hits=$(field '.hits')
[ "$hits" -le "$merges" ] || decide deny "merge-guard: comando de merge em forma não reconhecida (GraphQL, HTTP, subshell ou texto); $UNRECOGNIZED"
[ "$merges" -le 1 ] || decide deny "merge-guard: mais de um merge no mesmo comando; $UNRECOGNIZED"

# Destinos de push: oficial ou indeterminado pede confirmação.
push_note=""
unresolved=$(field '[.pushes[].unresolved[]] | join(", ")')
[ -z "$unresolved" ] || push_note="push com destino não determinado ($unresolved)"
for dst in $(field '.pushes[].targets[]'); do
  [ -z "$push_note" ] || break
  if printf '%s\n' "$dst" | grep -qE "$OFFICIAL_RE"; then
    push_note="push direto para a branch oficial '$dst'"
    break
  fi
done

if [ "$merges" -eq 0 ]; then
  [ -z "$push_note" ] || decide ask "merge-guard: $push_note. Branch oficial só recebe código via PR; confirme apenas com autorização humana expressa para esta operação (ex.: criação da branch)."
  exit 0
fi

[ -z "$push_note" ] || decide deny "merge-guard: merge e $push_note no mesmo comando; execute cada operação separadamente"

ambiguous=$(field '.merges[0].ambiguous | join(", ")')
admin=$(field '.merges[0].admin')
pr_number=$(field '.merges[0].number // empty')
pr_repo=$(field '.merges[0].repo // empty')
head_sha=$(field '.merges[0].head // empty')
via=$(field '.merges[0].via')

[ "$admin" = false ] || decide deny "merge-guard: --admin contorna a proteção do repositório; bypass exige autorização e execução humana direta"
[ -z "$ambiguous" ] || decide deny "merge-guard: argumentos do merge não determináveis ($ambiguous); $UNRECOGNIZED"
case "$pr_number" in ''|*[!0-9]*) decide deny "merge-guard: PR não identificado; $UNRECOGNIZED" ;; esac
case "$pr_repo" in */*) ;; *) decide deny "merge-guard: repositório não explícito; $UNRECOGNIZED" ;; esac
if ! printf '%s\n' "$head_sha" | grep -qE '^[0-9a-f]{40}$'; then
  if [ "$via" = "gh api" ]; then
    decide deny "merge-guard: merge via API sem -f sha=<sha completo>; o HEAD avaliado precisa ser fixado"
  fi
  decide deny "merge-guard: merge sem --match-head-commit <sha completo>; o HEAD avaliado precisa ser fixado"
fi

[ -r "$GATE" ] || decide deny "merge-guard: gate ausente em $GATE; merge bloqueado"

gate_err=$(mktemp "${TMPDIR:-/tmp}/merge-guard.XXXXXX")
report=$(bash "$GATE" "$pr_number" -R "$pr_repo" --expect-head "$head_sha" --format json 2>"$gate_err")
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

# confirm_exception: diálogo nativo; sucesso só com o número do PR
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
