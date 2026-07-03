# 🚀 Jean Dev Environment

Fonte única de verdade para todo o ambiente de desenvolvimento de IA e
automações (Claude Code, Cursor, BMAD, MCP e o que vier depois).

O conteúdo real mora **fora** dos repositórios de cliente. Cada projeto
recebe apenas **symlinks**. Assim um `git clean -fdx` nunca mais apaga
configuração — ele remove o link, o conteúdo continua intacto no
`dev-env`, e um único comando recria tudo.

---

## 🧭 Visão geral da arquitetura

```
~/Developer/
├── Projects/
│   └── <cliente>/
│       ├── .claude   ─┐
│       ├── .agents    │  (symlinks — ignorados pelo git,
│       ├── .cursor    │   recriáveis a qualquer momento)
│       ├── _bmad      │
│       └── .mcp.json ─┘
│
└── dev-env  ──►  Projects/jean-dev-environment   (symlink mestre estável)
```

- **`~/Developer/dev-env`** é um symlink mestre para este repositório.
  É o caminho estável que todos os projetos referenciam.
- **`ai/shared/`** guarda o conteúdo compartilhado entre projetos.
- **`ai/profiles/`** guarda variações por perfil.
- Um **manifesto declarativo** (`manifest/links.yaml`) descreve quais
  links cada projeto recebe.
- Um **CLI** (`dev-env`) cria, migra, valida, audita e repara tudo de
  forma idempotente.

---

## 📂 Estrutura de diretórios

```
jean-dev-environment/            (= ~/Developer/dev-env)
├── bin/dev-env                  # CLI
├── manifest/links.yaml          # manifesto declarativo dos symlinks
├── ai/
│   ├── shared/                  # fonte da verdade compartilhada
│   │   ├── .agents  .claude  .cursor  _bmad
│   │   ├── mcp/                 # perfis de MCP (ex.: swift.json)
│   │   ├── prompts  snippets  templates
│   │   └── knowledge  docs
│   └── profiles/                # overrides por perfil (futuro)
├── bootstrap/                   # implementação do CLI (comandos + libs)
├── scripts/mac-dev-setup.sh     # setup de máquina (zsh) — ver no fim
├── state/                       # registro dos projetos (por máquina)
└── backups/                     # backups timestamped (por máquina)
```

---

## 📦 Como instalar (`init`)

```bash
git clone <repo> ~/Developer/Projects/jean-dev-environment
cd ~/Developer/Projects/jean-dev-environment
./bin/dev-env init
```

O `init` é idempotente e faz:

1. cria o symlink mestre `~/Developer/dev-env` → este repo;
2. garante a estrutura `ai/shared/`;
3. valida o manifesto;
4. configura o git ignore global (`~/.config/git/ignore`);
5. adiciona `dev-env/bin` ao `PATH` (bloco delimitado no `~/.zshrc`).

Abra um novo shell e o comando `dev-env` fica disponível de qualquer
lugar.

---

## ➕ Como adicionar um projeto (`project`)

Cria/repara os symlinks de um projeto conforme o perfil.

```bash
dev-env project ~/Developer/Projects/meu-app
dev-env project ~/Developer/Projects/meu-app --profile swift
dev-env project ~/Developer/Projects/meu-app --dry-run    # só mostra
```

- Se o link já estiver correto → não faz nada.
- Se estiver quebrado ou apontando errado → recria.
- Se houver **dado real** no lugar → faz backup antes (política
  `conflict` do manifesto) e então cria o link.
- Escreve as entradas em `.git/info/exclude` (o `.gitignore` do cliente
  não é tocado) e registra o projeto.

---

## 📥 Como migrar um projeto existente (`migrate`)

Quando o projeto **já tem** `.claude/.cursor/...` reais e você quer movê-los
para o `dev-env` e substituí-los por links:

```bash
dev-env migrate ~/Developer/Projects/legado
dev-env migrate ~/Developer/Projects/legado --dry-run
```

Para cada item com dado real:

- **backup** (cópia fiel, preserva permissões/timestamps/xattrs) →
- **move** para `ai/shared` (só se o destino central estiver vazio) →
- **cria o symlink** apontando para o `dev-env`.

Se o destino central **já tiver conteúdo**, é um **conflito**: o comando
**para imediatamente**, não sobrescreve e não faz merge. Resolva à mão e
rode de novo. O projeto só entra no registro quando a migração termina
100%.

---

## ✅ Como validar (`validate`)

Smoke tests focados: as ferramentas achariam a config?

```bash
dev-env validate ~/Developer/Projects/meu-app
dev-env validate ~/Developer/Projects/meu-app --profile swift
```

Checa: todos os links resolvem, Claude acha `.claude`, Cursor acha
`.cursor`, MCP `.mcp.json` é JSON válido. Sai com código ≠ 0 se algo
falhar.

---

## 🩺 Como auditar (`doctor`)

Auditoria ampla, read-only.

