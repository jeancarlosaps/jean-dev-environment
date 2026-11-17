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

# --- review do PR: falha fechada da política e da evidência -------------
build tests-missing
for bad in '{"ignore_paths": "x*"}' '{"scope_paths": "Sources/*"}' '{"required_checks": "tests"}' \
           '{"verb_synonyms": ["del", "remove"]}' '{"min_platforms": ["15"]}' '{"min_platforms": {"ios": "quinze"}}' \
           '{"library": "sim"}' '[]'; do
  printf '%s\n' "$bad" > "$work/bad.json"
  run --policy "$work/bad.json"
  expect_status "política com tipo inválido ($bad): erro, nunca relatório vazio" 2
done
for bad in '{"checks": "tests"}' '{"checks": [{"name": "tests", "exit": "0"}]}' '{"checks": [{"exit": 0}]}'; do
  printf '%s\n' "$bad" > "$work/bad.json"
  run --evidence "$work/bad.json"
  expect_status "evidência inválida ($bad): erro" 2
done
printf '{"ignore_paths": ["Sources/Shop/Nada/*"]}\n' > "$work/ok.json"
run --policy "$work/ok.json"
expect_status "ignore_paths válido não ignora o resto" 0
expect_count "ignore_paths válido mantém a auditoria do diff" CORE-TESTS-MISSING WARNING 1

# --- review do PR: caminhos Unicode, espaços, renomeação e exclusão -----
build pipeline-unified
token="gh""p_$(printf 'B%.0s' $(seq 1 36))"
mkdir -p "$repo/Sources/Shop/Configuração Avançada"
printf 'let chave = "%s"\nfunc espera() async throws { try await Task.sleep(for: .seconds(1)) }\n' "$token" \
  > "$repo/Sources/Shop/Configuração Avançada/Ação de Teste.swift"
mkdir -p "$repo/Módulos/Novo/Sources/Novo"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Novo", platforms: [.iOS("17.0"), .macOS("14.0")])\n' > "$repo/Módulos/Novo/Package.swift"
printf 'func pausa() async throws { try await Task.sleep(for: .seconds(1)) }\n' > "$repo/Módulos/Novo/Sources/Novo/Pausa.swift"
g add -A; g commit -q -m unicode
run
expect_status "caminho Unicode com espaço e credencial: BLOCKER, não diff ignorado" 1
if jq -e --arg f "Sources/Shop/Configuração Avançada/Ação de Teste.swift" \
    '[.findings[] | select(.file == $f) | .rule] | (index("CORE-SECRET") != null and index("SWIFT-AVAILABILITY") != null)' "$work/out.json" >/dev/null; then
  ok "arquivo com acento e espaço auditado pelo caminho real"; else fail "caminho Unicode" "arquivo ausente ou caminho escapado"; fi
expect_avail "Package.swift em diretório acentuado com .iOS(\"17.0\") vale para o submódulo" "Módulos/Novo/Sources/Novo/Pausa.swift" ""

build pipeline-unified
printf 'public struct Antiga {\n    public init() {}\n    public func valor() -> Int { 1 }\n}\n' > "$repo/Sources/Shop/Antiga.swift"
g add -A; g commit -q -m base-extra; g branch -f main HEAD
g mv "Sources/Shop/Antiga.swift" "Sources/Shop/Nova Pasta Ação/Antiga.swift" 2>/dev/null || {
  mkdir -p "$repo/Sources/Shop/Nova Pasta Ação"; g mv "Sources/Shop/Antiga.swift" "Sources/Shop/Nova Pasta Ação/Antiga.swift"; }
g commit -q -m rename
run
expect_count "renomeação de arquivo com API pública intacta: sem quebra" SWIFT-API-BREAK "" 0
expect_count "renomeação pura: sem linhas adicionadas a auditar" CORE-TESTS-MISSING "" 0
g rm -q "Sources/Shop/Nova Pasta Ação/Antiga.swift"; g commit -q -m delete
run
expect_count "exclusão de arquivo com tipo público: quebra detectada" SWIFT-API-BREAK BLOCKER 3
expect_evidence "exclusão cita o tipo removido" SWIFT-API-BREAK "<global>.struct Antiga"

