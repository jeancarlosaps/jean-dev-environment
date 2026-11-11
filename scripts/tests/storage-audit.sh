#!/usr/bin/env bash
# Harness de storage-audit.sh. Não altera arquivos versionados.
# O script sob teste é invocado via `bash` (não depende de +x no tree).
set -eu
set -o pipefail

ROOT=$(cd -P "$(dirname "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/storage-audit.sh"

if [ ! -f "$AUDIT" ]; then
  echo "script ausente: $AUDIT" >&2
  exit 1
fi

# Snapshot de permissões do script versionado — o harness não pode alterá-las.
AUDIT_MODE_BEFORE=$(ls -l "$AUDIT" | awk '{print $1}')

# Invoca o script via bash; variáveis de ambiente vêm do caller.
run_audit() {
  bash "$AUDIT" "$@"
}

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

assert_lacks() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s\n' "$haystack" | grep -q "$needle"; then
    echo "FALHOU $label: nao deveria conter [$needle]" >&2
    echo "$haystack" >&2
    failures=$((failures + 1))
  else
    echo "ok $label"
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/storage-audit-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# --- help ---
out=$(run_audit --help 2>&1) || true
assert_contains "help" "$out" "somente leitura"

# --- limites invalidos ---
set +e
out=$(DEV_STORAGE_OK_GIB=5 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  bash "$AUDIT" "$work" 2>&1)
st=$?
set -e
assert_status "limits_order_exit" 2 "$st"
assert_contains "limits_order_msg" "$out" "CRIT <= WARN <= OK"

set +e
out=$(DEV_STORAGE_OK_GIB=abc DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  bash "$AUDIT" "$work" 2>&1)
st=$?
set -e
assert_status "limits_non_int_exit" 2 "$st"
assert_contains "limits_non_int_msg" "$out" "inteiros"

# --- limites exatos (FREE injetado; sem depender do df da máquina) ---
# free < CRIT → CRITICO
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=9 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_crit_below" "$out" "estado=CRITICO"

# free == CRIT → ATENCAO (não crítico)
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=10 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_crit_eq" "$out" "estado=ATENCAO"

# free == OK-1 → ATENCAO
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=19 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_ok_below" "$out" "estado=ATENCAO"

# free == OK → NORMAL
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=20 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_ok_eq" "$out" "estado=NORMAL"

# CRIT < WARN < OK
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=5 \
  DEV_STORAGE_FREE_GIB=7 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_between_crit_warn" "$out" "estado=ATENCAO"
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=5 \
  DEV_STORAGE_FREE_GIB=4 bash "$AUDIT" "$work" 2>&1)
assert_contains "bound_below_split_crit" "$out" "estado=CRITICO"

# --- repo com worktree (caminho com espaço) ---
repo="$work/repo with spaces"
mkdir -p "$repo"
git init -q "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" config user.name "Tester"
git -C "$repo" config user.email "tester@example.com"
git -C "$repo" config commit.gpgsign false
# Preferência que omitiria untracked sem -unormal
git -C "$repo" config status.showUntrackedFiles no
echo base >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -q -m "chore: base"

git -C "$repo" branch feature/demo
wt="$work/wt demo"
git -C "$repo" worktree add -q "$wt" feature/demo
echo dirty >"$wt/extra.txt"

repo_real=$(cd -P "$repo" && pwd)
wt_real=$(cd -P "$wt" && pwd)

out=$(DEV_STORAGE_OK_GIB=1 DEV_STORAGE_WARN_GIB=0 DEV_STORAGE_CRIT_GIB=0 \
  DEV_STORAGE_FREE_GIB=5 bash "$AUDIT" "$repo" 2>&1)
st=$?
assert_status "exit_ok" 0 "$st"
assert_contains "estado_normal" "$out" "estado=NORMAL"
assert_contains "worktree_path" "$out" "path=$repo_real"
assert_contains "worktree_extra" "$out" "path=$wt_real"
assert_contains "dirty_untracked" "$out" "dirty=1"
assert_contains "review" "$out" "revisao_humana"
assert_contains "readonly" "$out" "somente_leitura=1"
assert_contains "limites" "$out" "ok_GiB=1"

# --- df real (portabilidade): deve reportar livre_GiB numérico ---
out=$(DEV_STORAGE_OK_GIB=1 DEV_STORAGE_WARN_GIB=0 DEV_STORAGE_CRIT_GIB=0 \
  bash "$AUDIT" "$repo" 2>&1)
assert_contains "df_real_estado" "$out" "estado="
free_line=$(printf '%s\n' "$out" | grep '^livre_GiB=' || true)
case "$free_line" in
  livre_GiB=[0-9]*) echo "ok df_real_gib" ;;
  *)
    echo "FALHOU df_real_gib: $free_line" >&2
    failures=$((failures + 1))
    ;;
esac

# --- caminho inexistente ---
set +e
DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=5 bash "$AUDIT" "$work/nao-existe" >/dev/null 2>&1
st=$?
set -e
assert_status "missing_path" 2 "$st"

# --- diretorio sem git ---
empty="$work/empty"
mkdir -p "$empty"
out=$(DEV_STORAGE_OK_GIB=20 DEV_STORAGE_WARN_GIB=10 DEV_STORAGE_CRIT_GIB=10 \
  DEV_STORAGE_FREE_GIB=50 bash "$AUDIT" "$empty" 2>&1)
assert_contains "not_git" "$out" "nao_e_repositorio_git=1"

# --- harness nao alterou o script versionado ---
AUDIT_MODE_AFTER=$(ls -l "$AUDIT" | awk '{print $1}')
assert_status "mode_unchanged" "$AUDIT_MODE_BEFORE" "$AUDIT_MODE_AFTER"

if [ "$failures" -gt 0 ]; then
  echo "Falhas: $failures" >&2
  exit 1
fi
echo "Todos os testes passaram."
exit 0
