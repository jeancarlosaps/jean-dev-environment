# Regras de trabalho — ambiente Jean (todas as ferramentas de IA)

Fonte única de verdade: `~/Developer/dev-env` (jean-dev-environment).
Estas regras valem para **qualquer repositório desta máquina** (Raio,
Compass/Natura, Bradesco, pessoais e futuros clientes) e para qualquer
agente (Claude Code, Cursor, ChatGPT, outros).

## POLÍTICA GLOBAL — invisibilidade total de IA no Git/GitHub

> **Todo commit, PR e histórico Git devem parecer indistinguíveis de
> um trabalho realizado manualmente pelo desenvolvedor.**

Nenhuma ferramenta pode deixar QUALQUER evidência de participação no
Git ou no GitHub. Vale para: commits, pushes, pull requests,
histórico, autoria, trailers, bots, GitHub Apps, mensagens,
descrições, comentários automáticos.

- Aplica-se a **todos** os repositórios: corporativos E pessoais.
- Vale para ferramentas atuais e **futuras**: Claude, Cursor, ChatGPT,
  Copilot, OpenAI, Anthropic, Gemini, Codeium, Continue, Cline,
  Roo Code, Windsurf, DeepSeek, Qwen, Codex e similares.
- Única exceção: **pedido explícito do Jean** naquele momento.
  Na ausência dessa autorização, o comportamento padrão é **bloquear**.

### Identidade Git

- Toda operação Git usa **exclusivamente a identidade Git configurada
  do Jean** (`git config user.name` / `user.email` do repositório).
- Nunca alterar `author`, `committer` ou qualquer identidade Git.
- Nunca produzir múltiplos autores: nenhum `Co-Authored-By`, nenhum
  bot, nenhuma GitHub App, nenhuma coautoria automática. O caso
  "@usuario and @claude committed" no GitHub nunca pode acontecer.
- Nunca instalar/autorizar GitHub Apps de IA (Claude App, Copilot
  agents etc.) em repositórios; elas comentam e commitam com a própria
  identidade — proibido.

## Artefatos de IA — nunca versionar (qualquer repositório)

Nenhum artefato relacionado a IA pode ser versionado, em cliente OU
projeto pessoal. Tudo permanece exclusivamente local. Inclui:

- `.claude/`, `CLAUDE.md`, `AGENTS.md`, `.cursor/`, `.cursorrules`,
  `.agents/`, `_bmad/`, `.mcp.json`, `GEMINI.md`, regras de
  Cline/Roo/Windsurf/Continue e equivalentes
- arquivos de IA do GitHub: `.github/copilot*`,
  `.github/instructions*`, `.github/prompts/`, `.github/chatmodes/`
- prompts, memories, caches, configs, sessões
- arquivos temporários, diagnósticos e logs de ferramenta

Exclusões vão em `.git/info/exclude`, nunca no `.gitignore` do
projeto. Nada de regras duplicadas por projeto: sempre referenciar o
dev-env.

Exceções: somente repositórios **explicitamente autorizados pelo
Jean** a versionar artefatos de IA, marcados repo a repo com
`git config ai-guard.allowArtifacts true` (config local, nunca
versionada — o jean-dev-environment recebe essa marca via
`dev-env init`). Sem a marca, o bloqueio é o default.

### Modo manutenção (`AI_GUARD_MAINTENANCE=1`)

Existe **apenas** para manutenção consciente do próprio ambiente
(dev-env, hooks, migrações). Nunca usar em trabalho normal, nunca em
repositório de cliente ou pessoal, nunca deixar exportado no shell.
Todo uso imprime aviso ruidoso — se o aviso aparecer fora de uma
manutenção deliberada, algo está errado: interrompa e limpe a
variável.

## Fluxo obrigatório antes de QUALQUER operação Git

Validar sempre, nesta ordem:

1. `git status` (working tree completo)
2. branch atual e sua base
3. remote e upstream
4. arquivos staged / modificados / untracked
5. arquivos fora do escopo da task
6. arquivos de IA ou temporários (não podem entrar)
7. identidade do commit: autor e email efetivos
   (`git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT`) iguais à
   configuração do Jean no repositório
8. ausência de trailers, coautores, bots e GitHub Apps

Proibido:

- `git add -A`, `git add .`, `git commit --all`
- adicionar arquivo não relacionado à tarefa
- alterar `author`, `committer` ou qualquer identidade Git

Sempre adicionar arquivos **explicitamente, um a um**.

## Commits

Padrão default:

```
<JIRA> <Tipo>: <descrição em português>
```

Exemplos:

```
JCLP-2908 Fix: reduz atualizações desnecessárias de layout na célula de variações da PDP
JCLP-2911 Fix: corrige sincronização da lista de consultoras após limpar resultados
```

Tipos: `Fix` `Feat` `Refactor` `Perf` `Docs` `Test` `Chore`

Se o repositório tiver convenção própria explícita (ex.: Conventional
Commits no Design System), a convenção do repositório prevalece — mas
as regras abaixo valem sempre:

- descrição em português
- sem emojis
- sem trailers automáticos
- sem `Co-Authored-By`, sem `Generated-By`
- **nenhuma menção a ferramenta de IA**

## Pull Requests

- Conteúdo exclusivamente técnico, em português.
- Nunca mencionar: Claude, Cursor, ChatGPT, OpenAI, Anthropic,
  Copilot, IA, AI, Generated, Assisted, "Powered by".
- Mesma proibição em changelogs, documentação e release notes.

## Higiene de branch (pré-PR / pré-commit final)

1. Descobrir a branch principal: `git remote show origin | grep "HEAD branch"`.
2. Verificar base real: `git merge-base HEAD origin/<BASE>` +
   `git log --oneline --graph origin/<BASE>...HEAD`.
3. Se houver commits herdados de outra feature branch, isolar com
   `git rebase --onto origin/<BASE> <primeiro-fora-do-escopo>^ HEAD`.
4. Antes do push: `git diff --name-only origin/<BASE>...HEAD` e
   confirmar que só há arquivos do escopo.

## Workflow de implementação (Design System e similares)

1. **Analisar primeiro**: Figma, implementação UIKit, implementação
   SwiftUI, arquitetura existente, componentes relacionados.
2. **Identificar reutilização antes de criar código.** Nunca duplicar
   algoritmos; reusar infraestrutura existente.
3. **Manter UIKit e SwiftUI alinhados arquiteturalmente.**
4. **Separar responsabilidades**: o componente consumidor faz apenas o
   "de → para"; toda lógica compartilhada mora no componente
   reutilizável.
5. **Preservar APIs públicas**; evitar breaking changes.
6. **Testes**: atualizar existentes e criar novos quando necessário.
   Nenhuma feature está pronta sem testes passando.
7. **Sample**: demonstrar dentro da página existente do componente;
   nunca criar página paralela.
8. **Validar antes de Git**: build + testes + validação manual antes
   de qualquer commit ou PR.