build pipeline-unified
printf 'struct Interna {\n    func valor() -> Int { 1 }\n}\n' > "$repo/Sources/Shop/Interna.swift"
g add -A; g commit -q -m base-interna; g branch -f main HEAD
g rm -q Sources/Shop/Interna.swift; g commit -q -m delete-interna
run
expect_count "exclusão de tipo interno: sem quebra de API" SWIFT-API-BREAK "" 0
if jq -e 'any(.not_evaluated[]; contains("só exclusões"))' "$work/out.json" >/dev/null; then
  ok "diff só com exclusão declara o que não avaliou"; else fail "só exclusões" "sem declaração"; fi

printf 'x\n' > "$repo/arquivo
quebrado.swift"
g add -A; g commit -q -m newline
run
expect_status "caminho com quebra de linha: erro, nunca relatório vazio" 2

# --- review do PR: compatibilidade de API pública -----------------------
api_case() {  # api_case <antes> <depois>: monta main/feature com Sources/Shop/Api.swift
  build pipeline-unified
  printf '%s\n' "$1" > "$repo/Sources/Shop/Api.swift"
  g add -A; g commit -q -m api-base; g branch -f main HEAD
  printf '%s\n' "$2" > "$repo/Sources/Shop/Api.swift"
  g add -A; g commit -q -m api-change
  run
}
api_case 'public struct S {
    public func find(id: String = "") {}
}' 'public struct S {
    public func find(id: String) {}
}'
expect_count "remover valor padrão quebra quem omite o argumento: BLOCKER" SWIFT-API-BREAK BLOCKER 1
api_case 'public struct S {
    public func find(id: String) {}
}' 'public struct S {
    public func find(id: String = "") {}
}'
expect_count "acrescentar valor padrão não quebra chamadas: sem achado" SWIFT-API-BREAK "" 0
api_case 'public struct S {
    public func find(id: String = "a") {}
}' 'public struct S {
    public func find(id: String = "b") {}
}'
expect_count "trocar só o valor do padrão: sem achado" SWIFT-API-BREAK "" 0
api_case 'public struct S {
    public func find(id value: String) {}
}' 'public struct S {
    public func find(id item: String) {}
}'
expect_count "trocar só o nome local do parâmetro: sem achado" SWIFT-API-BREAK "" 0
api_case 'public struct S {
    public func find(id value: String) {}
}' 'public struct S {
    public func find(key value: String) {}
}'
expect_count "trocar o rótulo externo: BLOCKER" SWIFT-API-BREAK BLOCKER 1
api_case 'public struct S {}
public extension S {
    func removeItem(id: String) {}
    private func hidden() {}
}' 'public struct S {}
public extension S {
    private func hidden2() {}
}'
expect_count "membro de public extension removido: BLOCKER" SWIFT-API-BREAK BLOCKER 1
expect_evidence "membro de public extension identificado" SWIFT-API-BREAK "S.func removeItem(id:String)"
api_case 'public struct S {}
extension S {
    func removeItem(id: String) {}
}' 'public struct S {}
extension S {
}'
expect_count "membro de extensão interna removido: sem achado" SWIFT-API-BREAK "" 0
api_case 'public struct S {}
public extension S {
    func removeItem(id: String) {}
}' 'public struct S {
    public func removeItem(id: String) {}
}'
expect_count "membro movido de public extension para declaração public: sem achado" SWIFT-API-BREAK "" 0
api_case 'public enum Mode {
    case fast
    case slow(Int)
    func f() -> Int { switch self { case .fast: return 1; case .slow: return 2 } }
}' 'public enum Mode {
    case fast
    func f() -> Int { switch self { case .fast: return 1 } }
}'
expect_count "case removido de enum público: BLOCKER" SWIFT-API-BREAK BLOCKER 1
expect_evidence "case removido identificado" SWIFT-API-BREAK "Mode.case slow(Int)"
api_case 'enum Mode {
    case fast
    case slow
}' 'enum Mode {
    case fast
}'
expect_count "case removido de enum interno: sem achado" SWIFT-API-BREAK "" 0
api_case 'public enum Code: Int {
    case ok = 200
}' 'public enum Code: Int {
    case ok = 201
}'
expect_count "valor bruto de case alterado não é quebra de assinatura" SWIFT-API-BREAK "" 0

