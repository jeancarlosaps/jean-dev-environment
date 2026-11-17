#!/usr/bin/env bash
# =====================================================================
# merge-gate.sh — prontidão técnica de um PR para merge (somente leitura)
# ---------------------------------------------------------------------
# Lê o PR pelo `gh` e classifica cada condição em BLOCKER, WARNING ou
# INFO. Nunca executa merge, nunca altera o PR, nunca escreve no GitHub.
#
# O resultado é técnico. "Sem BLOCKER" NÃO é autorização de merge: a
# autorização é sempre uma decisão humana expressa, fora deste script.
# O gate também não concede exceção de aprovações; só informa se o PR é
# elegível a ela pela política (approvals.exceptionEligible).
#
# Aprovação vigente: a última revisão de cada revisor no PR é APPROVED.
# Vale mesmo em commit anterior ao HEAD, salvo quando o servidor invalida
# aprovações a cada push (dismiss stale: ruleset ou proteção clássica) —
# aí só conta a do HEAD. Com "approval of the most recent reviewable push"
# no servidor, falta de aprovação no HEAD é BLOCKER. DISMISSED nunca conta.
#
# Uso:
#   MERGE_GATE_POLICY_FILE=<arquivo> ./scripts/merge-gate.sh <n> -R owner/repo [opções]
#
# Opções:
#   --expect-head <sha>    HEAD validado; divergência é BLOCKER
#   --expect-base <branch> destino correto; divergência é BLOCKER
#   --format text|json     padrão text
#
# Política (obrigatória): MERGE_GATE_POLICY_FILE aponta para um TSV no
# formato de scripts/merge-policy.example.tsv. Variável ausente é BLOCKER;
# arquivo inexistente ou ilegível é erro. Arquivo sem padrões que casem
# significa "vale só o que o servidor declara".
#
# Falha segura: qualquer erro de leitura do GitHub encerra com status 2;
# nunca é tratado como lista vazia.
#
# Saída: 0 sem BLOCKER · 1 com BLOCKER · 2 erro de uso ou de coleta.
# Dependências: bash 3.2+, gh autenticado, jq.
# =====================================================================
set -eu
set -o pipefail

POLICY_FILE="${MERGE_GATE_POLICY_FILE:-}"

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "merge-gate: $*" >&2
  exit 2
}

number="" repo="" expect_head="" expect_base="" format=text
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) repo="${2:-}"; shift 2 ;;
    --expect-head) expect_head="${2:-}"; shift 2 ;;
    --expect-base) expect_base="${2:-}"; shift 2 ;;
    --format) format="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "opção desconhecida: $1" ;;
    *) [ -z "$number" ] || die "mais de um PR informado"; number="$1"; shift ;;
  esac
done

case "$number" in ''|*[!0-9]*) die "informe o número do PR" ;; esac
case "$repo" in */*) ;; *) die "informe -R owner/repo explícito" ;; esac
case "$format" in text|json) ;; *) die "--format deve ser text ou json" ;; esac
command -v gh >/dev/null 2>&1 || die "gh não encontrado"
command -v jq >/dev/null 2>&1 || die "jq não encontrado"

# ---------------------------------------------------------------------
# Política local
# ---------------------------------------------------------------------
policy_min="" policy_source="" policy_exception=""
if [ -n "$POLICY_FILE" ]; then
  [ -f "$POLICY_FILE" ] && [ -r "$POLICY_FILE" ] \
    || die "política inexistente ou ilegível: $POLICY_FILE"
  tab=$(printf '\t')
  while IFS="$tab" read -r pattern min source exception_rule || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue ;; esac
    case "$min" in ''|*[!0-9]*) die "política inválida para '$pattern': mínimo '$min'" ;; esac
    # shellcheck disable=SC2254
    case "$repo" in
      $pattern) policy_min="$min"; policy_source="$source"; policy_exception="$exception_rule"; break ;;
    esac
  done < "$POLICY_FILE"
fi

# ---------------------------------------------------------------------
# Coleta (somente leitura, estrita)
# ---------------------------------------------------------------------
owner=${repo%%/*}
name=${repo#*/}

pr_json=$(gh pr view "$number" -R "$repo" --json \
  number,url,state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,reviews \
  2>/dev/null) || die "não foi possível ler o PR $repo#$number"
printf '%s' "$pr_json" | jq -e '.headRefOid and .baseRefName and (.reviews | type == "array")' >/dev/null 2>&1 \
  || die "resposta inesperada ao ler o PR $repo#$number"

base=$(printf '%s' "$pr_json" | jq -r '.baseRefName')
base_uri=$(printf '%s' "$base" | jq -sRr @uri)

