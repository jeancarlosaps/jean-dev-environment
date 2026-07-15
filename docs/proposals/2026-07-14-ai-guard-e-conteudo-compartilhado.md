# Proposta — AI Guard (hooks git) + conteúdo compartilhado

Data: 2026-07-14
Status: em revisão

## Contexto

Auditoria da máquina identificou três lacunas no dev-env:

1. **Nenhuma proteção git contra referência a ferramentas de IA.**
   Assistentes de código adicionam trailers (`Co-Authored-By: Claude`,
   `Generated with ...`) e menções em mensagens de commit. Hoje nada
   impede isso de vazar para repositórios de clientes.
2. **`ai/shared/` vazio.** A estrutura existe, mas não há conteúdo:
   nenhuma regra central para Claude Code, Cursor ou outros agentes.
3. **`init` não configura hooks globais** nem detecta conflito entre
   `core.excludesfile` legado e o `~/.config/git/ignore` que ele criou.

## Proposta

### 1. `git/hooks/` — AI Guard global

Novo diretório na raiz do repo com três hooks + biblioteca comum:

```
git/hooks/
├── lib/ai-guard.sh      # padrões e funções compartilhadas
├── lib/passthrough.sh   # delegação genérica para hooks do repositório
├── prepare-commit-msg   # remove trailers de IA antes do editor
├── commit-msg           # remove trailers + bloqueia menções residuais
├── pre-push             # varre commits a enviar; bloqueia se houver IA
└── pre-commit, post-*   # symlinks -> lib/passthrough.sh
```

Como `core.hooksPath` global faz o git ignorar `.git/hooks` para
**todos** os hooks, os demais nomes padrão (pre-commit, post-commit,
post-checkout, post-merge, pre-rebase, post-rewrite, applypatch-*,
pre-merge-commit) existem como symlinks para `passthrough.sh`, que
apenas reexecuta o hook homônimo do repositório. Hooks corporativos
continuam funcionando exatamente como antes.

Ativação: `git config --global core.hooksPath ~/Developer/dev-env/git/hooks`
(passo novo do `init`).

Política que os hooks implementam (v2, 2026-07-14):

> Todo commit, PR e histórico Git devem parecer indistinguíveis de um
> trabalho realizado manualmente pelo desenvolvedor. Sem evidência de
> IA em commits, pushes, PRs, histórico, autoria, trailers, bots,
> GitHub Apps, mensagens ou comentários — em QUALQUER repositório
> (corporativo ou pessoal). Exceção única: pedido explícito.
> Default: bloquear.

Comportamento:

- **Remoção automática (silenciosa)** de trailers:
  `Co-Authored-By` de ferramentas, `Generated-By`, `Assisted-By`,
  `🤖 Generated with ...` etc.
- **Bloqueio (exit 1)** quando o corpo da mensagem ainda menciona
  ferramenta de IA (Claude, Copilot, ChatGPT, OpenAI, Anthropic,
  Codex, Gemini, "Cursor AI/agent", "gerado por IA", "AI-generated",
  "Powered by ..."). A palavra `cursor` isolada NÃO bloqueia (é termo
  legítimo de UI); só combinações claras com a ferramenta.
- **Bloqueio de coautoria (qualquer uma)**: todo `Co-Authored-By`
  restante após a limpeza bloqueia o commit e o push — coautoria gera
  "X and Y committed" no GitHub; múltiplos autores nunca por default.
- **Guarda de identidade (`pre-commit`, novo hook real)**:
  - bloqueia author/committer cujo nome/email case com ferramenta de
    IA ou bot (`claude`, `copilot`, `[bot]`, `github-actions`,
    `noreply@anthropic` etc. — lista extensível em `AI_GUARD_TOOLS`);
  - bloqueia committer diferente do `git config user.name/user.email`
    efetivo do repositório (identidades corporativas por repo
    continuam funcionando — a comparação é contra a config local);
  - author humano ≠ config é permitido (rebase/cherry-pick de commit
    de colega preserva autoria legítima), desde que não seja IA/bot.