# --- review do PR: credencial nunca reexposta no relatório -------------
build pipeline-unified
token="gh""p_$(printf 'C%.0s' $(seq 1 36))"
printf 'public final class Box: @unchecked Sendable { let k = "%s"; func w() async throws { try await Task.sleep(for: .seconds(1)) } }\n' "$token" \
  > "$repo/Sources/Shop/Box.swift"
printf 'let apiKey = "%s"\n' "$token" > "$repo/Sources/Shop/Keys.swift"
g add -A; g commit -q -m leak
run
same_line=$(jq '[.findings[] | select(.file == "Sources/Shop/Box.swift" and .line == 1)] | length' "$work/out.json")
if [ "$same_line" -ge 3 ]; then ok "três ou mais achados na mesma linha com credencial ($same_line)"; else fail "achados na mesma linha" "$same_line"; fi
python3 "$AUDIT" --repo "$repo" --base main > "$work/out.md" 2>/dev/null || true
for format in json md; do
  if grep -q "${token:0:10}" "$work/out.$format"; then fail "nenhum trecho da credencial no relatório ($format)" "token exposto"
  else ok "nenhum trecho da credencial no relatório ($format)"; fi
done
expect_evidence "evidência de concorrência sem o literal" SWIFT-CONCURRENCY-UNSAFE "@unchecked Sendable"

# --- quarto review -------------------------------------------------------
pair_case() {  # pair_case <arquivo> <antes|-> <depois|->: main com "antes", feature com "depois"
  build pipeline-unified
  if [ "$2" != - ]; then mkdir -p "$repo/$(dirname "$1")"; printf '%s\n' "$2" > "$repo/$1"; fi
  g add -A; g commit -q --allow-empty -m pair-base; g branch -f main HEAD
  if [ "$3" = - ]; then g rm -q "$1"; else mkdir -p "$repo/$(dirname "$1")"; printf '%s\n' "$3" > "$repo/$1"; g add -A; fi
  g commit -q -m pair-change
  run
}
lines_of() {  # lines_of <regra> <arquivo>
  jq -r --arg r "$1" --arg f "$2" '[.findings[] | select(.rule == $r and .file == $f) | .line] | map(tostring) | join(",")' "$work/out.json"
}
expect_lines() {  # expect_lines <label> <regra> <arquivo> <linhas>
  local got; got=$(lines_of "$2" "$3")
  if [ "$got" = "$4" ]; then ok "$1"; else fail "$1" "$2 em $3: linhas [$got], esperado [$4]"; fi
}

# R1: conteúdo adicionado começando com ++ não é cabeçalho
token="gh""p_$(printf 'D%.0s' $(seq 1 36))"
f1="Sources/Shop/Operadores Ação/Inc.swift"
pair_case "$f1" 'var counter = 0
--counter' "$(printf '++counter; let k = "%s"\nfunc w() async throws { try await Task.sleep(for: .seconds(1)) }\n+++counter' "$token")"
expect_lines "linha adicionada começando com ++ é auditada (credencial)" CORE-SECRET "$f1" "1"
expect_lines "numeração depois da linha ++ continua correta" SWIFT-AVAILABILITY "$f1" "2"
for format in json md; do
  if [ "$format" = md ]; then python3 "$AUDIT" --repo "$repo" --base main > "$work/out.md" 2>/dev/null || true; fi
  if grep -q "${token:0:10}" "$work/out.$format"; then fail "credencial da linha ++ mascarada ($format)" "exposta"; else ok "credencial da linha ++ mascarada ($format)"; fi
