#!/usr/bin/env bash
# Harness de storage-audit.sh. Somente leitura no script sob teste;
# o harness cria repositórios temporários locais e os remove ao sair.
set -eu
set -o pipefail

ROOT=$(cd -P "$(dirname "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/storage-audit.sh"

if [ ! -x "$AUDIT" ] && [ -f "$AUDIT" ]; then
  chmod +x "$AUDIT"
fi
if [ ! -f "$AUDIT" ]; then
  echo "script ausente: $AUDIT" >&2
  exit 1
fi

failures=0
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s\n' "$haystack" | grep -q "$needle"; then
    echo "FALHOU $label: nao encontrou [$needle]" >&2
    echo "$haystack" >&2
    failures=$((failures + 1))
  else
    echo "ok $label"
  fi
}

assert_status() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FALHOU $label: status $actual, esperado $expected" >&2
    failures=$((failures + 1))
  else
    echo "ok $label"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/storage-audit-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# --- help ---
out=$("$AUDIT" --help 2>&1) || true
assert_contains "help" "$out" "somente leitura"

# --- repo com worktree ---
repo="$work/repo"
git init -q "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" config user.name "Tester"
git -C "$repo" config user.email "tester@example.com"
git -C "$repo" config commit.gpgsign false
echo base >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -q -m "chore: base"

git -C "$repo" branch feature/demo
wt="$work/wt-demo"
git -C "$repo" worktree add -q "$wt" feature/demo
echo dirty >"$wt/extra.txt"

# Limites baixos → estado NORMAL em qualquer máquina com algum espaço livre.
export DEV_STORAGE_OK_GIB=1
export DEV_STORAGE_WARN_GIB=0
export DEV_STORAGE_CRIT_GIB=0

repo_real=$(cd -P "$repo" && pwd)
wt_real=$(cd -P "$wt" && pwd)

out=$("$AUDIT" "$repo" 2>&1)
st=$?
assert_status "exit_ok" 0 "$st"
assert_contains "estado" "$out" "estado=NORMAL"
assert_contains "worktree_path" "$out" "path=$repo_real"
assert_contains "worktree_extra" "$out" "path=$wt_real"
assert_contains "dirty_flag" "$out" "dirty=1"
assert_contains "review" "$out" "revisao_humana"
assert_contains "readonly" "$out" "somente_leitura=1"
assert_contains "limites" "$out" "ok_GiB=1"

# --- caminho inexistente ---
set +e
"$AUDIT" "$work/nao-existe" >/dev/null 2>&1
st=$?
set -e
assert_status "missing_path" 2 "$st"

# --- diretorio sem git ---
empty="$work/empty"
mkdir -p "$empty"
out=$("$AUDIT" "$empty" 2>&1)
assert_contains "not_git" "$out" "nao_e_repositorio_git=1"

if [ "$failures" -gt 0 ]; then
  echo "Falhas: $failures" >&2
  exit 1
fi
echo "Todos os testes passaram."
exit 0
