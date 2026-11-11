# Política de tratamento de reviews em Pull Requests

Documento proprietário desta política. As regras em
`ai/shared/AGENTS.md` referenciam este arquivo; adapters (`.cursor`,
`.claude`) não devem duplicar o texto.

Aplica-se a PRs sob nossa responsabilidade, com Cursor, Claude Code,
ambos, ou fluxo Git manual.

## 1. Distinções obrigatórias

| Conceito | O que é | Como consultar (exemplos) |
|---|---|---|
| Comentário geral | Comentário no PR, fora de linha | `gh api repos/.../issues/<n>/comments` |
| Review submetido | Veredito (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`) | `gh pr view --json reviews,reviewDecision` |
| Comentário inline | Comentário ligado a um trecho | parte do review ou da thread |
| Review thread | Conversa agrupada (pode estar aberta ou resolvida) | GraphQL `pullRequest.reviewThreads` |

Lista vazia de comentários gerais **não** prova ausência de threads
inline. `MERGEABLE` não é aprovação técnica. CI ausente não é CI verde.
Thread resolvida não cancela sozinha um `CHANGES_REQUESTED`. Push
bem-sucedido não encerra o PR.

## 2. Ciclo obrigatório

**Consultar → Classificar → Corrigir → Validar → Publicar → Responder →
Resolver → Reconsultar.**

### Consultar

Antes de declarar a tarefa pronta ou o PR como `READY`:

1. Confirmar repositório (`-R`), número do PR, HEAD e branch base.
2. Buscar comentários gerais.
3. Buscar reviews submetidos e `reviewDecision`.
4. Buscar comentários inline e **todas** as review threads
   (resolvidas e não resolvidas).
5. Verificar comentários novos após o último push.

### Classificar

Cada apontamento recebe uma decisão:

- **Procedente** — corrigir.
- **Não procedente** — justificar na thread.
- **Dúvida respondida** — esclarecer sem mudança de código, se bastar.
- **Fora do escopo** — encaminhar ou registrar follow-up.
- **Bloqueado** — dependência externa ou falta de permissão; manter
  aberto e informar.

### Corrigir e validar

Para procedentes: causa, menor correção adequada, testes quando
necessário, validações relevantes, sem refatoração oportunista.

### Publicar

Commit e push só após validação. Confirmar que o commit está no HEAD
do PR (`gh pr view --json headRefOid` / comparação com o SHA local).

### Responder

Responder **na thread correspondente**, com:

- o que foi identificado;
- o que foi corrigido ou por que não será alterado;
- SHA do commit, quando houver correção;
- validação executada.

Proibido responder só com "fixed", "done" ou equivalentes sem contexto.
Não mencionar ferramentas de IA na resposta pública.

### Resolver

Após responder, e se o fluxo do repositório permitir:

- resolver a thread quando o apontamento estiver atendido;
- não resolver sem análise;
- não resolver com problema técnico ainda aberto;
- não resolver unilateralmente o que exige concordância explícita do
  revisor;
- se faltar permissão ou aceite, manter aberta e informar o motivo.

Métodos oficiais preferidos: `gh api graphql` com
`resolveReviewThread`, ou a UI do GitHub. Se a operação falhar,
registrar a limitação e **não** declarar a thread tratada.

### Reconsultar

Depois de escrever no GitHub:

1. Buscar de novo as threads.
2. Confirmar que a resposta aparece.
3. Confirmar que a resolução persistiu (`isResolved`).
4. Identificar comentários novos.
5. Conferir `reviewDecision` atual.

Não declarar sucesso só pelo retorno do comando de escrita.

## 3. Status de conclusão do PR

| Status | Quando usar |
|---|---|
| `READY` | Código publicado; testes ok; CI obrigatório verde (se existir); feedback tratado; respostas publicadas; threads resolvidas quando apropriado; restantes justificadas; reviews obrigatórios satisfeitos; HEAD e base confirmados; sem finding bloqueante |
| `AWAITING_REVIEW` | Trabalho técnico feito e feedback tratado na medida do possível; falta revisão humana ou re-review |
| `BLOCKED` | Comentário pendente de tratamento, resposta não publicada, thread bloqueante aberta, CI obrigatório falhando, ou review obrigatório ainda não satisfeito |

Um PR **não** fica `READY` apenas porque o código foi enviado.

## 4. Worktrees

Code review e tratamento de threads reutilizam o checkout da tarefa.
Não criar worktree só para responder comentários. Política completa:
`ai/shared/docs/worktrees-and-storage.md`.

## 5. Autorizações

Merge, auto-merge, force push e bypass de proteção continuam exigindo
autorização explícita (`AGENTS.md`, "Ações que exigem autorização
explícita").

## Referências

- Regras resumidas: `ai/shared/AGENTS.md` (Pull Requests; estado da
  execução)
- Evidências: `ai/shared/knowledge/engineering-learnings.md`
