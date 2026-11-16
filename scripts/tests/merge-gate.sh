#!/usr/bin/env bash
# Harness de merge-gate.sh e merge-guard.sh. Não acessa o GitHub nem abre
# diálogos: `gh` e `osascript` falsos no PATH servem a fixture do cenário
# e registram cada chamada. Nenhum cenário pode resultar em merge
# executado nem em decisão que conceda permissão.
set -eu
set -o pipefail

ROOT=$(cd -P "$(dirname "$0")/../.." && pwd)
GATE="$ROOT/scripts/merge-gate.sh"
GUARD="$ROOT/scripts/merge-guard.sh"
BASE="$ROOT/scripts/tests/fixtures/merge-gate/base.json"
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

for f in "$GATE" "$GUARD" "$BASE"; do
  [ -f "$f" ] || { echo "ausente: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "jq é obrigatório" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export GH_SHIM_LOG="$work/gh-calls.log" OSA_SHIM_LOG="$work/osascript-calls.log"
export XDG_STATE_HOME="$work/state"
: > "$GH_SHIM_LOG"; : > "$OSA_SHIM_LOG"

cat > "$work/bin/gh" <<'SHIM'
#!/usr/bin/env bash
f="$GH_SHIM_FIXTURE"
printf '%s\n' "$*" >> "$GH_SHIM_LOG"
flag() { [ "$(jq -r ".$1 // false" "$f")" = true ]; }
case "$1 ${2:-}" in
  "pr view")
    flag pr_view_error && exit 1
    flag pr_view_garbage && { echo '{"oops":1}'; exit 0; }
    jq '.pr_view' "$f" ;;
  "pr merge")
    echo "MERGE-EXECUTED" >> "$GH_SHIM_LOG" ;;
  "pr checks")
    flag checks_error && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    case " $* " in
      *" --required "*)
        flag checks_required_none && { echo "no required checks reported on the 'x' branch" >&2; exit 1; }
        jq '.checks_required' "$f" ;;
      *)
        flag checks_none && { echo "no checks reported on the 'x' branch" >&2; exit 1; }
        jq '.checks' "$f" ;;
    esac
    exit "$(jq -r '.checks_exit // 0' "$f")" ;;
  "api graphql")
    flag threads_error && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    jq '.threads' "$f" ;;
  "alias list")
    jq -r '.aliases // ""' "$f" ;;
  api\ repos/*/rules/branches/*)
    flag rules_error && { echo "HTTP 404" >&2; exit 1; }
    jq '.rules' "$f" ;;
  *)
    exit 1 ;;
esac
SHIM

cat > "$work/bin/osascript" <<'SHIM'
#!/usr/bin/env bash
echo CALL >> "$OSA_SHIM_LOG"
[ -n "${OSA_SHIM_REPLY:-}" ] || exit 1
printf '%s\n' "$OSA_SHIM_REPLY"
SHIM
chmod +x "$work/bin/gh" "$work/bin/osascript"
export PATH="$work/bin:$PATH"

TAB=$(printf '\t')
printf 'acme/*%s2%sPolítica de teste%sautorização do responsável\n' "$TAB" "$TAB" "$TAB" > "$work/policy.tsv"
printf 'acme/*%s2%sPolítica sem exceção\n' "$TAB" "$TAB" > "$work/policy-sem-excecao.tsv"
printf '# só comentários: vale o servidor\n' > "$work/policy-vazia.tsv"
printf 'acme/*%sdois%sinválida\n' "$TAB" "$TAB" > "$work/policy-invalida.tsv"
export MERGE_GATE_POLICY_FILE="$work/policy.tsv"

failures=0
ok() { echo "ok $1"; }
fail() { echo "FALHOU $1: $2" >&2; printf '%s\n' "$out" >&2; failures=$((failures + 1)); }

# scenario <jq-patch>: grava a fixture do cenário e exporta o caminho
scenario() {
  jq "$1" "$BASE" > "$work/fixture.json"
  export GH_SHIM_FIXTURE="$work/fixture.json"
}

# gate <label> <status esperado> <padrão esperado|-> <padrão proibido|-> args...
gate() {
  local label="$1" expected="$2" want="$3" deny="$4" status=0
  shift 4
  out=$(bash "$GATE" "$@" 2>&1) || status=$?
  if [ "$status" != "$expected" ]; then fail "$label" "status $status, esperado $expected"; return; fi
  if [ "$want" != - ] && ! printf '%s\n' "$out" | grep -q -- "$want"; then fail "$label" "sem [$want]"; return; fi
  if [ "$deny" != - ] && printf '%s\n' "$out" | grep -q -- "$deny"; then fail "$label" "contém [$deny]"; return; fi
  ok "$label"
}

# guard <label> <modo> <decisão esperada|none> <padrão no motivo|-> <comando> [cwd] [script]
guard() {
  local label="$1" mode="$2" expected="$3" want="$4" cmd="$5" cwd="${6:-$work}" script="${7:-$GUARD}" decision
  if [ "$mode" = --claude ]; then
    out=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | bash "$script" --claude)
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || echo invalid)
  else
    out=$(jq -n --arg c "$cmd" --arg d "$cwd" '{command: $c, cwd: $d}' | bash "$script" --cursor)
    decision=$(printf '%s' "$out" | jq -r '.permission // "none"' 2>/dev/null || echo invalid)
  fi
  [ -n "$out" ] || decision=none
  if [ "$decision" != "$expected" ]; then fail "$label" "decisão $decision, esperada $expected"; return; fi
  if [ "$want" != - ] && ! printf '%s\n' "$out" | grep -q -- "$want"; then fail "$label" "sem [$want]"; return; fi
  ok "$label"
}

osa_calls() { wc -l < "$OSA_SHIM_LOG" | tr -d ' '; }

R=(42 -R acme/app)

# --- gate: aprovações -------------------------------------------------
scenario '.'
gate "duas aprovações no HEAD: sem BLOCKER" 0 "SEM BLOQUEIO TÉCNICO" "BLOCKER |" "${R[@]}"
gate "relatório nunca autoriza merge" 0 "não autoriza merge" "Resultado: AUTORIZADO" "${R[@]}"

scenario '.pr_view.reviews |= .[:1]'
gate "uma aprovação e CI verde: BLOCKER" 1 "MG-APPROVALS" - "${R[@]}"
gate "uma aprovação: gate só informa a exceção, não a concede" 1 "Este script não a concede" "SEM BLOQUEIO" "${R[@]}"

scenario ".pr_view.reviews[1].commit.oid = \"$OLD_SHA\""
gate "aprovação em commit antigo não conta" 1 "em commit antigo: reviewer-b@bbbbbbbbbb" - "${R[@]}"

scenario '.pr_view.reviews += [{"author":{"login":"reviewer-c"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-16T12:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]'
gate "CHANGES_REQUESTED vigente: BLOCKER" 1 "MG-CHANGES" - "${R[@]}"

scenario '.pr_view.reviews = [
  {"author":{"login":"reviewer-a"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-16T09:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
] + .pr_view.reviews'
gate "aprovação posterior substitui CHANGES_REQUESTED do mesmo revisor" 0 - "MG-CHANGES" "${R[@]}"

scenario '.pr_view.reviews += [{"author":{"login":"reviewer-a"},"state":"COMMENTED","submittedAt":"2026-11-16T13:00:00Z","commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]'
gate "comentário depois da aprovação não cancela a aprovação" 0 - "MG-APPROVALS" "${R[@]}"

scenario '.pr_view.reviews = [.pr_view.reviews[0], .pr_view.reviews[0]]'
gate "duas aprovações do mesmo revisor contam uma" 1 "1 aprovação" - "${R[@]}"

# --- gate: threads, checks, conflito, estado --------------------------
scenario '.threads.data.repository.pullRequest.reviewThreads.nodes = [{"isResolved":false,"isOutdated":false,"path":"Sources/Service.swift","line":10,"comments":{"nodes":[]}}, {"isResolved":true,"isOutdated":false,"path":"a","line":1,"comments":{"nodes":[]}}] | .threads.data.repository.pullRequest.reviewThreads.totalCount = 2'
gate "thread sem resolução: BLOCKER" 1 "1 thread(s) sem resolução: Sources/Service.swift:10" - "${R[@]}"

scenario '.threads.data.repository.pullRequest.reviewThreads.totalCount = 150'
gate "threads além da primeira página: BLOCKER" 1 "150 threads, só 0 lidas" - "${R[@]}"

scenario '.checks[0].bucket = "fail" | .checks_required[0].bucket = "fail" | .checks_exit = 1'
gate "check obrigatório com falha: BLOCKER" 1 "check obrigatório com falha: build" - "${R[@]}"

scenario '.checks[0].bucket = "pending" | .checks_required[0].bucket = "pending" | .checks_exit = 8'
gate "check obrigatório pendente: BLOCKER" 1 "check obrigatório pendente: build" - "${R[@]}"

scenario '.checks[1].bucket = "fail"'
gate "check não obrigatório com falha: WARNING" 0 "check não obrigatório com falha: lint" "BLOCKER |" "${R[@]}"

scenario '.checks_required_none = true | .checks[1].bucket = "fail"'
gate "sem required declarado, todo check conta como obrigatório" 1 "check obrigatório com falha: lint" - "${R[@]}"

scenario '.checks_none = true | .checks_required_none = true'
gate "CI ausente não é CI verde" 0 "CI ausente não é CI verde" - "${R[@]}"

scenario '.pr_view.mergeable = "CONFLICTING" | .pr_view.mergeStateStatus = "DIRTY"'
gate "conflito: BLOCKER" 1 "MG-CONFLICT" - "${R[@]}"

scenario '.pr_view.isDraft = true'
gate "draft: BLOCKER" 1 "MG-DRAFT" - "${R[@]}"

scenario '.pr_view.state = "MERGED"'
gate "PR já mergeado: BLOCKER e sem avaliação de conflito" 1 "MG-STATE" "MG-CONFLICT" "${R[@]}"

# --- gate: HEAD, base, política ---------------------------------------
scenario '.'
gate "HEAD diferente do validado: BLOCKER" 1 "difere do validado" - "${R[@]}" --expect-head cccccccc
gate "HEAD igual ao validado: sem aviso de HEAD" 0 - "MG-HEAD" "${R[@]}" --expect-head aaaaaaaa
gate "base diferente da esperada: BLOCKER" 1 "difere do esperado master" - "${R[@]}" --expect-base master
gate "base confirmada: sem aviso de base" 0 - "MG-BASE" "${R[@]}" --expect-base dev
gate "opção de exceção removida: erro de uso" 2 "opção desconhecida" - "${R[@]}" --approval-exception "qualquer texto"

scenario '.pr_view.url = "https://github.com/other/lib/pull/42" | .pr_view.reviews |= .[:1]'
gate "repositório fora da política local segue o servidor (1 aprovação)" 0 "aprovações válidas 1/1" "MG-APPROVALS" 42 -R other/lib

scenario '.'
out=$(MERGE_GATE_POLICY_FILE= bash "$GATE" "${R[@]}" 2>&1) && st=0 || st=$?
if [ "$st" = 1 ] && printf '%s\n' "$out" | grep -q "BLOCKER | MG-POLICY"; then ok "política não configurada: BLOCKER"; else fail "política não configurada: BLOCKER" "status $st"; fi
out=$(MERGE_GATE_POLICY_FILE="$work/nao-existe.tsv" bash "$GATE" "${R[@]}" 2>&1) && st=0 || st=$?
if [ "$st" = 2 ] && printf '%s\n' "$out" | grep -q "inexistente ou ilegível"; then ok "arquivo de política ausente: erro"; else fail "arquivo de política ausente: erro" "status $st"; fi
out=$(MERGE_GATE_POLICY_FILE="$work/policy-invalida.tsv" bash "$GATE" "${R[@]}" 2>&1) && st=0 || st=$?
if [ "$st" = 2 ] && printf '%s\n' "$out" | grep -q "política inválida"; then ok "política com mínimo inválido: erro"; else fail "política com mínimo inválido: erro" "status $st"; fi
scenario '.pr_view.reviews |= .[:1]'
out=$(MERGE_GATE_POLICY_FILE="$work/policy-vazia.tsv" bash "$GATE" "${R[@]}" 2>&1) && st=0 || st=$?
if [ "$st" = 0 ] && printf '%s\n' "$out" | grep -q "1/1"; then ok "política vazia: vale só o servidor"; else fail "política vazia: vale só o servidor" "status $st"; fi

# --- gate: falhas de leitura do GitHub --------------------------------
scenario '.pr_view_error = true'
gate "falha ao ler o PR: erro de coleta" 2 "não foi possível ler o PR" - "${R[@]}"
scenario '.pr_view_garbage = true'
gate "PR com resposta inesperada: erro de coleta" 2 "resposta inesperada ao ler o PR" - "${R[@]}"
scenario '.threads_error = true'
gate "falha ao ler threads: erro de coleta" 2 "threads de review" - "${R[@]}"
scenario '.checks_error = true'
gate "falha ao ler checks não vira CI ausente" 2 "não foi possível ler os checks" "CI ausente" "${R[@]}"
scenario '.rules_error = true'
gate "falha ao ler rulesets: erro de coleta" 2 "rulesets" - "${R[@]}"
gate "sem -R explícito: erro de uso" 2 "owner/repo explícito" - 42

# --- guard: Claude Code -----------------------------------------------
scenario '.'
guard "comando comum: sem decisão" --claude none - "git status"
guard "leitura de PR: sem decisão" --claude none - "gh pr view 42 -R acme/app --json mergeable,mergeCommit"
guard "busca por PRs mergeados: sem decisão" --claude none - "gh pr list -R acme/app --search is:merged"
guard "git merge-base: sem decisão" --claude none - "git merge-base HEAD origin/dev"
guard "duas aprovações e CI verde: ask, nunca allow" --claude ask "Isto não é autorização" "gh pr merge 42 -R acme/app --squash --match-head-commit aaaaaaaa"
guard "forma URL é avaliada" --claude ask "acme/app#42" "gh pr merge https://github.com/acme/app/pull/42 --merge"
guard "--repo= é avaliado" --claude ask - "gh pr merge 42 --repo=acme/app"
guard "auto-merge é avaliado como merge" --claude ask - "gh pr merge 42 -R acme/app --auto --squash"
guard "HEAD divergente: deny" --claude deny "difere do validado" "gh pr merge 42 -R acme/app --match-head-commit cccccccc"

scenario '.pr_view.reviews |= .[:1]'
guard "uma aprovação e CI verde: deny" --claude deny "MG-APPROVALS" "gh pr merge 42 -R acme/app --squash"
guard "merge via API REST: avaliado e deny" --claude deny "MG-APPROVALS" "gh api -X PUT repos/acme/app/pulls/42/merge -f merge_method=squash"
guard "sem -R: deny" --claude deny "repositório não explícito" "gh pr merge 42"
guard "GH_REPO no ambiente não substitui -R: deny" --claude deny "repositório não explícito" "GH_REPO=acme/app gh pr merge 42"
guard "sem número: deny" --claude deny "PR não identificado" "gh pr merge -R acme/app"
guard "--admin: deny" --claude deny "contorna a proteção" "gh pr merge 42 -R acme/app --admin"
guard "dois merges no mesmo comando: deny" --claude deny "mais de um merge" "gh pr merge 41 -R acme/app && gh pr merge 42 -R acme/app"
guard "dois merges em linhas separadas: deny" --claude deny "mais de um merge" "$(printf 'gh pr merge 41 -R acme/app\ngh pr merge 42 -R acme/app')"
guard "texto solto no corpo: deny por ambiguidade" --claude deny "ambíguos" "gh pr merge -b \"fix 7\" 42 -R acme/app"
guard "gh por caminho absoluto é avaliado" --claude deny "MG-APPROVALS" "/opt/homebrew/bin/gh pr merge 42 -R acme/app"

# --- guard: execução indireta -----------------------------------------
guard "dentro de bash -c é avaliado" --claude deny "MG-APPROVALS" "bash -c \"gh pr merge 42 -R acme/app\""
guard "dentro de sh -lc é avaliado" --claude deny "MG-APPROVALS" "sh -lc 'gh pr merge 42 -R acme/app'"
guard "env gh é avaliado" --claude deny "MG-APPROVALS" "env GH_DEBUG=1 gh pr merge 42 -R acme/app"
guard "eval é avaliado" --claude deny "MG-APPROVALS" "eval gh pr merge 42 -R acme/app"
guard "encadeado após cd é avaliado" --claude deny "MG-APPROVALS" "cd /tmp && gh pr merge 42 -R acme/app"
guard "xargs sem número explícito: deny" --claude deny "PR não identificado" "echo 42 | xargs gh pr merge -R acme/app"
guard "subshell \$(...): deny" --claude deny "forma não reconhecida" 'echo $(gh pr merge 42 -R acme/app)'
guard "crase: deny" --claude deny "forma não reconhecida" 'echo `gh pr merge 42 -R acme/app`'
guard "merge legítimo + merge escondido: deny" --claude deny "forma não reconhecida" 'gh pr merge 42 -R acme/app; X=$(gh pr merge 43 -R acme/app)'
guard "variável no lugar do gh: deny" --claude deny "forma não reconhecida" 'G=gh; $G pr merge 42 -R acme/app'
guard "python -c com lista de argumentos: deny" --claude deny "forma não reconhecida" "python3 -c 'import subprocess; subprocess.run([\"gh\", \"pr\", \"merge\", \"42\"])'"
guard "GraphQL mergePullRequest: deny" --claude deny "forma não reconhecida" "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
guard "GraphQL auto-merge: deny" --claude deny "forma não reconhecida" "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'"
guard "curl no endpoint de merge: deny" --claude deny "forma não reconhecida" "curl -X PUT https://api.github.com/repos/acme/app/pulls/42/merge"
printf '#!/bin/sh\ngh pr merge 42 -R acme/app\n' > "$work/m.sh"
guard "script em arquivo executado direto: deny" --claude deny "script ./m.sh" "./m.sh" "$work"
guard "script em arquivo via bash: deny" --claude deny "script m.sh" "bash m.sh" "$work"
printf 'import subprocess\nsubprocess.run(["gh", "pr", "merge", "42"])\n' > "$work/m.py"
guard "script python em arquivo: deny" --claude deny "script m.py" "python3 m.py" "$work"
scenario '.aliases = "pm: pr merge\nco: pr checkout"'
guard "alias do gh que faz merge: deny" --claude deny "alias do gh 'pm'" "gh pm 42 -R acme/app"
guard "alias do gh sem merge: sem decisão" --claude none - "gh co 42 -R acme/app"
guard "desligar hooks pelo shell: deny" --claude deny "disableAllHooks" "echo '{\"disableAllHooks\": true}' > .claude/settings.local.json"
guard "desligar hooks com jq: deny" --claude deny "disableAllHooks" "jq '.disableAllHooks = true' s.json > t && mv t s.json"
guard "criar alias de merge: deny" --claude deny "forma não reconhecida" "gh alias set pm 'pr merge'"

# --- guard: exceção de aprovações -------------------------------------
scenario '.pr_view.reviews |= .[:1]'
before=$(osa_calls)
guard "texto MERGE_GATE_EXCEPTION no comando não concede exceção" --claude deny "não confirmada no diálogo" "MERGE_GATE_EXCEPTION=autorizado gh pr merge 42 -R acme/app"
guard "texto de exceção com espaços: deny" --claude deny - "MERGE_GATE_EXCEPTION='autorizado após alinhamento técnico' gh pr merge 42 -R acme/app"
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:42, gave up:false" \
  guard "exceção confirmada no diálogo com o número do PR: ask" --claude ask "EXCEÇÃO de aprovações confirmada" "gh pr merge 42 -R acme/app"
if grep -q "acme/app#42" "$XDG_STATE_HOME/merge-guard/exceptions.log" 2>/dev/null; then ok "exceção confirmada fica registrada"; else out=""; fail "exceção confirmada fica registrada" "sem registro"; fi
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:41, gave up:false" \
  guard "diálogo com número errado: deny" --claude deny "não confirmada" "gh pr merge 42 -R acme/app"
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:42, gave up:true" \
  guard "diálogo expirado: deny" --claude deny "não confirmada" "gh pr merge 42 -R acme/app"
OSA_SHIM_REPLY="button returned:Recusar, text returned:42, gave up:false" \
  guard "diálogo recusado: deny" --claude deny "não confirmada" "gh pr merge 42 -R acme/app"
after=$(osa_calls)
if [ "$after" -eq $((before + 5)) ]; then ok "diálogo aberto uma vez por tentativa elegível"; else out=""; fail "diálogo aberto uma vez por tentativa elegível" "$before -> $after"; fi

before=$(osa_calls)
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:42, gave up:false" MERGE_GATE_POLICY_FILE="$work/policy-sem-excecao.tsv" \
  guard "política sem regra de exceção: deny sem diálogo" --claude deny "MG-APPROVALS" "gh pr merge 42 -R acme/app"
scenario '.pr_view.reviews |= .[:1] | .threads.data.repository.pullRequest.reviewThreads = {"totalCount":1,"nodes":[{"isResolved":false,"path":"a","line":1}]}'
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:42, gave up:false" \
  guard "outro BLOCKER além das aprovações: deny sem diálogo" --claude deny "MG-THREADS" "gh pr merge 42 -R acme/app"
scenario '.pr_view.reviews = []'
OSA_SHIM_REPLY="button returned:Autorizar exceção, text returned:42, gave up:false" \
  guard "abaixo do mínimo do servidor: deny sem diálogo" --claude deny "MG-APPROVALS" "gh pr merge 42 -R acme/app"
if [ "$(osa_calls)" -eq "$before" ]; then ok "diálogo não abre fora da elegibilidade"; else out=""; fail "diálogo não abre fora da elegibilidade" "osascript chamado"; fi

# --- guard: falha segura ----------------------------------------------
scenario '.pr_view_error = true'
guard "gate sem coleta: deny" --claude deny "não concluiu a avaliação" "gh pr merge 42 -R acme/app"
scenario '.checks_error = true'
guard "erro ao ler checks: deny" --claude deny "não concluiu a avaliação" "gh pr merge 42 -R acme/app"
scenario '.'
MERGE_GATE_POLICY_FILE= guard "política não configurada: deny" --claude deny "MG-POLICY" "gh pr merge 42 -R acme/app"
MERGE_GATE_POLICY_FILE="$work/nao-existe.tsv" guard "arquivo de política ausente: deny" --claude deny "inexistente ou ilegível" "gh pr merge 42 -R acme/app"
mkdir -p "$work/sem-gate"
cp "$GUARD" "$work/sem-gate/merge-guard.sh"
guard "gate ausente: deny" --claude deny "gate ausente" "gh pr merge 42 -R acme/app" "$work" "$work/sem-gate/merge-guard.sh"
guard "gate ausente não afeta comando comum" --claude none - "ls" "$work" "$work/sem-gate/merge-guard.sh"

# --- guard: push em branch oficial ------------------------------------
repo="$work/repo"
git init -q "$repo"
git -C "$repo" checkout -q -b epic/ABC-1
guard "push explícito para dev: ask" --claude ask "branch oficial 'dev'" "git push origin HEAD:dev" "$repo"
guard "push explícito para release/*: ask" --claude ask "release/1.2" "git push origin feat/x:release/1.2" "$repo"
guard "push sem refspec na branch epic: ask" --claude ask "epic/ABC-1" "git push" "$repo"
guard "push com HEAD na branch epic: ask" --claude ask "epic/ABC-1" "git push -u origin HEAD" "$repo"
guard "push de branch de trabalho: sem decisão" --claude none - "git push -u origin feat/ABC-1" "$repo"
guard "push de tag: sem decisão" --claude none - "git push origin refs/tags/v1.0.0" "$repo"
guard "branch com nome parecido: sem decisão" --claude none - "git push origin feat/dev-tools" "$repo"

# --- guard: Cursor ----------------------------------------------------
scenario '.'
guard "Cursor: duas aprovações: ask" --cursor ask "Isto não é autorização" "gh pr merge 42 -R acme/app"
scenario '.pr_view.reviews |= .[:1]'
guard "Cursor: uma aprovação: deny" --cursor deny "MG-APPROVALS" "gh pr merge 42 -R acme/app"
guard "Cursor: comando comum: sem decisão" --cursor none - "ls -la"

# --- invariantes globais ----------------------------------------------
if grep -q "MERGE-EXECUTED" "$GH_SHIM_LOG"; then
  out=$(cat "$GH_SHIM_LOG"); fail "nenhum merge executado" "gh pr merge foi chamado"
else
  ok "nenhum merge executado em $(wc -l < "$GH_SHIM_LOG" | tr -d ' ') chamadas ao gh"
fi
if grep -qE '"allow"|decide allow|emit allow' "$GUARD"; then
  out=""; fail "guard não tem caminho que conceda permissão" "encontrado allow no script"
else
  ok "guard não tem caminho que conceda permissão"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures falha(s)" >&2
  exit 1
fi
echo "todos os cenários passaram"
