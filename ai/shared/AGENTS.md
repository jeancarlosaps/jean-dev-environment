# Regras de trabalho — Jean Dev Environment (todas as ferramentas de IA)

Fonte única de verdade: `~/Developer/dev-env` (jean-dev-environment).

Estas regras se aplicam a **qualquer repositório que adote o Jean Dev
Environment** e a **qualquer agente configurado para consumi-las**.

## Independência de ferramenta

As regras deste documento descrevem **comportamento de engenharia**,
nunca preferência por uma IA específica.

Claude, Cursor, ChatGPT, Codex, Gemini, Copilot ou qualquer outro agente
— atual ou futuro — seguem exatamente as mesmas regras. Limitações
específicas de uma ferramenta são **exceções operacionais**, nunca a
regra principal.

Exemplo:

```
RUIM: "Claude deve usar X."
BOM:  "O diff deve ser revisado antes do commit."
```

Quando uma ferramenta não conseguir cumprir uma etapa, registre a
limitação explicitamente e siga o restante do fluxo. Nunca reescreva a
regra global por causa de uma única ferramenta.

## POLÍTICA GLOBAL — invisibilidade total de IA no Git/GitHub

> **Todo commit, PR e histórico Git devem parecer indistinguíveis de
> um trabalho realizado manualmente pelo desenvolvedor.**

Nenhuma ferramenta pode deixar QUALQUER evidência de participação no
Git ou no GitHub. Vale para: commits, pushes, pull requests,
histórico, autoria, trailers, bots, GitHub Apps, mensagens,
descrições, comentários automáticos.

- Aplica-se a **todos** os repositórios, corporativos e pessoais.
- Escopo: os **artefatos de trabalho** produzidos em repositórios
  consumidores. O próprio Jean Dev Environment documenta agentes,
  automação e engenharia assistida por IA — esse é o assunto do
  projeto, não evidência de participação em um trabalho de terceiro.
- Vale para ferramentas atuais e **futuras**: Claude, Cursor, ChatGPT,
  Copilot, OpenAI, Anthropic, Gemini, Codeium, Continue, Cline,
  Roo Code, Windsurf, DeepSeek, Qwen, Codex e similares.
- Única exceção: **pedido explícito do desenvolvedor** naquele momento.
  Na ausência dessa autorização, o comportamento padrão é **bloquear**.

### Identidade Git

- Toda operação Git usa **exclusivamente a identidade Git já configurada
  no repositório** (`git config user.name` / `user.email`).
- Nunca alterar `author`, `committer` ou qualquer identidade Git.
- Nunca produzir múltiplos autores: nenhum `Co-Authored-By`, nenhum
  bot, nenhuma GitHub App, nenhuma coautoria automática. O caso
  "@usuario and @agente committed" no GitHub nunca pode acontecer.
- Nunca instalar/autorizar GitHub Apps de IA em repositórios; elas
  comentam e commitam com a própria identidade — proibido.
- Respeitar a política de assinatura já existente no repositório. Não
  ligar nem desligar `commit.gpgsign` por conta própria.
- Com assinatura configurada na máquina (ex.: SSH commit signing), todo
  commit sai assinado: nunca usar `--no-gpg-sign` e nunca reescrever
  histórico publicado só para assinar retroativamente.

## Artefatos de IA — nunca versionar

Nenhum artefato relacionado a IA pode ser versionado. Tudo permanece
exclusivamente local. Inclui:

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

Exceções: somente repositórios **explicitamente autorizados**, marcados
repo a repo com `git config ai-guard.allowArtifacts true` (config local,
nunca versionada — o próprio jean-dev-environment recebe essa marca via
`dev-env init`). Sem a marca, o bloqueio é o default.

### Modo manutenção (`AI_GUARD_MAINTENANCE=1`)

Existe **apenas** para manutenção consciente do próprio ambiente
(dev-env, hooks, migrações). Nunca usar em trabalho normal, nunca em
repositório de terceiros, nunca deixar exportado no shell.
Todo uso imprime aviso ruidoso — se o aviso aparecer fora de uma
manutenção deliberada, algo está errado: interrompa e limpe a
variável.