threads_json=$(gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){totalCount nodes{isResolved isOutdated path line comments(first:1){nodes{url}}}}}}}' \
  -F o="$owner" -F r="$name" -F n="$number" 2>/dev/null) \
  || die "não foi possível ler as threads de review"
printf '%s' "$threads_json" |
  jq -e '.data.repository.pullRequest.reviewThreads | (.nodes | type == "array") and (.totalCount | type == "number")' >/dev/null 2>&1 \
  || die "resposta inesperada ao ler as threads de review"

# read_checks [--required]: JSON do `gh pr checks`. O status do comando
# não decide (8 = pendente, 1 = falha ou sem checks); o conteúdo decide.
# "no checks reported" é lista vazia; qualquer outra saída é erro.
read_checks() {
  local out err
  err=$(mktemp "${TMPDIR:-/tmp}/merge-gate.XXXXXX")
  out=$(gh pr checks "$number" -R "$repo" "$@" --json name,bucket 2>"$err" || true)
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    rm -f "$err"; printf '%s' "$out"; return 0
  fi
  if printf '%s\n%s\n' "$out" "$(cat "$err")" | grep -qiE '^no (required )?checks reported'; then
    rm -f "$err"; printf '[]'; return 0
  fi
  rm -f "$err"
  return 1
}
checks_json=$(read_checks) || die "não foi possível ler os checks"
required_json=$(read_checks --required) || die "não foi possível ler os checks obrigatórios"

rules_json=$(gh api "repos/$repo/rules/branches/$base_uri" 2>/dev/null) \
  || die "não foi possível ler os rulesets de $base"
printf '%s' "$rules_json" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die "resposta inesperada ao ler os rulesets de $base"

# Proteção clássica: o mínimo de aprovações só é legível com admin. Sem
# leitura, o reviewDecision do GitHub continua refletindo a exigência.
classic_count="" classic_unknown=false classic_dismiss=false classic_last_push=false
classic_enabled=$(gh api "repos/$repo/branches/$base_uri" --jq '.protection.enabled // false' 2>/dev/null) \
  || die "não foi possível ler a proteção de $base"
if [ "$classic_enabled" = true ]; then
  err=$(mktemp "${TMPDIR:-/tmp}/merge-gate.XXXXXX")
  if classic_line=$(gh api "repos/$repo/branches/$base_uri/protection/required_pull_request_reviews" \
      --jq '"\(.required_approving_review_count // 0) \(.dismiss_stale_reviews // false) \(.require_last_push_approval // false)"' 2>"$err"); then
    read -r classic_count classic_dismiss classic_last_push <<EOF_CLASSIC
$classic_line
EOF_CLASSIC
    case "$classic_count:$classic_dismiss:$classic_last_push" in
      *[!0-9]*:*:* | :*) rm -f "$err"; die "resposta inesperada da proteção clássica de $base" ;;
    esac
    case "$classic_dismiss$classic_last_push" in
      truetrue|truefalse|falsetrue|falsefalse) ;;
      *) rm -f "$err"; die "resposta inesperada da proteção clássica de $base" ;;
    esac
  elif grep -qE 'HTTP 40[34]' "$err"; then
    classic_count="" classic_unknown=true
  else
    rm -f "$err"; die "não foi possível ler a proteção clássica de $base"
  fi
  rm -f "$err"
fi

