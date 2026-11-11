#!/usr/bin/env bash
# =====================================================================
# storage-audit.sh — diagnóstico somente leitura de disco e worktrees
# ---------------------------------------------------------------------
# Não exclui arquivos. Não exige privilégios administrativos.
# Compatível com Bash 3.2 (macOS) e Linux. No Windows, use Git Bash
# ou WSL; para espaço livre puro no PowerShell: Get-PSDrive.
#
# Uso:
#   ./scripts/storage-audit.sh [caminho-do-repositório]
#   DEV_STORAGE_OK_GIB=25 ./scripts/storage-audit.sh .
#
# Variáveis (GiB, inteiros):
#   DEV_STORAGE_OK_GIB    desejado   (padrão 20)
#   DEV_STORAGE_WARN_GIB  atenção    (padrão 10)
#   DEV_STORAGE_CRIT_GIB  crítico    (padrão = WARN)
# =====================================================================
set -eu
set -o pipefail

OK_GIB="${DEV_STORAGE_OK_GIB:-20}"
WARN_GIB="${DEV_STORAGE_WARN_GIB:-10}"
CRIT_GIB="${DEV_STORAGE_CRIT_GIB:-$WARN_GIB}"

usage() {
  cat <<'EOF'
storage-audit.sh — diagnóstico somente leitura (disco + worktrees)

  ./scripts/storage-audit.sh [caminho-do-repositório]

Não exclui nada. Inventaria espaço livre, limites configurados e
worktrees do repositório informado (ou do diretório atual).

Variáveis: DEV_STORAGE_OK_GIB, DEV_STORAGE_WARN_GIB, DEV_STORAGE_CRIT_GIB
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

TARGET="${1:-.}"
if [ ! -d "$TARGET" ]; then
  echo "caminho inexistente: $TARGET" >&2
  exit 2
fi
TARGET=$(cd -P "$TARGET" && pwd)

# --- espaço livre ----------------------------------------------------
_free_gib_posix() {
  local path="$1"
  # Preferir blocos de 1G quando disponíveis (df -g no BSD/macOS).
  if df -g "$path" >/dev/null 2>&1; then
    df -g "$path" 2>/dev/null | awk 'NR==2 {print $4; exit}'
    return 0
  fi
  # Linux: df -BG
  if df -BG "$path" >/dev/null 2>&1; then
    df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4; exit}'
    return 0
  fi
  # Fallback: 1K-blocks → GiB
  df -k "$path" 2>/dev/null | awk 'NR==2 {printf "%d\n", int($4/1048576); exit}'
}

FREE_GIB=$(_free_gib_posix "$TARGET")
FREE_GIB=${FREE_GIB:-0}

_status_for() {
  local free="$1"
  if [ "$free" -lt "$CRIT_GIB" ]; then
    echo "CRITICO"
  elif [ "$free" -lt "$OK_GIB" ]; then
    echo "ATENCAO"
  else
    echo "NORMAL"
  fi
}

STATUS=$(_status_for "$FREE_GIB")

echo "=== Armazenamento ==="
echo "caminho=$TARGET"
echo "livre_GiB=$FREE_GIB"
echo "ok_GiB=$OK_GIB warn_GiB=$WARN_GIB crit_GiB=$CRIT_GIB"
echo "estado=$STATUS"
if [ -n "${DEV_SCRATCH_DIR:-}" ]; then
  if [ -d "$DEV_SCRATCH_DIR" ] && [ -w "$DEV_SCRATCH_DIR" ]; then
    echo "DEV_SCRATCH_DIR=$DEV_SCRATCH_DIR (ok)"
  else
    echo "DEV_SCRATCH_DIR=$DEV_SCRATCH_DIR (ausente ou sem escrita)"
  fi
else
  echo "DEV_SCRATCH_DIR=(nao definida)"
fi

case "$STATUS" in
  CRITICO)
    echo "acao=suspender operacoes volumosas e solicitar autorizacao"
    ;;
  ATENCAO)
    echo "acao=alertar antes de builds grandes ou novos worktrees"
    ;;
  NORMAL)
    echo "acao=operacao permitida"
    ;;
