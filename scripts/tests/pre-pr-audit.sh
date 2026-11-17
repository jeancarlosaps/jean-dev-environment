#!/usr/bin/env bash
# Harness de scripts/pre-pr-audit.py. Cada caso monta um repositório git
# temporário: main = _base + <caso>/before, feature = _base + <caso>/after.
# Segredos e caminhos pessoais são gerados aqui, nunca versionados.
set -eu
set -o pipefail

ROOT=$(cd -P "$(dirname "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/pre-pr-audit.py"
FIX="$ROOT/scripts/tests/fixtures/pre-pr-audit"
command -v jq >/dev/null 2>&1 || { echo "jq é obrigatório" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 é obrigatório" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/pre-pr-audit-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/empty-hooks"
unset PRE_PR_AUDIT_POLICY || true

failures=0
ok() { echo "ok $1"; }
fail() { echo "FALHOU $1: $2" >&2; [ -f "$work/out.json" ] && jq -c '[.findings[] | {rule, severity, file, line}]' "$work/out.json" >&2 2>/dev/null; failures=$((failures + 1)); }

g() { git -C "$repo" -c core.hooksPath="$work/empty-hooks" "$@"; }

# build <caso>: cria $repo com main (before) e feature (after)
build() {
  repo="$work/$1"
  rm -rf "$repo"; mkdir -p "$repo"
  git init -q "$repo"
  g symbolic-ref HEAD refs/heads/main
  g config user.name Tester; g config user.email tester@example.com; g config commit.gpgsign false
  cp -R "$FIX/_base/." "$repo/"; cp -R "$FIX/$1/before/." "$repo/"; rm -f "$repo/.keep"
  g add -A; g commit -q -m base
  g checkout -q -b feature
  g rm -rq --cached .
  find "$repo" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -R "$FIX/_base/." "$repo/"; cp -R "$FIX/$1/after/." "$repo/"; rm -f "$repo/.keep"
  g add -A; g commit -q --allow-empty -m change
}

# run [args]: audita $repo contra main; status em $status
run() {
  status=0
  python3 "$AUDIT" --repo "$repo" --base main --format json "$@" > "$work/out.json" 2>"$work/err.txt" || status=$?
}

count() {  # count <regra> [severidade]
  jq --arg r "$1" --arg s "${2:-}" '[.findings[] | select(.rule == $r and ($s == "" or .severity == $s))] | length' "$work/out.json"
}

expect_count() {  # expect_count <label> <regra> <severidade|""> <n>
  local n
  n=$(count "$2" "$3")
  if [ "$n" = "$4" ]; then ok "$1"; else fail "$1" "$2 $3: $n, esperado $4"; fi
}

expect_status() {
  if [ "$status" = "$2" ]; then ok "$1"; else fail "$1" "status $status, esperado $2 ($(tail -1 "$work/err.txt"))"; fi
}

expect_evidence() {  # expect_evidence <label> <regra> <trecho>
  if jq -e --arg r "$2" --arg t "$3" 'any(.findings[]; .rule == $r and (.evidence | contains($t)))' "$work/out.json" >/dev/null; then
    ok "$1"; else fail "$1" "sem evidência [$3] em $2"; fi
}

# --- 1–3: pipeline versionado -----------------------------------------
build pipeline-duplicated; run
expect_count "pipeline V1/V2 duplicado: WARNING" SWIFT-PIPELINE-DUPLICATED WARNING 1
expect_evidence "pipeline duplicado cita a cadeia" SWIFT-PIPELINE-DUPLICATED "data → mapError → acceptStatus → decode → map → mapError → eraseToAnyPublisher; diferindo só nos argumentos"
expect_count "pipeline duplicado não vira BLOCKER" SWIFT-PIPELINE-DUPLICATED BLOCKER 0
expect_count "pipeline duplicado não é contado de novo como duplicação genérica" CORE-DUPLICATION "" 0
expect_status "pipeline duplicado: sem BLOCKER, status 0" 0

build pipeline-unified; run
expect_count "pipeline unificado: sem achado" SWIFT-PIPELINE-DUPLICATED "" 0
expect_status "pipeline unificado: status 0" 0

build pipeline-insertions; run
expect_count "V2 que só acrescenta operadores ao pipeline da V1: WARNING" SWIFT-PIPELINE-DUPLICATED WARNING 1
expect_evidence "pipeline com acréscimos cita o que a V2 acrescenta" SWIFT-PIPELINE-DUPLICATED "acrescenta includesSession, map"

build pipeline-legit-difference; run
expect_count "versões com retry e tryMap diferentes: sem achado" SWIFT-PIPELINE-DUPLICATED "" 0

# --- 4–5: API pública ---------------------------------------------------
build public-api-removed; run
expect_count "init público removido e conformidade removida: 2 BLOCKER" SWIFT-API-BREAK BLOCKER 2
expect_evidence "remoção do init identificada" SWIFT-API-BREAK "declaração pública removida: RemoveRequest.init(legacyId:String,customerId:String)"
expect_evidence "remoção de Equatable identificada" SWIFT-API-BREAK "conformidade RemoveRequest: Equatable"
expect_status "API pública quebrada: status 1" 1

build public-api-preserved; run
expect_count "API antiga preservada: sem quebra" SWIFT-API-BREAK "" 0
expect_count "API preservada como deprecated: INFO pedindo delegação e teste" SWIFT-API-DEPRECATED INFO 1
# a mesma API declarada em várias linhas na base e numa linha no HEAD continua sendo a mesma
python3 - "$repo/Sources/Shop/RemoveRequest.swift" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("public init(legacyId: String, customerId: String) {", "public init(legacyId: String,customerId: String) {")
open(p, "w").write(s)
PY2
g add -A; g commit -q -m reformat
run
expect_count "assinatura reformatada não é quebra" SWIFT-API-BREAK "" 0
expect_count "deprecated com message/renamed não gera aviso de mensagem" SWIFT-DEPRECATED-NO-MESSAGE "" 0
expect_status "API preservada: status 0" 0

# --- 6–7: nomenclatura -------------------------------------------------
build naming-inconsistent; run
expect_count "delResource e DelResourceResponse num módulo que usa remove: 2 INFO" CORE-NAMING INFO 2
expect_evidence "nomenclatura cita o vocabulário do módulo" CORE-NAMING "usa 'remove'"

build naming-consistent; run
expect_count "nomes que seguem o módulo: sem achado" CORE-NAMING "" 0
expect_count "teste alterado junto: sem aviso de teste ausente" CORE-TESTS-MISSING "" 0

# --- 8: deployment target ----------------------------------------------
build deployment-target; run
expect_count "Task.sleep(for:) em teste com iOS 15: 1 BLOCKER" SWIFT-AVAILABILITY BLOCKER 1
if jq -e '.findings[] | select(.rule == "SWIFT-AVAILABILITY") | select(.file == "Tests/ShopTests/PollerTests.swift" and .line == 6)' "$work/out.json" >/dev/null; then
  ok "disponibilidade aponta arquivo e linha"; else fail "disponibilidade aponta arquivo e linha" "local errado"; fi
expect_evidence "disponibilidade cita iOS e macOS" SWIFT-AVAILABILITY "ios 16+ (alvo 15)"
expect_status "deployment target violado: status 1" 1
mkdir -p "$repo/Tests/Fixtures/Sample/Sources"
printf 'func sample() async throws {\n    try await Task.sleep(for: .seconds(1))\n}\n' > "$repo/Tests/Fixtures/Sample/Sources/Sample.swift"
printf '// swift-tools-version:5.7\nimport PackageDescription\nlet package = Package(name: "Sample", platforms: [.iOS(.v12)])\n' > "$repo/Tests/Fixtures/Sample/Package.swift"
g add -A; g commit -q -m fixture
run
expect_count "código em diretório de fixtures não é auditado pela camada Swift" SWIFT-AVAILABILITY "" 1
if jq -e 'any(.verified[]; contains("ios 15"))' "$work/out.json" >/dev/null; then
  ok "Package.swift de fixture não define o deployment target"; else fail "Package.swift de fixture" "alvo lido da fixture"; fi

# --- SWIFT-AVAILABILITY: BLOCKER só com incompatibilidade comprovada ----
avail_file() {  # avail_file <arquivo>: severidades da regra nesse arquivo
  jq -r --arg f "$1" '[.findings[] | select(.rule == "SWIFT-AVAILABILITY" and .file == $f) | .severity] | join(",")' "$work/out.json"
}
expect_avail() {  # expect_avail <label> <arquivo> <severidades esperadas, "" = nenhuma>
  local got
  got=$(avail_file "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else fail "$1" "SWIFT-AVAILABILITY em $2: [$got], esperado [$3]"; fi
}
build pipeline-unified
mkdir -p "$repo/Modules/Modern/Sources/Modern"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Modern", platforms: [.iOS(.v17), .macOS(.v14)])\n' > "$repo/Modules/Modern/Package.swift"
printf 'func pause() async throws {\n    try await Task.sleep(for: .seconds(1))\n}\n' > "$repo/Modules/Modern/Sources/Modern/Pause.swift"
cat > "$repo/Sources/Shop/Guards.swift" <<'SWIFT'
import SwiftUI

@available(iOS, introduced: 16.0)
@available(macOS, introduced: 13.0)
func introducedForm() async throws {
    try await Task.sleep(for: .seconds(1))
}

func unavailableElse() async throws {
    if #unavailable(iOS 16, macOS 13) {
        try await Task.sleep(nanoseconds: 1)
    } else {
        try await Task.sleep(for: .seconds(1))
    }
}

func unprotectedElse() async throws {
    if #available(iOS 16, macOS 13, *) {
        try await Task.sleep(nanoseconds: 1)
    } else {
        try await Task.sleep(for: .seconds(1))
    }
}
SWIFT
cat > "$repo/Sources/Shop/Conditional.swift" <<'SWIFT'
#if os(visionOS)
func spatial() async throws {
    try await Task.sleep(for: .seconds(1))
}
#endif
SWIFT
cat > "$repo/Sources/Shop/Backport.swift" <<'SWIFT'
import SwiftUI

struct NavigationStack<Content: View>: View {
    let content: Content
    var body: some View { content }
}

struct Screen: View {
    var body: some View { NavigationStack(content: Text("ok")) }
}
SWIFT
g add -A; g commit -q -m availability
run
expect_avail "Package.swift mais próximo (iOS 17) vale para o arquivo do submódulo" Modules/Modern/Sources/Modern/Pause.swift ""
expect_avail "@available(iOS, introduced:) protege; else de #available não protege" Sources/Shop/Guards.swift "BLOCKER"
if jq -e '[.findings[] | select(.rule == "SWIFT-AVAILABILITY" and .file == "Sources/Shop/Guards.swift") | .line] == [21]' "$work/out.json" >/dev/null; then
  ok "#unavailable { } else { } protege o else; só o else de #available é apontado (linha 21)"; else fail "#unavailable" "linhas erradas"; fi
expect_avail "uso dentro de #if: WARNING, não BLOCKER" Sources/Shop/Conditional.swift "WARNING"
expect_avail "projeto que declara NavigationStack (backport): WARNING" Sources/Shop/Backport.swift "WARNING"
expect_evidence "rebaixamento explica o que não está comprovado" SWIFT-AVAILABILITY "não comprovado: o projeto declara 'NavigationStack'"

build pipeline-unified
g rm -q Package.swift
mkdir -p "$repo/App.xcodeproj"
printf 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;\nIPHONEOS_DEPLOYMENT_TARGET = 15.0;\n' > "$repo/App.xcodeproj/project.pbxproj"
printf 'func pause() async throws {\n    try await Task.sleep(for: .seconds(1))\n}\n' > "$repo/Sources/Shop/Pause.swift"
g add -A; g commit -q -m app
run
expect_avail "project.pbxproj com alvo único: BLOCKER" Sources/Shop/Pause.swift "BLOCKER"
printf 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;\nIPHONEOS_DEPLOYMENT_TARGET = 17.0;\n' > "$repo/App.xcodeproj/project.pbxproj"
g add -A; g commit -q -m targets
run
expect_avail "project.pbxproj com alvos diferentes por target: WARNING" Sources/Shop/Pause.swift "WARNING"
printf '{"min_platforms": {"ios": "16.1"}}\n' > "$work/min.json"
run --policy "$work/min.json"
expect_avail "min_platforms 16.1 na política permite Task.sleep(for:)" Sources/Shop/Pause.swift ""
printf '{"min_platforms": {"ios": "15.10"}}\n' > "$work/min.json"
run --policy "$work/min.json"
expect_avail "versão comparada como número de versão (15.10 < 16)" Sources/Shop/Pause.swift "BLOCKER"

# --- 9: testes ausentes --------------------------------------------------
build tests-missing; run
expect_count "Swift alterado sem teste: WARNING" CORE-TESTS-MISSING WARNING 1
expect_count "teste ausente não vira BLOCKER" CORE-TESTS-MISSING BLOCKER 0

# --- 10: política opcional ---------------------------------------------
if jq -e '.context.policy == null' "$work/out.json" >/dev/null; then ok "sem política: só verificações universais"; else fail "sem política" "política carregada"; fi
if jq -e 'any(.not_evaluated[]; contains("nenhuma declarada na política"))' "$work/out.json" >/dev/null; then
  ok "sem política: verificações obrigatórias declaradas como não avaliadas"; else fail "sem política: não avaliado" "ausente"; fi
printf '{"required_checks": ["tests", "lint"]}\n' > "$work/policy.json"
run --policy "$work/policy.json"
expect_count "verificação obrigatória sem evidência: WARNING" CORE-CHECK-UNPROVEN WARNING 2
printf '{"checks": [{"name": "tests", "command": "swift test", "exit": 1}, {"name": "lint", "command": "swiftlint", "exit": 0}]}\n' > "$work/evidence.json"
run --policy "$work/policy.json" --evidence "$work/evidence.json"
expect_count "verificação obrigatória com falha: BLOCKER" CORE-CHECK-FAILED BLOCKER 1
expect_count "verificação obrigatória que passou: sem achado" CORE-CHECK-UNPROVEN "" 0
printf '{"required_checks": [], "segredo_corporativo": 1}\n' > "$work/bad-policy.json"
run --policy "$work/bad-policy.json"
expect_status "política com chave desconhecida: erro" 2
PRE_PR_AUDIT_POLICY="$work/nao-existe.json" run
expect_status "política configurada e ausente: erro" 2
printf '{"scope_paths": ["Tests/*"]}\n' > "$repo/.pre-pr-audit.json"
g add -A; g commit -q -m policy
run
expect_count "política local do repositório: arquivo fora do escopo" CORE-SCOPE WARNING 2
run --scope 'Sources/*' --scope '.pre-pr-audit.json' --policy "$work/policy.json"
expect_count "--policy prevalece sobre o arquivo do repositório" CORE-SCOPE "" 0

# --- 11: diff vazio -----------------------------------------------------
build empty-diff; run
expect_count "diff vazio: INFO" CORE-EMPTY-DIFF INFO 1
expect_status "diff vazio: status 0" 0
if [ "$(jq '.findings | length' "$work/out.json")" = 1 ]; then ok "diff vazio: nenhum outro achado"; else fail "diff vazio" "achados extras"; fi

# --- 12: múltiplas linguagens ------------------------------------------
build multi-language; run
expect_count "TypeScript sem teste: 1 WARNING" CORE-TESTS-MISSING WARNING 1
expect_evidence "aviso de teste aponta só TypeScript" CORE-TESTS-MISSING "TypeScript"
if jq -e 'any(.findings[]; .rule == "CORE-TESTS-MISSING" and (.evidence | test("Python|Swift")))' "$work/out.json" >/dev/null; then
  fail "Python e Swift com teste não são sinalizados" "sinalizados"; else ok "Python e Swift com teste não são sinalizados"; fi

# --- regressão funcional e contrato -------------------------------------
build mutation-fallback; run
expect_count "mutação com fallback para V1: WARNING" SWIFT-MUTATION-FALLBACK WARNING 1
expect_evidence "fallback aponta applyCoupon, não fetchCart" SWIFT-MUTATION-FALLBACK "applyCoupon"

build contract-keys; run
expect_count "chave de CodingKeys renomeada: WARNING" SWIFT-CONTRACT-KEYS WARNING 1
expect_evidence "contrato cita a chave antiga" SWIFT-CONTRACT-KEYS "'orderId'"

build protocol-requirement; run
expect_count "requisito novo sem implementação padrão: 1 WARNING" SWIFT-PROTOCOL-REQUIREMENT WARNING 1
expect_evidence "requisito sinalizado é o do CartServicing" SWIFT-PROTOCOL-REQUIREMENT "CartServicing"

build swift-hygiene; run
expect_count "@unchecked Sendable: WARNING" SWIFT-CONCURRENCY-UNSAFE WARNING 1
expect_count "deprecated sem mensagem: INFO" SWIFT-DEPRECATED-NO-MESSAGE INFO 1
expect_count "XCTest e Testing no mesmo arquivo: WARNING" SWIFT-TEST-FRAMEWORK-MIX WARNING 1
printf '\n@available(*, deprecated)\nfunc legacyHelper() {}\n' >> "$repo/Tests/ShopTests/CounterTests.swift"
g add -A; g commit -q -m deprecated-test
run
expect_count "deprecated sem mensagem em arquivo de teste: ignorado" SWIFT-DEPRECATED-NO-MESSAGE "" 1

# --- segurança e duplicação (conteúdo gerado aqui) ----------------------
build pipeline-unified
token="gh""p_$(printf 'A%.0s' $(seq 1 36))"
home_path="/Us""ers/fulano/projeto"
printf 'let token = "%s"\nlet base = "%s/config"\nlet password = "%s"\n' "$token" "$home_path" "ficticio-123456" > "$repo/Sources/Shop/Config.swift"
g add -A; g commit -q -m config
run
expect_count "token em formato conhecido: BLOCKER" CORE-SECRET BLOCKER 1
if grep -q "$token" "$work/out.json"; then fail "token mascarado no relatório" "token exposto"; else ok "token mascarado no relatório"; fi
expect_count "caminho pessoal: WARNING" CORE-LOCAL-PATH WARNING 1
expect_count "atribuição literal a password: WARNING heurístico" CORE-SECRET-LIKE WARNING 1

build pipeline-unified
block='let a = compute(1)
let b = transform(a, mode: .fast)
let c = validate(b, strict: true)
let d = persist(c, into: store)
let e = notify(d, channel: .main)
let f = finish(e, status: .ok)'
printf 'func one() {\n%s\n}\n' "$block" > "$repo/Sources/Shop/One.swift"
printf 'func two() {\n%s\n}\n' "$block" > "$repo/Sources/Shop/Two.swift"
g add -A; g commit -q -m dup
run
expect_count "bloco repetido em dois arquivos: 1 WARNING" CORE-DUPLICATION WARNING 1

# --- reprodutibilidade e formatos --------------------------------------
build pipeline-duplicated; run; cp "$work/out.json" "$work/first.json"; run
if cmp -s "$work/first.json" "$work/out.json"; then ok "duas execuções produzem o mesmo JSON"; else fail "reprodutível" "saídas diferentes"; fi
md=$(python3 "$AUDIT" --repo "$repo" --base main 2>/dev/null || true)
for section in "## Achados" "## Verificado" "## Não avaliado" "## Revisão adversarial (pendente)"; do
  if printf '%s\n' "$md" | grep -q "^$section"; then ok "markdown tem $section"; else fail "markdown" "sem $section"; fi
done
status=0; python3 "$AUDIT" --repo "$repo" --base nao-existe >/dev/null 2>&1 || status=$?
expect_status "base inexistente: erro" 2
status=0; python3 "$AUDIT" --repo "$work" >/dev/null 2>&1 || status=$?
expect_status "diretório fora de repositório git: erro" 2

if [ "$failures" -gt 0 ]; then
  echo "$failures falha(s)" >&2
  exit 1
fi
echo "todos os cenários passaram"