# ---------------------------------------------------------------------
# Avaliação
# ---------------------------------------------------------------------
report=$(jq -n \
  --arg repo "$repo" \
  --argjson pr "$pr_json" \
  --argjson threads "$threads_json" \
  --argjson checks "$checks_json" \
  --argjson required "$required_json" \
  --argjson rules "$rules_json" \
  --arg policy_min "$policy_min" \
  --arg policy_source "$policy_source" \
  --arg policy_exception "$policy_exception" \
  --arg policy_file "$POLICY_FILE" \
  --arg classic_count "$classic_count" \
  --arg classic_unknown "$classic_unknown" \
  --arg classic_dismiss "$classic_dismiss" \
  --arg classic_last_push "$classic_last_push" \
  --arg expect_head "$expect_head" \
  --arg expect_base "$expect_base" '
  def f(sev; rule; evidence; rec): {severity: sev, rule: rule, evidence: evidence, recommendation: rec};
  def short: .[0:10];

  ($pr.headRefOid) as $head
  | ((([$rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count // 0] | max) // 0) as $rules_min
     | [$rules_min, (if $classic_count == "" then 0 else ($classic_count | tonumber) end)] | max) as $server
  | (if $policy_min == "" then null else ($policy_min | tonumber) end) as $policy
  | ([$server, $policy // 0] | max) as $needed
  | ($pr.reviews
      | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
      | sort_by(.submittedAt)
      | group_by(.author.login)
      | map(last)) as $latest
  | ([$rules[] | select(.type == "pull_request") | .parameters // {}]) as $prp
  | (($prp | map(.dismiss_stale_reviews_on_push // false) | any) or $classic_dismiss == "true") as $dismiss_stale
  | (($prp | map(.require_last_push_approval // false) | any) or $classic_last_push == "true") as $last_push
  | ($latest | map(select(.state == "APPROVED"))) as $approved
  | ($approved | map(select(.commit.oid == $head) | .author.login)) as $on_head
  | ($approved | map(select(.commit.oid != $head) | "\(.author.login)@\(.commit.oid | short)")) as $earlier
  | (if $dismiss_stale then $on_head else ($approved | map(.author.login)) end) as $valid
  | ($latest | map(select(.state == "CHANGES_REQUESTED") | .author.login)) as $changes
  | ($threads.data.repository.pullRequest.reviewThreads) as $rt
  | ($rt.nodes | map(select(.isResolved | not))) as $open_threads
  | ($required | map(.name)) as $req_names
  | ($checks | map(. + {required: (if ($req_names | length) > 0 then (.name as $n | $req_names | index($n) != null) else true end)})) as $cks
  | ($cks | map(select(.required and (.bucket == "fail" or .bucket == "cancel")) | .name)) as $req_fail
  | ($cks | map(select(.required and .bucket == "pending") | .name)) as $req_pending
  | ($cks | map(select((.required | not) and (.bucket == "fail" or .bucket == "cancel")) | .name)) as $opt_fail
  | [
      (if $policy_file == "" then
         f("BLOCKER"; "MG-POLICY"; "política local não configurada (MERGE_GATE_POLICY_FILE)"; "configurar a política do time; arquivo sem padrões = só o servidor") else empty end),
      (if $policy_file != "" and $policy == null and $server == 0 then
         f("WARNING"; "MG-POLICY"; "nenhuma exigência de aprovação conhecida para \($repo) em \($pr.baseRefName)"; "confirmar a política do repositório antes de seguir") else empty end),
      (if $pr.state != "OPEN" then f("BLOCKER"; "MG-STATE"; "estado do PR: \($pr.state)"; "nada a mergear") else empty end),
      (if $pr.isDraft then f("BLOCKER"; "MG-DRAFT"; "PR em draft"; "publicar como ready só quando a revisão terminar") else empty end),
      (if $expect_head == "" then f("WARNING"; "MG-HEAD"; "HEAD validado não informado; HEAD atual \($head | short)"; "usar --match-head-commit no merge e --expect-head aqui")
       elif ($head | startswith($expect_head)) | not then f("BLOCKER"; "MG-HEAD"; "HEAD atual \($head | short) difere do validado \($expect_head)"; "revalidar e pedir nova autorização")
       else empty end),
      (if $expect_base == "" then f("WARNING"; "MG-BASE"; "destino \($pr.baseRefName) não confirmado pelo chamador"; "confirmar a base pela regra do fluxo")
       elif $pr.baseRefName != $expect_base then f("BLOCKER"; "MG-BASE"; "destino \($pr.baseRefName) difere do esperado \($expect_base)"; "corrigir a base do PR")
       else empty end),
      (if ($valid | length) < $needed then
         f("BLOCKER"; "MG-APPROVALS";
           "\($valid | length) aprovação(ões) vigente(s) no PR, exigidas \($needed) (servidor: \($server); política: \($policy // "nenhuma"))"
           + (if ($valid | length) > 0 then "; vigentes: \($valid | join(", "))" else "" end)
           + (if $dismiss_stale and ($earlier | length) > 0 then "; anteriores ao HEAD, invalidadas pelo dismiss stale do servidor: \($earlier | join(", "))" else "" end);
           "aguardar as aprovações")
       else empty end),
      (if ($dismiss_stale | not) and ($earlier | length) > 0 then
         f("INFO"; "MG-APPROVALS"; "aprovação vigente em commit anterior ao HEAD (servidor sem dismiss stale): \($earlier | join(", "))"; "nenhuma") else empty end),
      (if $last_push and ($on_head | length) == 0 then
         f("BLOCKER"; "MG-LAST-PUSH"; "o servidor exige aprovação do push mais recente e não há aprovação no HEAD \($head | short)"; "pedir aprovação no HEAD a quem não fez o último push") else empty end),
      (if $pr.reviewDecision == "REVIEW_REQUIRED" then
         f("BLOCKER"; "MG-SERVER"; "o GitHub informa REVIEW_REQUIRED: a exigência de revisão do servidor não foi atendida"; "obter as aprovações exigidas pelo repositório") else empty end),
      (if $classic_unknown == "true" then
         f("BLOCKER"; "MG-SERVER"; "proteção clássica ativa em \($pr.baseRefName); mínimo efetivo de aprovações desconhecido (ilegível sem admin)"; "confirmar o mínimo com quem administra o repositório; o gate não libera sem ele") else empty end),
      (if ($changes | length) > 0 then f("BLOCKER"; "MG-CHANGES"; "CHANGES_REQUESTED vigente: \($changes | join(", "))"; "atender e pedir re-review") else empty end),
      (if $rt.totalCount > ($rt.nodes | length) then
         f("BLOCKER"; "MG-THREADS"; "\($rt.totalCount) threads, só \($rt.nodes | length) lidas"; "conferir as threads manualmente") else empty end),
      (if ($open_threads | length) > 0 then
         f("BLOCKER"; "MG-THREADS"; "\($open_threads | length) thread(s) sem resolução: \($open_threads | map("\(.path // "?"):\(.line // "?")") | join(", "))"; "responder e resolver as threads") else empty end),
      (if ($cks | length) == 0 then f("WARNING"; "MG-CHECKS"; "nenhum check no HEAD (CI ausente não é CI verde)"; "confirmar se o repositório tem CI para esta base") else empty end),
      (if ($req_fail | length) > 0 then f("BLOCKER"; "MG-CHECKS"; "check obrigatório com falha: \($req_fail | join(", "))"; "corrigir e rodar de novo") else empty end),
      (if ($req_pending | length) > 0 then f("BLOCKER"; "MG-CHECKS"; "check obrigatório pendente: \($req_pending | join(", "))"; "aguardar a conclusão") else empty end),
      (if ($opt_fail | length) > 0 then f("WARNING"; "MG-CHECKS"; "check não obrigatório com falha: \($opt_fail | join(", "))"; "provar que não é required antes de desconsiderar") else empty end),
      (if $pr.state != "OPEN" then empty
       elif $pr.mergeable == "CONFLICTING" or $pr.mergeStateStatus == "DIRTY" then f("BLOCKER"; "MG-CONFLICT"; "conflito com \($pr.baseRefName)"; "resolver o conflito com autorização")
       elif $pr.mergeable == "UNKNOWN" then f("WARNING"; "MG-CONFLICT"; "mergeable ainda não calculado pelo GitHub"; "consultar de novo")
       elif $pr.mergeStateStatus == "BEHIND" then f("WARNING"; "MG-CONFLICT"; "branch atrás de \($pr.baseRefName)"; "atualizar se o repositório exigir")
       else empty end),
      f("INFO"; "MG-AUTH"; "este relatório não autoriza merge"; "merge só com autorização humana expressa para este PR e este HEAD")
    ] as $findings
  | ($findings | map(select(.severity == "BLOCKER") | .rule)) as $blocking
  | {
      repo: $repo, number: $pr.number, url: $pr.url, head: $head, base: $pr.baseRefName,
      approvals: {
        valid: $valid, earlier: $earlier, onHead: $on_head, required: $needed, server: $server, policy: $policy,
        dismissStale: $dismiss_stale, lastPushApproval: $last_push,
        policySource: $policy_source, exceptionRule: $policy_exception,
        exceptionEligible: ($policy != null and $policy_exception != ""
          and ($valid | length) < $needed
          and ($valid | length) >= ([$server, 1] | max)
          and ($blocking == ["MG-APPROVALS"]))
      },
      findings: $findings,
      blockers: ($blocking | length),
      warnings: ($findings | map(select(.severity == "WARNING")) | length)
    }
')

blockers=$(printf '%s' "$report" | jq '.blockers')

if [ "$format" = json ]; then
  printf '%s\n' "$report"
else
  printf '%s' "$report" | jq -r '
    "Merge gate — \(.repo)#\(.number)",
    "HEAD \(.head[0:10]) · base \(.base) · aprovações vigentes \(.approvals.valid | length)/\(.approvals.required)",
    "",
    "| Severidade | Regra | Evidência | Recomendação |",
    "|---|---|---|---|",
    (.findings[] | "| \(.severity) | \(.rule) | \(.evidence) | \(.recommendation) |"),
    "",
    (if .approvals.exceptionEligible then "Exceção de aprovações possível pela política: \(.approvals.exceptionRule). Este script não a concede." else empty end),
    (if .blockers > 0 then "Resultado: BLOQUEADO (\(.blockers) BLOCKER, \(.warnings) WARNING)"
     else "Resultado: SEM BLOQUEIO TÉCNICO (\(.warnings) WARNING). Merge continua dependendo de autorização humana expressa." end)'
fi

[ "$blockers" -eq 0 ]