esac

# --- worktrees -------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "git ausente; inventário de worktrees ignorado" >&2
  exit 0
fi

if ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "=== Worktrees ==="
  echo "nao_e_repositorio_git=1"
  exit 0
fi

COMMON=$(git -C "$TARGET" rev-parse --git-common-dir 2>/dev/null)
COMMON=$(cd -P "$TARGET" && cd -P "$COMMON" && pwd)

echo "=== Worktrees ==="
echo "git_common_dir=$COMMON"

# Contadores para o resumo
WT_TOTAL=0
WT_DIRTY=0
WT_AHEAD=0
WT_REVIEW=0

_emit_wt() {
  local path="$1" head="$2" branch="$3" bare="$4" locked="$5"
  WT_TOTAL=$((WT_TOTAL + 1))
  echo "---"
  echo "path=$path"
  [ -n "$head" ] && echo "HEAD=$head"
  [ -n "$branch" ] && echo "branch=$branch"
  [ "$bare" = "1" ] && echo "bare=1"
  [ -n "$locked" ] && echo "locked=$locked"

  local dirty=0 ahead="?" review=0 uniq="?"
  if [ -d "$path" ] && [ "$bare" != "1" ]; then
    if [ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -c 1)" ]; then
      dirty=1
      WT_DIRTY=$((WT_DIRTY + 1))
      review=1
    fi
    echo "dirty=$dirty"
    if git -C "$path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      ahead=$(git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')
      echo "ahead_of_upstream=$ahead"
      if [ "$ahead" != '?' ] && [ "$ahead" -gt 0 ] 2>/dev/null; then
        WT_AHEAD=$((WT_AHEAD + 1))
        review=1
      fi
    else
      echo "upstream=(nenhum)"
      # Sem upstream: revisar antes de descartar (pode ser branch só local).
      review=1
    fi
    # Contagem vs origin/HEAD é informativa: squash/rebase gera "únicos"
    # sem significar trabalho não publicado.
    if [ -n "$head" ]; then
      local main_ref
      main_ref=$(git -C "$path" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
      if [ -n "$main_ref" ]; then
        uniq=$(git -C "$path" rev-list --count "$main_ref..$head" 2>/dev/null || echo '?')
        echo "unique_vs_origin_HEAD=$uniq"
        if [ "$uniq" != '?' ] && [ "$uniq" -gt 0 ] 2>/dev/null; then
          echo "unique_note=pode_ser_squash_ou_commits_exclusivos"
        fi
      fi
    fi
  else
    echo "dirty=(indisponivel)"
    review=1
  fi

  if [ "$review" = "1" ]; then
    echo "classificacao_sugerida=revisao_humana"
    WT_REVIEW=$((WT_REVIEW + 1))
  else
    echo "classificacao_sugerida=verificar_reutilizacao"
  fi
  echo "nota=candidato_a_remocao_somente_apos_revisao_humana"
}

# Parser porcelain
path="" head="" branch="" bare=0 locked=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    worktree\ *)
      if [ -n "$path" ]; then
        _emit_wt "$path" "$head" "$branch" "$bare" "$locked"
      fi
      path=${line#worktree }
      head=""; branch=""; bare=0; locked=""
      ;;
    HEAD\ *) head=${line#HEAD } ;;
    branch\ *) branch=${line#branch } ;;
    bare) bare=1 ;;
    locked*) locked=${line#locked } ;;
    "")
      if [ -n "$path" ]; then
        _emit_wt "$path" "$head" "$branch" "$bare" "$locked"
        path=""; head=""; branch=""; bare=0; locked=""
      fi
      ;;
  esac
done <<EOF
$(git -C "$TARGET" worktree list --porcelain)
EOF
if [ -n "$path" ]; then
  _emit_wt "$path" "$head" "$branch" "$bare" "$locked"
fi

echo "=== Resumo ==="
echo "worktrees=$WT_TOTAL dirty=$WT_DIRTY ahead_local=$WT_AHEAD revisao_humana=$WT_REVIEW"
echo "somente_leitura=1"
exit 0