## Fluxo de engenharia

```
Investigação
↓
Arquitetura
↓
Implementação
↓
Build
↓
Lint
↓
Testes
↓
Commit
↓
Push
↓
Pull Request
↓
CI
↓
Code Review
↓
Merge autorizado
↓
Relatório
```

Nem toda task precisa de todas as etapas, mas **nenhuma etapa aplicável
pode ser pulada silenciosamente**. Ao pular uma etapa, declare qual e
por quê.

### Estado da execução

Ao finalizar qualquer etapa, informar explicitamente:

- Código alterado?
- Build executado?
- Lint executado?
- Testes executados?
- Commit criado?
- Push realizado?
- PR criada ou atualizada?
- CI obrigatório verde (ou ausente — nunca confundir ausência com aprovação)?
- Feedback de review consultado e classificado?
- Respostas publicadas nas threads pertinentes?
- Threads resolvidas quando apropriado (e reconciliação no GitHub)?
- Status do PR: `READY`, `AWAITING_REVIEW` ou `BLOCKED`?

Nunca deixar esses estados implícitos. Push bem-sucedido **não**
encerra o PR: o ciclo de review em
`ai/shared/docs/pull-request-reviews.md` ainda é obrigatório.

### Paradas obrigatórias

Após cada grande etapa, parar e aguardar instruções: investigação
concluída, triagem concluída, arquitetura definida, implementação da
entrega concluída, testes concluídos. Nunca assumir que deve continuar
automaticamente.

## Investigação

Antes de investigar ou implementar, procure em
`ai/shared/knowledge/engineering-learnings.md` um aprendizado sobre o
mesmo componente, ferramenta ou sintoma. Reutilize-o e evolua a entrada
existente; não reinvente solução já documentada. Como usar o arquivo:
o cabeçalho dele.

Toda investigação relevante deve registrar:

- causa raiz;
- trigger (o que dispara o problema);
- hipóteses consideradas;
- hipóteses descartadas e por quê;
- experimentos realizados;
- evidências;
- impacto;
- risco;
- plano de rollback;
- lacunas (o que continua desconhecido).

### Fato, hipótese, inferência, decisão

Separar explicitamente:

| Categoria | Significado |
|---|---|
| **Fato** | Observado diretamente, com evidência reproduzível |
| **Hipótese** | Explicação plausível ainda não comprovada |
| **Inferência** | Conclusão derivada de fatos, sem observação direta |
| **Decisão** | Escolha tomada, com o motivo registrado |

**Nunca apresentar inferência como fato.**

### Workaround

Um workaround **não encerra automaticamente** uma investigação. Ele
mitiga sintoma; a causa raiz continua aberta até ser comprovada.

### Classificação obrigatória dos achados

Durante qualquer investigação, classificar cada achado como:

- Regressão introduzida pela própria mudança
- Bug funcional
- Dívida técnica existente
- Melhoria futura
- Fora do escopo

A implementação prioriza apenas regressões e bugs funcionais. O resto
permanece como follow-up registrado.

### Aprendizado permanente

Ao concluir uma investigação relevante, perguntar explicitamente:

> "Existe algum aprendizado permanente que merece entrar no ambiente?"