done
pair_case "Sources/Shop/Plain.swift" 'let a = 1' 'let a = 1
let b = 2'
expect_count "diff comum continua com cabeçalhos tratados como cabeçalho" CORE-SECRET "" 0

# R2: #available em qualquer posição da lista de condições
f2="Sources/Shop/Cond.swift"
pair_case "$f2" - 'func f(enabled: Bool, value: Int?) async throws {
    if enabled, #available(iOS 16, macOS 13, *) {
        try await Task.sleep(for: .seconds(1))
    }
    if let v = value,
       v > 0,
       #available(iOS 16, macOS 13, *) {
        if v > 1 {
            try await Task.sleep(for: .seconds(1))
        }
    }
    guard enabled, #available(iOS 16, macOS 13, *) else { return }
    try await Task.sleep(for: .seconds(1))
}
func g(running: Bool) async throws {
    while running, #available(iOS 16, macOS 13, *) {
        try await Task.sleep(for: .seconds(1))
    }
    if running, #available(iOS 16, macOS 13, *) {
    }
    try await Task.sleep(for: .seconds(1))
}'
expect_lines "#available depois de outras condições protege if, guard, while e bloco aninhado; uso fora do bloco não" SWIFT-AVAILABILITY "$f2" "21"

# R3: @available protege só a declaração que o recebe
f3="Sources/Shop/Attr.swift"
pair_case "$f3" - '@available(iOS 16, macOS 13, *)
typealias Clock = ContinuousClock
func afterAlias() async throws {
    try await Task.sleep(for: .seconds(1))
}
@available(iOS 16, macOS 13, *)
@MainActor
func protectedBody() async throws {
    try await Task.sleep(for: .seconds(1))
}
@available(iOS 16, macOS 13, *)
let stored = 1
func afterStored() async throws {
    try await Task.sleep(for: .seconds(1))
}
@available(iOS 16, macOS 13, *)
var computed: Int {
    _ = ContinuousClock()
    return 1
}
@available(iOS 16, macOS 13, *)
func split()
    async throws
{
    try await Task.sleep(for: .seconds(1))
}'
expect_lines "proteção não vaza de typealias nem de propriedade armazenada; corpo, atributos múltiplos e assinatura em várias linhas protegem" SWIFT-AVAILABILITY "$f3" "4,14"

# R4: public typealias
pair_case "Sources/Shop/Alias.swift" 'public typealias ID = String' 'public typealias ID = Int'
expect_count "typealias público com outro tipo: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Alias.swift" 'public typealias ID = String' 'public typealias ID=String'
expect_count "typealias só reformatado: sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Alias.swift" 'public typealias Handler<T> = (T) -> Void' 'public typealias Handler<T> = (T) throws -> Void'
expect_count "typealias genérico com outro tipo: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Alias.swift" 'public typealias Handler<T> = (T) -> Void' 'public typealias Handler<T> = ( T )->Void'
expect_count "typealias genérico só reformatado: sem achado" SWIFT-API-BREAK "" 0

# R5: estático × instância
pair_case "Sources/Shop/Load.swift" 'public struct S {
    public static func load() {}
}' 'public struct S {
    public func load() {}
}'
expect_count "static func vira método de instância: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Load.swift" 'public struct S {
    public func load() {}
}' 'public struct S {
    public static func load() {}
}'
expect_count "método de instância vira static: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Load.swift" 'public class C {
    public class func make() {}
}' 'public class C {
    public static func make() {}
}'
expect_count "class func para static func (ambos do tipo): sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Load.swift" 'public struct S {}
public extension S {
    static func load() {}
}' 'public struct S {}
public extension S {
    func load() {}
}'
expect_count "static em public extension vira instância: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Load.swift" 'public struct S {
    public static func load() {}
}' 'public struct S {
    public   static   func load( ) {}
}'
expect_count "static só reformatado: sem achado" SWIFT-API-BREAK "" 0

