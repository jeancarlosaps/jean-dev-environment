#!/bin/bash
# Harness do AI Guard. Não envia nada ao GitHub. O servidor é um bare local:
# o hook recebe a URL dele e o stdin. A política de coautoria e de menção a IA
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
bare="$work/server.git"
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
git init --bare -q "$bare"
ln -s "$bare" "$work/push-b.git"

publish() {
  git -c core.hooksPath="$empty_hooks" --git-dir="$bare" fetch -q "$repo" "+${1}:${2}"
}

reset_server() {
  git --git-dir="$bare" for-each-ref --format='delete %(refname)' refs | git --git-dir="$bare" update-ref --stdin
}

clear_local() {
  git -C "$repo" for-each-ref --format='delete %(refname)' refs/remotes refs/tags refs/cache | git -C "$repo" update-ref --stdin
  git -C "$repo" config --unset-all remote.origin.fetch 2>/dev/null || true
  git -C "$repo" config --unset-all remote.origin.url 2>/dev/null || true
  git -C "$repo" config --unset-all remote.backup.url 2>/dev/null || true
}

run_pre_push() {
  local input="$1" url="${2:-$bare}" remote_name="${3:-origin}"
  set +e
  pre_err=$(printf '%s\n' "$input" | (cd "$repo" && "$PRE_PUSH" "$remote_name" "$url") 2>&1)
  pre_status=$?
  set -e
}

# 1. Commit publicado no servidor, em outra branch, não é reavaliado.
clear_local
reset_server
publish "$B" refs/heads/dev
publish "$A" refs/heads/main
run_pre_push "refs/heads/main $C refs/heads/main $A"
assert_status "historico publicado em outra branch do servidor" 0 "$pre_status"
assert_lacks "nao reavalia o commit publicado" "historico publicado"

# 2. Commit novo proibido continua bloqueado.
run_pre_push "refs/heads/main $D refs/heads/main $A"
assert_status "commit novo com mencao proibida" 1 "$pre_status"
assert_contains "mencao proibida aparece" "mencao proibida"
assert_lacks "publicado nao entra na lista" "historico publicado"

# 3. Branch nova.
publish "$C" refs/heads/main
run_pre_push "refs/heads/feature $C refs/heads/feature $ZERO"
assert_status "branch nova sem commit inedito" 0 "$pre_status"
run_pre_push "refs/heads/main $D refs/heads/nova $ZERO"
assert_status "branch nova com commit proibido" 1 "$pre_status"
assert_contains "branch nova aponta o commit proibido" "mencao proibida"

# 4. Várias refs no mesmo push.
reset_server
publish "$B" refs/heads/main
run_pre_push "refs/heads/main $D refs/heads/main $B
refs/heads/feature $E refs/heads/feature $ZERO"
assert_status "push com duas refs" 1 "$pre_status"
assert_contains "primeira ref proibida" "mencao proibida"
assert_contains "segunda ref proibida" "coautoria nova"
assert_lacks "refs multiplas nao listam o publicado" "historico publicado"

# 5. Coautoria nova bloqueada; a já publicada não vira menção a IA.
publish "$C" refs/heads/main
run_pre_push "refs/heads/feature $E refs/heads/feature $C"
assert_status "coautoria humana nova bloqueada pela politica" 1 "$pre_status"
assert_contains "motivo de coautoria" "coautoria"
assert_lacks "coautoria humana nao vira mencao a IA" "menção a IA"
assert_lacks "nao aponta o trailer publicado" "historico publicado"

# 6. Ref de rastreio alheia adiantada não esconde commit ausente no servidor.
reset_server
publish "$C" refs/heads/main
git -C "$repo" update-ref refs/remotes/origin/dev "$D"
run_pre_push "refs/heads/feature $D refs/heads/feature $C"
assert_status "rastreio alheio adiantado nao libera commit novo" 1 "$pre_status"
assert_contains "rastreio alheio mostra a mencao" "mencao proibida"

# O mesmo commit, quando o servidor realmente o anuncia, não é reavaliado.
publish "$D" refs/heads/dev
run_pre_push "refs/heads/feature $D refs/heads/feature $C"
assert_status "commit anunciado pelo servidor nao e reavaliado" 0 "$pre_status"
assert_lacks "anuncio do servidor nao lista a mencao" "mencao proibida"

