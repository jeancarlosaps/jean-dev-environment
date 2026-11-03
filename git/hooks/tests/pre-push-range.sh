#!/bin/bash
# Harness do AI Guard. Não faz push: alimenta pre-push e commit-msg com
# stdin e arquivo de mensagem. A política de coautoria e de menção a IA
# permanece; o que muda é o conjunto de commits julgados.
set -eu
set -o pipefail

HOOK_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
PRE_PUSH="$HOOK_DIR/pre-push"
COMMIT_MSG="$HOOK_DIR/commit-msg"
ZERO=0000000000000000000000000000000000000000
unset AI_GUARD_MAINTENANCE || true

if [ ! -x "$PRE_PUSH" ] || [ ! -x "$COMMIT_MSG" ]; then
  echo "hooks ausentes ou sem permissão de execução" >&2
  exit 1
fi

failures=0
assert_status() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FALHOU $label: status $actual, esperado $expected" >&2
    echo "$pre_err" >&2
    failures=$((failures + 1))
  else
    echo "ok $label"
  fi
}

assert_contains() {
  local label="$1" needle="$2"
  if ! printf '%s\n' "$pre_err" | grep -q "$needle"; then
    echo "FALHOU $label: não encontrou [$needle]" >&2
    echo "$pre_err" >&2
    failures=$((failures + 1))
  fi
}

assert_lacks() {
  local label="$1" needle="$2"
  if printf '%s\n' "$pre_err" | grep -q "$needle"; then
    echo "FALHOU $label: não deveria conter [$needle]" >&2
    echo "$pre_err" >&2
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/ai-guard-test.XXXXXX")
empty_hooks="$work/empty-hooks"
repo="$work/repo"
mkdir -p "$empty_hooks"
trap 'rm -rf "$work"' EXIT

git init -q "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main
git -C "$repo" config user.name "Tester"
git -C "$repo" config user.email "tester@example.com"
git -C "$repo" config commit.gpgsign false

commit_file() {
  local path="$1" content="$2" message_file="$3"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" -c core.hooksPath="$empty_hooks" commit -q -F "$message_file"
}

msg() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
}

base_msg="$work/base.txt"
published_msg="$work/published.txt"
valid_msg="$work/valid.txt"
ai_msg="$work/ai.txt"
human_msg="$work/human.txt"
msg "$base_msg" "feat: base"
msg "$published_msg" "feat: historico publicado" "" "Co-authored-by: João Ramos <jvd.ramos@hotmail.com>"
msg "$valid_msg" "feat: ajuste valido"
msg "$ai_msg" "feat: mencao proibida" "" "Texto gerado por ia."
msg "$human_msg" "feat: coautoria nova" "" "Co-authored-by: João Ramos <jvd.ramos@hotmail.com>"

commit_file a.txt base "$base_msg"
A=$(git -C "$repo" rev-parse HEAD)
commit_file b.txt publicado "$published_msg"
B=$(git -C "$repo" rev-parse HEAD)
commit_file c.txt valido "$valid_msg"
C=$(git -C "$repo" rev-parse HEAD)
commit_file d.txt proibido "$ai_msg"
D=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" branch feature "$C"
git -C "$repo" checkout -q feature
commit_file e.txt coautor "$human_msg"
E=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main

pre_err=""
run_pre_push() {
  local input="$1"
  set +e
  pre_err=$(printf '%s\n' "$input" | (cd "$repo" && "$PRE_PUSH" origin "file://$work/nowhere") 2>&1)
  pre_status=$?
  set -e
}

# 1. Commits novos válidos sobre histórico que já contém coautoria publicada.
git -C "$repo" update-ref refs/remotes/origin/main "$B"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run_pre_push "refs/heads/main $C refs/heads/main $B"
assert_status "push valido sobre coautoria publicada" 0 "$pre_status"
assert_lacks "push valido nao cita o commit publicado" "historico publicado"

# 2. Commit novo que viola regra legítima continua bloqueado.
run_pre_push "refs/heads/main $D refs/heads/main $B"
assert_status "commit novo com mencao proibida" 1 "$pre_status"
assert_contains "mencao proibida aparece" "mencao proibida"
assert_contains "motivo e mencao a IA" "menção a IA"
assert_lacks "coautoria publicada nao entra na lista" "historico publicado"

# 3. Branch nova: só o que ainda não está em nenhum remoto.
git -C "$repo" update-ref refs/remotes/origin/main "$C"
run_pre_push "refs/heads/feature $C refs/heads/feature $ZERO"
assert_status "branch nova sem commit inedito" 0 "$pre_status"
run_pre_push "refs/heads/main $D refs/heads/nova $ZERO"
assert_status "branch nova com commit proibido" 1 "$pre_status"
assert_contains "branch nova aponta o commit proibido" "mencao proibida"
assert_lacks "branch nova nao reabre o historico publicado" "historico publicado"

# 4. Várias refs no mesmo push: cada atualização é julgada.
git -C "$repo" update-ref refs/remotes/origin/main "$B"
git -C "$repo" update-ref -d refs/remotes/origin/feature 2>/dev/null || true
run_pre_push "refs/heads/main $D refs/heads/main $B
refs/heads/feature $E refs/heads/feature $ZERO"
assert_status "push com duas refs" 1 "$pre_status"
assert_contains "primeira ref proibida" "mencao proibida"
assert_contains "segunda ref proibida" "coautoria nova"
assert_lacks "refs multiplas nao listam o publicado" "historico publicado"