# R6: módulo de origem
build pipeline-unified
printf '// swift-tools-version:5.7\nimport PackageDescription\nlet package = Package(name: "Shop", platforms: [.iOS(.v15), .macOS(.v12)], products: [.library(name: "Shop", targets: ["Shop"]), .library(name: "Other", targets: ["Other"]), .library(name: "Core", targets: ["Core"])], targets: [.target(name: "Shop"), .target(name: "Other"), .target(name: "Core", path: "Lib/Core")])\n' > "$repo/Package.swift"
mkdir -p "$repo/Sources/Other" "$repo/Lib/Core" "$repo/Loose"
client='public struct Client {
    public func fetch() {}
}'
printf '%s\n' "$client" > "$repo/Sources/Shop/Client.swift"; printf '%s\n' "$client" > "$repo/Sources/Other/Client.swift"
printf 'public struct Engine {\n    public func start() {}\n}\n' > "$repo/Lib/Core/Engine.swift"
printf 'public struct Loose {\n    public func go() {}\n}\n' > "$repo/Loose/Loose.swift"
g add -A; g commit -q -m modules; g branch -f main HEAD
printf 'public struct Client {\n}\n' > "$repo/Sources/Shop/Client.swift"
mkdir -p "$repo/Lib/Core/Sub"; g mv Lib/Core/Engine.swift Lib/Core/Sub/Engine.swift
printf '// mudança\n' >> "$repo/Lib/Core/Sub/Engine.swift"
mkdir -p "$repo/Elsewhere"; g mv Loose/Loose.swift Elsewhere/Loose.swift; printf '// mudança\n' >> "$repo/Elsewhere/Loose.swift"
g add -A; g commit -q -m modules-change
run
expect_count "API removida de um target com homônimo em outro: BLOCKER" SWIFT-API-BREAK BLOCKER 1
expect_evidence "quebra cita o homônimo de outro módulo" SWIFT-API-BREAK "homônimo em outro módulo (Other)"
if jq -e 'any(.findings[]; .rule == "SWIFT-API-BREAK" and (.evidence | contains("Engine")))' "$work/out.json" >/dev/null; then
  fail "movimento dentro do mesmo target (path: customizado) não é quebra" "Engine sinalizado"; else ok "movimento dentro do mesmo target (path: customizado) não é quebra"; fi
expect_count "arquivo fora de qualquer target movido: WARNING de origem, não BLOCKER" SWIFT-API-ORIGIN-UNKNOWN WARNING 2
build pipeline-unified
printf '// swift-tools-version:5.7\nimport PackageDescription\nlet package = Package(name: "Shop", platforms: [.iOS(.v15)], products: [.library(name: "Shop", targets: ["Shop", "Other"])], targets: [.target(name: "Shop"), .target(name: "Other")])\n' > "$repo/Package.swift"
mkdir -p "$repo/Sources/Other"
printf 'public struct Mover {\n    public func go() {}\n}\n' > "$repo/Sources/Shop/Mover.swift"
g add -A; g commit -q -m mover; g branch -f main HEAD
g mv Sources/Shop/Mover.swift Sources/Other/Mover.swift; g commit -q -m move-target
run
expect_count "arquivo movido para outro target: API sai do módulo original (BLOCKER)" SWIFT-API-BREAK BLOCKER 2
g mv Sources/Other/Mover.swift Sources/Other/Mover2.swift; g branch -f main HEAD~0; g commit -q -m rename-same-dir
run
expect_count "arquivo renomeado no mesmo diretório: sem achado" SWIFT-API-BREAK "" 0