# 7. Rastreio da própria ref, espelho, tag local e alias também não provam publicação.
clear_local
reset_server
publish "$C" refs/heads/feature
git -C "$repo" update-ref refs/remotes/origin/feature "$D"
git -C "$repo" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/tracked/*'
git -C "$repo" update-ref refs/remotes/origin/tracked/feature "$D"
git -C "$repo" update-ref refs/cache/origin/feature "$D"
git -C "$repo" update-ref refs/tags/so-local "$D"
git -C "$repo" config remote.backup.url "$bare"
git -C "$repo" update-ref refs/remotes/backup/feature "$D"
run_pre_push "refs/heads/feature $D refs/heads/feature $C"
assert_status "refs locais nao escondem commit novo" 1 "$pre_status"
assert_contains "refs locais mostram a mencao" "mencao proibida"

# 8. Deleção não usa o rastreio adiantado da ref apagada.
clear_local
reset_server
publish "$C" refs/heads/old
git -C "$repo" update-ref refs/remotes/origin/old "$D"
run_pre_push "refs/heads/old $ZERO refs/heads/old $C
refs/heads/feature $D refs/heads/feature $A"
assert_status "delecao nao esconde commit novo" 1 "$pre_status"
assert_contains "delecao mostra a mencao" "mencao proibida"

# 9. Duas refs com rastreio local adiantado nas duas.
clear_local
reset_server
publish "$C" refs/heads/main
publish "$C" refs/heads/feature
git -C "$repo" update-ref refs/remotes/origin/main "$D"
git -C "$repo" update-ref refs/remotes/origin/feature "$D"
run_pre_push "refs/heads/main $D refs/heads/main $C
refs/heads/feature $D refs/heads/feature $C"
assert_status "push multiplo nao esconde commit novo" 1 "$pre_status"
assert_contains "push multiplo mostra a mencao" "mencao proibida"

# 10. Tag no servidor prova publicação; tag só local não.
clear_local
reset_server
publish "$A" refs/heads/main
publish "$B" refs/tags/v1
run_pre_push "refs/heads/main $C refs/heads/main $A"
assert_status "tag anunciada preserva historico" 0 "$pre_status"
assert_lacks "tag anunciada nao reabre o publicado" "historico publicado"
git -C "$repo" update-ref refs/tags/so-local "$D"
run_pre_push "refs/heads/main $D refs/heads/main $A"
assert_status "tag local nao esconde commit novo" 1 "$pre_status"
assert_contains "tag local mostra a mencao" "mencao proibida"

# 11. Outra grafia da mesma URL, caminho relativo e URL inexistente.
clear_local
reset_server
publish "$C" refs/heads/feature
git -C "$repo" update-ref refs/remotes/origin/feature "$D"
run_pre_push "refs/heads/feature $D refs/heads/feature $C" "$work/push-b.git"
assert_status "segunda URL do mesmo servidor nao esconde commit novo" 1 "$pre_status"
assert_contains "segunda URL mostra a mencao" "mencao proibida"
run_pre_push "refs/heads/feature $C refs/heads/feature $A" "../server.git"
assert_status "caminho relativo le o servidor" 0 "$pre_status"
run_pre_push "refs/heads/feature $C refs/heads/feature $A" "$work/ausente.git"
assert_status "URL sem remoto falha fechado" 1 "$pre_status"
assert_contains "URL sem remoto explica a falha" "não foi possível ler as refs do remoto"

# 12. SHA remoto inválido e objeto anunciado que não está local.
reset_server
publish "$B" refs/heads/main
run_pre_push "refs/heads/main $C refs/heads/main aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_status "objeto remoto ausente" 1 "$pre_status"
assert_contains "mensagem de estado inconsistente" "estado inconsistente"
side="$work/side"
git init -q "$side"
git -C "$side" config user.name "Tester"
git -C "$side" config user.email "tester@example.com"
git -C "$side" config commit.gpgsign false
printf '%s\n' "x" > "$side/x.txt"
git -C "$side" add x.txt
git -C "$side" -c core.hooksPath="$empty_hooks" commit -q -m "feat: so no servidor"
S=$(git -C "$side" rev-parse HEAD)
git -c core.hooksPath="$empty_hooks" --git-dir="$bare" fetch -q "$side" "+${S}:refs/heads/other"
run_pre_push "refs/heads/main $C refs/heads/main $B"
assert_status "objeto anunciado ausente falha fechado" 1 "$pre_status"
assert_contains "objeto anunciado explica a falha" "não está disponível localmente"

# 13. Ref nova com SHA de 64 zeros não é erro quando o commit já está no servidor.
reset_server
publish "$C" refs/heads/main
Z64=0000000000000000000000000000000000000000000000000000000000000000
run_pre_push "refs/heads/feature $C refs/heads/feature $Z64"
assert_status "zeros de 64 em branch nova publicada" 0 "$pre_status"

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