Se sim, registrar seguindo [Decision → Rule → Learning](#decision--rule--learning).

## Escopo e arquitetura

- Entender a arquitetura existente **antes** de alterar.
- Menor diff possível.
- Não refatorar por preferência pessoal ou estilo.
- Não ampliar escopo silenciosamente.
- Não aproveitar um bugfix para fazer limpeza paralela.
- Preservar API pública quando não houver motivo técnico para mudá-la.
- Achados fora de escopo são **registrados separadamente**, nunca
  implementados junto.
- Em dúvida arquitetural: parar, explicar, apresentar opções e aguardar
  decisão. **Nunca implementar por dedução.**

### Separação entre feature e infraestrutura

Nunca misturar correções de infraestrutura, renames, consolidações,
limpeza técnica ou migrações com uma mudança funcional. Quando
necessário: branch própria, PR própria e commits independentes — mesmo
que a infraestrutura bloqueie a feature.

### Trabalho incremental

Nunca implementar uma iniciativa inteira de uma única vez. Quebrar em
entregáveis pequenos e independentes:

```
Fase 2
- Entrega 1
- Entrega 2
- Entrega 3
- Entrega 4
```

Cada entrega é concluída antes da próxima. Iniciativa grande demais para
uma única resposta deve ser dividida, não comprimida.

### Revisão horizontal obrigatória

Sempre que modificar um componente compartilhado, verificar os
consumidores semelhantes antes de considerar a entrega pronta:

```
ComponenteBase
  ↓
VarianteA
VarianteB
VarianteC
```

Objetivo: detectar regressões e inconsistências antes do code review.

### Build e testes

Sempre validar: build do projeto, lint, testes impactados — e a **suíte
completa** quando a mudança tocar infraestrutura ou componente
compartilhado. Nenhuma entrega está pronta com build, lint ou testes
vermelhos.

### Armazenamento local e Git Worktrees

Política completa (ciclo de vida, classificação, alertas, remoção
segura e script de diagnóstico):
`ai/shared/docs/worktrees-and-storage.md`.

Evidências e particularidades do macOS/APFS:
`ai/shared/knowledge/engineering-learnings.md` ("Armazenamento local no
macOS — artefatos de build, simuladores e caches de agentes").

Vale antes de clones, instalações, builds, testes, downloads grandes,
criação de worktrees e outras operações intensivas de I/O, em qualquer
sistema operacional.

- Verificar o espaço livre do volume que vai receber os dados
  (`df -h <caminho>` / `df -g` no macOS e no Linux; `Get-PSDrive` no
  Windows). Medir o efeito de qualquer limpeza antes e depois.
- Limites personalizáveis via `DEV_STORAGE_OK_GIB` (padrão 20),
  `DEV_STORAGE_WARN_GIB` (padrão 10) e `DEV_STORAGE_CRIT_GIB` (padrão
  igual ao de atenção). Acima do desejado: operação permitida. Entre
  atenção e desejado: alertar antes de builds ou novos worktrees.
  Abaixo do crítico: suspender operações volumosas e pedir autorização.
  Não criar daemon nem limpeza automática ao cruzar os limites.
- **Uma tarefa sequencial reutiliza o checkout existente.** Worktree
  adicional só para paralelismo real ou isolamento técnico comprovado.
  Antes de criar: inventariar checkouts, alterações e processos; só
  então justificar a criação. Não criar worktree automático para review,
  continuação de PR, bugfix da mesma tarefa, testes, investigação ou
  documentação. Detalhes e ciclo de vida: o documento proprietário.
- Área de rascunho opcional: se `DEV_SCRATCH_DIR` estiver definida e o
  caminho existir e aceitar escrita, usar `$DEV_SCRATCH_DIR/<agente>/`
  para ensaios, clones descartáveis e artefatos de build, sempre por
  caminho explícito no próprio comando (`git worktree add <caminho>`,
  `-derivedDataPath`, variável de cache no comando). Sem a variável, ou
  com o volume ausente, usar os caminhos padrão das ferramentas e seguir
  a regra de espaço acima; nunca falhar por isso. Não criar uma segunda
  estratégia concorrente de armazenamento temporário.
- Não mover projetos existentes, não alterar configuração global de
  ferramentas e não mudar permissões para usar outro volume.
- Reutilizar worktrees, dependências e instalações existentes. Clone
  completo ou dependências duplicadas (ex.: `node_modules`) só com
  justificativa.
- Ao concluir a tarefa, remover os artefatos temporários criados por ela,
  por caminho exato, e citar no relatório o que foi mantido. Sem
  automação de limpeza e sem `rm -rf` genérico. Não remover worktree só
  porque o PR foi mergeado; nunca `git worktree remove --force`.
- Nunca apagar, mover ou alterar, para liberar espaço, arquivos de outro
  agente ou worktree, arquivos pessoais, caches em uso ou dados de
  simuladores e emuladores sem autorização.
- Diagnóstico somente leitura: `scripts/storage-audit.sh`
  `[caminho-do-repositório]`.

## Code review técnico

Antes de considerar a entrega pronta, revisar — quando aplicável ao
stack:

- regressão;
- crash;
- retain cycle;
- memory leak;
- race condition;
- concorrência;
- actor isolation;
- cancelamento;
- contratos;
- API pública;
- naming;
- fail-open / fail-closed;
- segurança;
- privacidade;
- logs sensíveis;
- código temporário;
- comentários temporários;
- `TODO` / `FIXME`;
- dead code.

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
   configuração do repositório
8. ausência de trailers, coautores, bots e GitHub Apps

Proibido:

- `git add -A`, `git add .`, `git commit --all`
- adicionar arquivo não relacionado à tarefa
- alterar `author`, `committer` ou qualquer identidade Git

Sempre adicionar arquivos **explicitamente, um a um**.

## Higiene de branch — pré-PR e pré-commit final

### 1. Descobrir a branch principal do projeto

Nunca assumir o nome da branch base. Descubra:

```bash
git remote show origin | grep "HEAD branch"
```

Use o resultado como `<BASE>`. Pode ser `main`, `master`, `dev`,
`develop`, `development` ou qualquer outro nome — verifique sempre.

### 2. Identificar a base real da branch

```bash
git merge-base HEAD origin/<BASE>
git log --oneline --graph origin/<BASE>...HEAD
git diff --stat origin/<BASE>...HEAD
```

### 3. Verificar a origem da branch

Confirme se a branch foi criada diretamente de `<BASE>`. Se veio de
outra feature branch, identifique quais commits pertencem ao escopo
atual e quais são herdados.

### 4. Corrigir a cadeia de commits quando necessário

```bash
git rebase --onto origin/<BASE> <primeiro-commit-fora-do-escopo>^ HEAD
```

Nunca usar `git restore` ou `git revert` para mascarar arquivos de outro
escopo — isso polui o histórico.

### 5. Validação obrigatória antes do push

```bash
git diff --name-only origin/<BASE>...HEAD
git diff --stat origin/<BASE>...HEAD
```

O resultado deve conter **somente arquivos do escopo atual**. Se
aparecer qualquer arquivo de outro componente:

1. Interrompa a execução.
2. Apresente um diagnóstico listando os arquivos fora do escopo.
3. Aguarde instrução antes de prosseguir.

### Resumo dos gates

| Gate | Comando | Critério de aprovação |
|---|---|---|
| Branch principal | `git remote show origin \| grep "HEAD branch"` | `<BASE>` detectada, nunca assumida |
| Base correta | `git merge-base HEAD origin/<BASE>` | Aponta para o HEAD de `<BASE>` |
| Histórico limpo | `git log --graph origin/<BASE>...HEAD` | Apenas commits do escopo |
| Diff de arquivos | `git diff --name-only origin/<BASE>...HEAD` | Zero arquivos fora do escopo |

## Antes do commit

Checklist:

- `git diff` revisado integralmente;
- staged contém exatamente o escopo pretendido;
- nenhum segredo, credencial ou token;
- nenhum log temporário;
- nenhum mock local;
- nenhuma instrumentação temporária;
- nenhum arquivo gerado inesperado;
- nenhum arquivo fora de escopo;
- build, lint e testes aplicáveis executados.

## Commits

**Descubra e respeite a convenção real do projeto.** Não existe padrão
universal. Antes do primeiro commit, inspecione o histórico:

```bash
git log --oneline -20
```

Exemplos de convenções reais possíveis:

```
fix: handle empty API response
```

```
PROJ-123 Fix: handle empty API response
```

Se o repositório tiver convenção explícita (Conventional Commits,
prefixo de ticket, idioma definido), ela prevalece. As regras abaixo
valem sempre, independentemente da convenção:

- sem emojis;
- sem trailers automáticos;
- sem `Co-Authored-By`, sem `Generated-By`;
- **nenhuma menção a ferramenta de IA**;
- commits pequenos e temáticos; mudanças independentes viram commits
  separados;
- sem `--amend` desnecessário e sem squash automático.

## Antes do push

Checklist:

- branch correta;
- remote correto;
- destino correto;
- commits corretos;
- working tree conhecido;
- build aplicável verde;
- lint aplicável verde;
- testes aplicáveis verdes.

### Hooks

**Nunca ignorar um hook automaticamente.** Nada de `--no-verify` por
conveniência.

Se um hook falhar: **investigar primeiro**. Bypass só com autorização
explícita e causa comprovada.

## Pull Requests

Política completa de feedback (comentários, reviews, threads inline,
resposta, resolução e reconciliação):
`ai/shared/docs/pull-request-reviews.md`.

- Descobrir e respeitar a convenção do projeto (título, idioma,
  estrutura).
- Procurar `.github/pull_request_template.md` (e variantes em
  `.github/PULL_REQUEST_TEMPLATE/`).
- Usar o template se existir.
- Se não existir, usar a estrutura padrão, sem seções vazias:
  - **O que foi feito**: resumo das principais alterações.
  - **Validação**: testes, build, lint e CI, quando aplicáveis.
  - **Observações**: só quando houver decisão, trade-off ou
    limitação relevante.

Título: seguir o padrão real do projeto, verificado no histórico de PRs.
Não impor prefixo de ticket como padrão universal.

Conteúdo exclusivamente técnico. Nunca mencionar Claude, Cursor,
ChatGPT, OpenAI, Anthropic, Copilot, Gemini, IA, AI, "Generated",
"Assisted" ou "Powered by" — a mesma proibição vale para changelogs,
documentação e release notes.

### Feedback de review (obrigatório)

Ciclo: **consultar → classificar → corrigir → validar → publicar →
responder → resolver → reconsultar**. Detalhes e distinções
(comentário geral ≠ review ≠ thread) no documento proprietário.

Antes de `READY`:

- Comentários gerais, reviews, inline e threads foram consultados
  (lista vazia de comentários gerais não basta).
- Cada apontamento foi classificado e tratado.
- Respostas foram publicadas **nas threads** com contexto técnico
  (proibido só "fixed"/"done").
- Threads resolvidas apenas quando o apontamento estiver atendido e o
  fluxo permitir; resolução confirmada de novo no GitHub.
- `MERGEABLE` não substitui aprovação; CI ausente não conta como verde;
  thread resolvida não cancela sozinha um `CHANGES_REQUESTED`.

Se o trabalho técnico e o feedback já estiverem tratados e só faltar
aprovação ou re-review humano: `AWAITING_REVIEW`. Se ainda houver
pendência acionável nossa (comentário sem tratamento, resposta não
publicada, thread bloqueante, CI obrigatório falhando ou
`CHANGES_REQUESTED` sem correção): `BLOCKED`. Nunca `READY` nesses
casos.

### Escrita

Escrever como um desenvolvedor sênior explicando a mudança para
outros desenvolvedores: português brasileiro quando o projeto não
definir outro idioma, frases simples e diretas, tom natural, sem
linguagem robótica ou corporativa.

- Título curto e descritivo.
- Curto por padrão: mudança simples cabe em 5 a 10 linhas; mudança
  complexa detalha só o necessário.
- Cobrir o que importa (objetivo, mudanças, decisões técnicas,
  testes, evidências de CI e trade-offs) sem repetir informação.
- Não narrar o processo de desenvolvimento.
- Não listar todos os arquivos modificados.
- Preferir bullets a tabelas quando bastarem.

Não pertence a descrições, comentários nem commits: problemas
particulares da máquina (espaço em disco, limpeza de caches,
ferramentas locais ausentes), caminhos absolutos do computador,
conversas ou prompts de agentes e narrativa de como a tarefa foi
executada. Exceção: detalhe local necessário para reproduzir um
problema técnico do projeto, descrito de forma genérica e sem caminhos
pessoais.

### Evidências

Evitar afirmações vazias:

```
RUIM: "Testado e funcionando."
```

Preferir evidência objetiva:

- número de testes executados e resultado;
- cobertura;
- screenshots;
- logs;
- métricas;
- benchmark;
- respostas de API;
- warnings antes/depois;
- build verde.

## GitHub CLI

Preferir `gh` para operações GitHub quando disponível.

**Regra: nunca depender do diretório atual para selecionar o
repositório.** Sempre que o comando aceitar, passe `-R`:

```bash
gh pr list -R owner/repository
gh pr view 123 -R owner/repository
gh pr checks 123 -R owner/repository
gh pr view 123 -R owner/repository --json comments,reviews,reviewDecision,headRefOid
```

Para review threads (incluindo resolvidas), use a API GraphQL
`pullRequest.reviewThreads` — não confie só em comentários gerais.
Responder e resolver: `gh api graphql` (`addPullRequestReviewComment` /
`resolveReviewThread`) ou a UI. Se a escrita falhar, registre a
limitação; não marque a thread como tratada. Detalhes:
`ai/shared/docs/pull-request-reviews.md`.

Motivação: o `gh` infere o repositório pelo `cwd`; em tarefas
multi-repositório isso pode executar no repositório errado.

## Multi-repositório

Tratar cada repositório de forma independente. Para cada um:

1. confirmar path;
2. confirmar remote;
3. confirmar branch base;
4. confirmar working tree;
5. atualizar a base;
6. criar branch;
7. implementar;
8. validar;
9. commit;
10. push;
11. PR.

Nunca assumir que todos usam a mesma branch base (`main`, `master`,
`dev`), o mesmo Makefile, o mesmo lint, o mesmo CI ou o mesmo template
de PR.

**Nunca confiar no último `cd`.** Confirme o repositório em cada
operação.

## Ações que exigem autorização explícita

Não executar automaticamente:

- merge;
- auto-merge;
- force push;
- bypass de hook;
- squash;
- atribuição de reviewers;
- labels;
- assignee;
- milestone;
- exclusão de branch;
- alteração de branch protection;
- alteração de secrets;
- qualquer mudança destrutiva;
- alteração de configuração global do Git.

## Documentação como artefato vivo

- A documentação representa o **padrão vigente**, não o histórico.
- O histórico pertence ao Git.
- Remover conteúdo obsoleto faz parte da manutenção.
- Atualizar exemplos antigos quando a convenção mudar.
- **Nunca duplicar regra.**

Antes de criar uma regra nova, verificar:

1. Já existe?
2. Existe parcialmente?
3. Pode ser incorporada a uma regra existente?
4. O assunto já tem um arquivo dono?

Se existir: **consolidar, atualizar e referenciar**. Nunca criar
documentação paralela.

## Decision → Rule → Learning

Método de registro de aprendizado:

```
Investigação
↓
Decision
↓
Rule
↓
Learning
```

| Etapa | O que registra | Onde mora |
|---|---|---|
| **Decision** | Por que decidimos fazer assim | Investigação / PR |
| **Rule** | Como fazemos daqui para frente | `AGENTS.md` |
| **Learning** | O que aprendemos e quais evidências sustentam | `ai/shared/knowledge/engineering-learnings.md` |

**Não duplicar o mesmo texto nos três lugares.** Cada etapa tem um dono;
as outras referenciam.

## Workflow de implementação (Design System e similares)

1. **Analisar primeiro**: design de referência, implementação existente
   em cada plataforma, arquitetura e componentes relacionados.
2. **Identificar reutilização antes de criar código.** Nunca duplicar
   algoritmos; reusar infraestrutura existente.
3. **Manter as plataformas alinhadas arquiteturalmente.**
4. **Separar responsabilidades**: o componente consumidor faz apenas o
   "de → para"; toda lógica compartilhada mora no componente
   reutilizável.
5. **Preservar APIs públicas**; evitar breaking changes.
6. **Testes**: atualizar existentes e criar novos quando necessário.
   Nenhuma entrega está pronta sem testes passando.
7. **Sample**: demonstrar dentro da página existente do componente;
   nunca criar página paralela.
8. **Validar antes de Git**: build + lint + testes + validação manual
   antes de qualquer commit ou PR.