# R7: remoção da CodingKeys
item_before='public struct Item: Codable {
    public let id: String
    public let name: String
    enum CodingKeys: String, CodingKey {
        case id = "item_id"
        case name
    }
}'
pair_case "Sources/Shop/Item.swift" "$item_before" 'public struct Item: Codable {
    public let id: String
    public let name: String
}'
expect_count "CodingKeys com mapeamento customizado removida: WARNING" SWIFT-CONTRACT-KEYS WARNING 1
expect_evidence "contrato cita a chave que muda" SWIFT-CONTRACT-KEYS "'item_id' passa a ser 'id'"
pair_case "Sources/Shop/Item.swift" 'public struct Item: Codable {
    public let id: String
    enum CodingKeys: String, CodingKey {
        case id
    }
}' 'public struct Item: Codable {
    public let id: String
}'
expect_count "CodingKeys equivalente ao nome sintetizado removida: sem achado" SWIFT-CONTRACT-KEYS "" 0
pair_case "Sources/Shop/Item.swift" "$item_before" 'public struct Item: Codable {
    public let id: String
    public let name: String
    public init(from decoder: Decoder) throws { fatalError() }
    public func encode(to encoder: Encoder) throws {}
}'
expect_count "CodingKeys removida com encode/decode explícito: INFO" SWIFT-CONTRACT-KEYS INFO 1
pair_case "Sources/Shop/Item.swift" "$item_before" 'public struct Other {}'
expect_count "tipo removido: sem achado de contrato (a remoção é de API)" SWIFT-CONTRACT-KEYS "" 0

# --- visibilidade efetiva (apontamento anterior não coberto) ------------
pair_case "Sources/Shop/Hidden.swift" 'struct Hidden {}
extension Hidden: Equatable {}' 'struct Hidden {}'
expect_count "conformidade removida de struct interna: sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Hidden.swift" 'struct Hidden {
    public func f() {}
}' 'struct Hidden {
}'
expect_count "membro public de struct interna removido: sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Hidden.swift" 'public struct Outer {
    struct Inner {
        public func f() {}
    }
}' 'public struct Outer {
    struct Inner {
    }
}'
expect_count "membro public de tipo aninhado interno removido: sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Hidden.swift" 'public struct Visible {}
protocol Tagged {}
extension Visible: Tagged {}' 'public struct Visible {}
protocol Tagged {}'
expect_count "conformidade de tipo público a protocolo interno removida: sem achado" SWIFT-API-BREAK "" 0
pair_case "Sources/Shop/Hidden.swift" 'public struct Visible {
    public func f() {}
}' 'struct Visible {
}'
expect_count "tipo público que vira interno: tipo e membro continuam BLOCKER" SWIFT-API-BREAK BLOCKER 2
pair_case "Sources/Shop/Ext.swift" 'extension String {
    public func shout() -> String { self }
}' 'extension String {
}'
expect_count "membro public em extensão de tipo de outro módulo removido: BLOCKER" SWIFT-API-BREAK BLOCKER 1
pair_case "Sources/Shop/Pk.swift" 'package struct Pk {
    public func f() {}
}' 'package struct Pk {
}'
expect_count "membro public de tipo package removido: WARNING, não BLOCKER" SWIFT-API-BREAK WARNING 1
expect_evidence "visibilidade incerta explica o motivo" SWIFT-API-BREAK "Pk tem acesso package"