- **Bloqueio de artefatos de IA staged (`pre-commit`)**: `.claude/`,
  `CLAUDE.md`, `AGENTS.md`, `.cursor*`, `.mcp.json`, `_bmad/`, regras
  de Cline/Roo/Windsurf/Continue, memories, caches etc. nunca entram
  em commit — em qualquer repo. Também bloqueia arquivos de IA do
  GitHub: `.github/copilot*`, `.github/instructions*`,
  `.github/prompts/`, `.github/chatmodes/`. Exceção: repositórios
  **explicitamente autorizados** via
  `git config ai-guard.allowArtifacts true` (config local por repo,
  nunca versionada; sem amarração a nome/caminho de repositório — o
  jean-dev-environment recebe a marca no `dev-env init`).
- **`pre-push` amplia a varredura**: além de mensagem/trailers, checa
  autor e committer (`%an %ae %cn %ce`) de cada commit a enviar e
  qualquer coautoria — pega histórico antigo, rebases e cherry-picks.
- **Delegação corporativa**: cada hook, ao final, executa o hook
  homônimo do repositório (`.git/hooks/<nome>`) se existir e for
  executável, preservando argumentos e stdin. Hooks corporativos nunca
  são sobrescritos — apenas encadeados.
- **Autoria intocada**: os hooks nunca alteram author/committer.
- **Modo manutenção**: `AI_GUARD_MAINTENANCE=1` pula o guard
  (delegação corporativa ainda roda). Restrito a manutenção
  consciente do próprio ambiente; todo uso imprime aviso ruidoso no
  stderr, tornando impossível um bypass acidental passar despercebido.

Limitações conhecidas:

- Se um repo corporativo definir `core.hooksPath` **local**, a config
  local vence a global e o AI Guard não roda nesse repo. O `doctor`
  passa a reportar isso.
- Filtro textual: não impede menção ofuscada intencionalmente. O
  objetivo é impedir vazamento acidental, não adversarial.
- **GitHub Apps agem no servidor**: um app instalado na org (ex.:
  Claude GitHub App, Copilot agent) comenta/commita direto no GitHub,
  fora do alcance de hooks locais. A defesa local cobre tudo que sai
  desta máquina; para apps a política central proíbe instalar ou
  autorizar qualquer app de IA nos repositórios (AGENTS.md), e o caso
  clássico "@user and @claude committed" — que nasce de
  `Co-Authored-By` no commit — fica 100% bloqueado pelos hooks.

### 2. Conteúdo do `ai/shared/`

- **`ai/shared/AGENTS.md`** — fonte única das regras de trabalho
  (fluxo git obrigatório, padrão de commit, PRs sem IA, workflow de
  componente DS). Agnóstico de ferramenta.
- **`ai/shared/.claude/CLAUDE.md`** — apenas um import
  (`@~/Developer/dev-env/ai/shared/AGENTS.md`). Na máquina,
  `~/.claude/CLAUDE.md` vira symlink para este arquivo → Claude Code
  consome as regras em qualquer repositório, sem nada versionável.
- **`ai/shared/.cursor/rules/core.mdc`** — regra mínima
  `alwaysApply: true` apontando para o AGENTS.md central.
- **`ai/shared/.cursor/rules/git-pr-branch-hygiene.mdc`** — migrada de
  `~/.cursor/rules/` (o arquivo da home passa a ser symlink na fase de
  aplicação). Zero duplicação.

### 3. Mudanças no CLI

- `init`: novo passo `_init_git_hooks` — configura
  `core.hooksPath` global apontando para `$DEV_ENV_STABLE/git/hooks`.
  Se já houver hooksPath apontando para outro lugar, **não sobrescreve**;
  avisa e falha suave (mesma filosofia do master symlink).
- `init`: novo passo `_init_git_excludes_check` — se
  `core.excludesfile` estiver definido para arquivo diferente de
  `~/.config/git/ignore`, avisa (o ignore global do git só usa o XDG
  quando `core.excludesfile` está vazio).
- `doctor`: passa a verificar hooksPath global + hooks executáveis.

### Fora do escopo (registrado para depois)

- Entrada `AGENTS.md` no manifesto (symlink na raiz dos projetos):
  desnecessária enquanto o consumo global via `~/.claude/CLAUDE.md` e
  `~/.cursor/rules` cobrir tudo.
- `dev-env version`.
- Migração do `FIGMA_ACCESS_TOKEN` para fora do `~/.zshrc`.