# 5. Commit antigo no histórico compartilhado não bloqueia por si só.
git -C "$repo" update-ref refs/remotes/origin/main "$C"
run_pre_push "refs/heads/feature $C refs/heads/feature $A"
assert_status "feature atrasada que incorpora o historico" 0 "$pre_status"

# A ref de rastreio da própria branch, mesmo adiantada, não absolve commit novo.
git -C "$repo" update-ref refs/remotes/origin/feature "$D"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feature
run_pre_push "refs/heads/feature $D refs/heads/feature $C"
assert_status "rastreio local adiantado nao libera commit novo" 1 "$pre_status"
assert_contains "commit novo continua visivel" "mencao proibida"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$repo" update-ref -d refs/remotes/origin/feature

# 6. Objeto remoto ausente falha fechado.
run_pre_push "refs/heads/main $C refs/heads/main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_status "objeto remoto ausente" 1 "$pre_status"
assert_contains "mensagem de estado inconsistente" "estado inconsistente"

# 7. Coautoria humana legítima não é classificada como ferramenta.
#    A política continua bloqueando Co-Authored-By em commit novo.
#    O mesmo trailer, já publicado, não bloqueia outro push.
git -C "$repo" update-ref refs/remotes/origin/main "$B"
run_pre_push "refs/heads/feature $E refs/heads/feature $C"
assert_status "coautoria humana nova bloqueada pela politica" 1 "$pre_status"
assert_contains "motivo de coautoria" "coautoria"
assert_lacks "coautoria humana nao vira mencao a IA" "menção a IA"
assert_lacks "nao aponta o trailer publicado" "historico publicado"

# Tag com o mesmo nome de uma branch não dispensa o rastreio dessa branch.
git -C "$repo" update-ref refs/remotes/origin/main "$B"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$repo" update-ref refs/tags/main "$B"
run_pre_push "refs/tags/main $B refs/tags/main $ZERO"
assert_status "tag com o mesmo nome da branch publicada" 0 "$pre_status"
assert_lacks "tag nao reabre o historico publicado" "historico publicado"
run_pre_push "refs/tags/alerta $D refs/tags/alerta $ZERO"
assert_status "tag nova com commit proibido" 1 "$pre_status"
assert_contains "tag nova aponta a mencao proibida" "mencao proibida"
assert_lacks "tag nova nao lista o historico publicado" "historico publicado"

# Refspec de fetch fora do mapeamento convencional.
git -C "$repo" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/tracked/*'
git -C "$repo" update-ref refs/remotes/origin/tracked/feature "$D"
git -C "$repo" update-ref refs/remotes/origin/feature "$C"
run_pre_push "refs/heads/feature $D refs/heads/feature $C"
assert_status "refspec personalizado nao esconde commit novo" 1 "$pre_status"
assert_contains "refspec personalizado mostra a mencao" "mencao proibida"
git -C "$repo" update-ref refs/remotes/origin/tracked/main "$B"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/tracked/main
git -C "$repo" update-ref -d refs/remotes/origin/main
git -C "$repo" update-ref -d refs/remotes/origin/feature
git -C "$repo" update-ref refs/remotes/origin/tracked/feature "$A"
run_pre_push "refs/heads/feature $C refs/heads/feature $A"
assert_status "refspec personalizado preserva historico publicado" 0 "$pre_status"
assert_lacks "refspec personalizado nao lista o publicado" "historico publicado"
git -C "$repo" config remote.origin.fetch 'refs/heads/*'
run_pre_push "refs/heads/feature $C refs/heads/feature $A"
assert_status "refspec sem destino falha fechado" 1 "$pre_status"
assert_contains "refspec invalido explica a falha" "estado inconsistente"
git -C "$repo" config --unset remote.origin.fetch
git -C "$repo" update-ref -d refs/remotes/origin/tracked/feature
git -C "$repo" update-ref -d refs/remotes/origin/tracked/main
git -C "$repo" update-ref -d refs/remotes/origin/feature
git -C "$repo" update-ref refs/remotes/origin/main "$B"

cd "$repo"
clean="$work/clean-msg.txt"
msg "$clean" "feat: mensagem nova sem trailer"
set +e
pre_err=$("$COMMIT_MSG" "$clean" 2>&1)
pre_status=$?
set -e
assert_status "commit-msg ignora trailer do ancestral" 0 "$pre_status"

inherited="$work/inherited-msg.txt"
msg "$inherited" "feat: copia o trailer" "" "Co-authored-by: João Ramos <jvd.ramos@hotmail.com>"
set +e
pre_err=$("$COMMIT_MSG" "$inherited" 2>&1)
pre_status=$?
set -e
assert_status "commit-msg bloqueia trailer na mensagem nova" 1 "$pre_status"
assert_contains "titulo de coautoria" "coautoria não permitida"
assert_lacks "titulo nao acusa ferramenta" "referência a ferramenta de IA"
if ! grep -q "Co-authored-by" "$inherited"; then
  echo "FALHOU coautoria humana foi apagada como trailer de IA" >&2
  failures=$((failures + 1))
else
  echo "ok coautoria humana nao e removida pelo strip"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures falha(s)" >&2
  exit 1
fi
echo "todos os cenarios passaram"