# extensões em outro arquivo
vis_files() {  # vis_files <tipo base> <extensão base> <extensão head|->
  build pipeline-unified
  printf '%s\n' "$1" > "$repo/Sources/Shop/VisType.swift"; printf '%s\n' "$2" > "$repo/Sources/Shop/VisExt.swift"
  g add -A; g commit -q -m vis-base; g branch -f main HEAD
  if [ "$3" = - ]; then g rm -q Sources/Shop/VisExt.swift; else printf '%s\n' "$3" > "$repo/Sources/Shop/VisExt.swift"; g add -A; fi
  g commit -q -m vis-change; run
}
vis_files 'struct Hidden {}' 'extension Hidden: Equatable {
    public func g() {}
}' -
expect_count "extensão de tipo interno em outro arquivo removida: sem achado" SWIFT-API-BREAK "" 0
vis_files 'struct Hidden {}' 'extension Hidden {
    public func g() {}
}' 'extension Hidden {
}'
expect_count "membro public de extensão de tipo interno em outro arquivo: sem achado" SWIFT-API-BREAK "" 0
vis_files 'public struct Visible {}' 'extension Visible: Equatable {}' -
expect_count "conformidade de tipo público em outro arquivo removida: BLOCKER" SWIFT-API-BREAK BLOCKER 1
vis_files 'public struct Visible {}' 'extension Visible {
    public func g() {}
}' 'extension Visible {
}'
expect_count "membro public de extensão de tipo público em outro arquivo: BLOCKER" SWIFT-API-BREAK BLOCKER 1
vis_files 'public enum Outer {
    struct Inner {}
}' 'extension Outer.Inner {
    public func g() {}
}' 'extension Outer.Inner {
}'
expect_count "extensão de tipo aninhado interno em outro arquivo: sem achado" SWIFT-API-BREAK "" 0

# homônimo público e interno em targets diferentes: visibilidade incerta
build pipeline-unified
printf '// swift-tools-version:5.7\nimport PackageDescription\nlet package = Package(name: "Shop", platforms: [.iOS(.v15)], products: [.library(name: "Shop", targets: ["Shop", "Other"])], targets: [.target(name: "Shop"), .target(name: "Other")])\n' > "$repo/Package.swift"
mkdir -p "$repo/Sources/Other"
printf 'public struct Twin {}\n' > "$repo/Sources/Shop/Twin.swift"
printf 'struct Twin {}\nextension Twin: Equatable {}\n' > "$repo/Sources/Other/Twin.swift"
g add -A; g commit -q -m twins; g branch -f main HEAD
printf 'struct Twin {}\n' > "$repo/Sources/Other/Twin.swift"; g add -A; g commit -q -m twins-change
run
expect_count "homônimo público e interno: WARNING, não BLOCKER" SWIFT-API-BREAK WARNING 1
expect_count "homônimo público e interno: nenhum BLOCKER" SWIFT-API-BREAK BLOCKER 0
expect_evidence "visibilidade incerta cita o tipo ambíguo" SWIFT-API-BREAK "Twin tem declarações com visibilidades diferentes"

# R8: falha ao gravar --output
build pipeline-unified
for target in "$work/nao/existe/out.json" "$work"; do
  status=0; python3 "$AUDIT" --repo "$repo" --base main --output "$target" >/dev/null 2>"$work/err.txt" || status=$?
  if [ "$status" = 2 ] && grep -q "não foi possível gravar o relatório" "$work/err.txt" && ! grep -q Traceback "$work/err.txt"; then
    ok "--output inválido ($target): status 2 com mensagem, sem traceback"; else fail "--output inválido ($target)" "status $status"; fi
done
mkdir -p "$work/ro"; chmod 555 "$work/ro"
if [ ! -w "$work/ro" ]; then
  status=0; python3 "$AUDIT" --repo "$repo" --base main --output "$work/ro/out.json" >/dev/null 2>"$work/err.txt" || status=$?
  if [ "$status" = 2 ] && ! grep -q Traceback "$work/err.txt"; then ok "--output sem permissão: status 2"; else fail "--output sem permissão" "status $status"; fi
else
  ok "--output sem permissão: ignorado (execução com privilégio de escrita)"
fi
chmod 755 "$work/ro"
status=0; python3 "$AUDIT" --repo "$repo" --base main --format json --output "$work/report.json" >/dev/null 2>&1 || status=$?
if [ "$status" = 0 ] && jq -e '.counts' "$work/report.json" >/dev/null; then ok "--output válido grava o relatório"; else fail "--output válido" "status $status"; fi

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