```bash
dev-env doctor                       # só o ambiente
dev-env doctor ~/Developer/Projects/meu-app
dev-env doctor --all                 # todos os projetos registrados
```

Verifica symlink mestre, estrutura `ai/shared`, manifesto, e por projeto:
links quebrados/ausentes/apontando errado, permissões, `info/exclude`,
Claude/Cursor/MCP. `--all` usa automaticamente o **perfil registrado de
cada projeto**. Sai com código ≠ 0 se houver falha (CI-friendly).

---

## 🆕 Fluxo recomendado para projeto novo

```bash
# 1. (uma vez por máquina) preparar o ambiente
dev-env init

# 2. clonar o projeto do cliente
git clone <cliente> ~/Developer/Projects/novo

# 3. criar os links (escolha o perfil se precisar)
dev-env project ~/Developer/Projects/novo --profile swift

# 4. conferir
dev-env validate ~/Developer/Projects/novo
```

---

## ♻️ Recuperação após `git clean -fdx`

O `git clean -fdx` remove os symlinks do projeto — mas **o conteúdo real
continua salvo** em `ai/shared`. Para recriar tudo:

```bash
dev-env project ~/Developer/Projects/meu-app
# ou, para todos de uma vez:
dev-env doctor --all        # mostra o que quebrou
# depois rode project em cada um que precisar
```

Nada é perdido. Os links voltam em segundos.

---

## 📜 Explicação do `manifest/links.yaml`

O manifesto declara os links. Sem comandos hardcoded.

```yaml
version: 1

defaults:
  required: true        # source ausente: falha (true) ou pula (false)
  conflict: backup      # target com dado real: backup | skip | fail

profiles:
  default:
    profileVersion: 1
    links:
      - source: ai/shared/.claude
        target: .claude
      - source: ai/shared/.agents
        target: .agents
      - source: ai/shared/.cursor
        target: .cursor
      - source: ai/shared/_bmad
        target: _bmad

  swift:
    extends: default            # herda os links do default
    profileVersion: 1
    links:
      - source: ai/shared/mcp/swift.json
        target: .mcp.json
        required: false
```

- `source` é relativo à raiz do `dev-env`; `target` é relativo à raiz do
  projeto.
- `required`/`conflict` têm padrão em `defaults` e podem ser
  sobrescritos por link.
- Regras do formato: indentação de 2 espaços, sem tabs, sem arrays
  inline, sem âncoras. Quebrou a regra → o parser falha alto (não
  adivinha).

---

## 🎛️ Perfis (`default`, `swift`)

- **`default`** — o conjunto compartilhado por todo projeto (`.claude`,
  `.agents`, `.cursor`, `_bmad`).
- **`swift`** — `extends: default` e acrescenta o `.mcp.json` do perfil
  Swift.

Novo perfil = novas linhas no manifesto (com `extends` quando fizer
sentido). O perfil usado por cada projeto fica gravado no registro, então
`doctor --all` aplica o perfil certo automaticamente.

---

## 🔒 Garantias do sistema

- **Idempotente** — rodar 2× dá o mesmo resultado; nada é recriado ou
  duplicado à toa.
- **Backups automáticos** — timestamped em `backups/<data>/`, nunca
  sobrescrevem, nunca reutilizam pasta, nunca apagam.
- **Nunca sobrescreve `ai/shared`** — migração só ocupa destino central
  vazio; `.gitkeep` conta como vazio (placeholder).
- **Nunca faz merge automático** — conflito de migração para na hora e
  reporta.
- **`--dry-run` disponível** — em toda operação mutável; mostra
  exatamente o que aconteceria, sem tocar em nada.

---

## 🛠️ Troubleshooting

**Link quebrado / apontando errado**
```bash
dev-env doctor ~/Developer/Projects/meu-app   # diagnostica
dev-env project ~/Developer/Projects/meu-app  # recria/repara
```

**Conflito de migração** (`CONFLICT: central already has content`)
O `ai/shared/<x>` já tem conteúdo diferente. Não há merge automático.
Compare os dois, decida qual mantém, ajuste à mão e rode `migrate` de
novo. O backup do projeto está em `backups/<data>/`.

**Comando `dev-env` não encontrado (PATH)**
Rode `dev-env init` e abra um novo shell. O `init` adiciona um bloco
delimitado (`# >>> dev-env >>>`) ao `~/.zshrc`. Confira se existe.

**Manifesto inválido**
```bash
dev-env doctor        # aponta "manifest invalid"
```
Cheque `manifest/links.yaml`: indentação de 2 espaços, sem tabs, só as
chaves conhecidas. O parser indica a linha do problema.

---

## 🖥️ Setup de máquina (zsh) — opcional

O `scripts/mac-dev-setup.sh` continua disponível para preparar o shell
(Powerlevel10k, autosuggestions, syntax highlight, fzf). É independente
do `dev-env` e roda uma vez por máquina.

```bash
./scripts/mac-dev-setup.sh
```

**Setup as code > Manual setup.**
