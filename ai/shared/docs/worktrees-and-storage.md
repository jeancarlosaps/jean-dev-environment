# Política de Git Worktrees e armazenamento local

Documento proprietário desta política. As regras em
`ai/shared/AGENTS.md` referenciam este arquivo; não duplicar o texto
completo em adapters (`.cursor`, `.claude`) nem em projetos
consumidores.

Aplica-se a quem usa Cursor, Claude Code, ambos, ou apenas Git
Worktrees — em qualquer linguagem e, com as adaptações de comando
abaixo, em macOS, Linux e Windows.

## 1. Princípio de reutilização

**Uma tarefa sequencial reutiliza o checkout existente.** Worktree
adicional só para paralelismo real ou isolamento técnico comprovado.

Antes de criar um worktree:

1. Listar checkouts existentes (`git worktree list --porcelain`).
2. Verificar se algum atende à tarefa (branch, HEAD, caminho).
3. Conferir alterações locais e processos concorrentes.
4. Avaliar se a operação cabe com segurança no checkout atual.
5. Só então criar um worktree novo, com justificativa registrada.

Não criar worktree automaticamente para: code review, continuação de
PR, correção de bug na mesma tarefa, testes, investigação de código,
atualização de documentação ou nova sessão de agente na mesma tarefa.

Não alternar de branch descartando alterações locais. Não permitir
escrita simultânea de agentes no mesmo checkout quando houver risco
de conflito.

Múltiplos worktrees são legítimos quando há necessidade real. Não
existe meta de reduzir a quantidade por si só.

## 2. Ciclo de vida

| Fase | Obrigação |
|---|---|
| **Criação** | Registrar repo, branch, tarefa e justificativa |
| **Utilização** | Reutilizar o checkout na implementação e nos testes |
| **Manutenção** | Revisar se ainda é necessário; sem exclusão automática |
| **Encerramento** | Confirmar fim da tarefa, PR, diffs, commits e processos |
| **Classificação** | Ativo, reutilizável, arquivado ou candidato à remoção |
| **Remoção** | Só com todos os critérios de segurança satisfeitos |

### Classificação

| Estado | Significado |
|---|---|
| **Ativo** | Tarefa ou processo em andamento |
| **Reutilizável** | Pode servir a novas tarefas sem recriação |
| **Arquivado** | Preserva contexto ou trabalho relevante |
| **Candidato à remoção** | Comprovadamente descartável após revisão humana |

### Remoção segura

Só remover quando: tarefa concluída, sem processo ativo, sem
alterações locais relevantes, sem commits exclusivos não publicados
(ou commits já incorporados de forma verificável), e com autorização
quando houver dúvida.

- Não remover automaticamente só porque o PR foi mergeado.
- Não usar `git worktree remove --force`.
- `git worktree prune` só com registros órfãos comprovados e após
  dry-run.
- Preservar branches e histórico Git; a remoção do checkout não é
  exclusão da branch.

## 3. Alertas de armazenamento

Verificar o espaço livre do volume que receberá dados **antes** de
builds grandes, novos worktrees, instalação de SDKs ou geração massiva
de arquivos. Estimar a operação de forma conservadora.

| Espaço livre | Estado | Ação |
|---|---|---|
| Acima do limite desejado | Normal | Operação permitida |
| Entre atenção e desejado | Atenção | Alertar antes de builds ou worktrees |
| Abaixo do limite crítico | Crítico | Suspender I/O volumoso; pedir autorização |

Valores padrão sugeridos (personalizáveis):

| Variável | Padrão | Papel |
|---|---|---|
| `DEV_STORAGE_OK_GIB` | `20` | Limite desejado (GiB) |
| `DEV_STORAGE_WARN_GIB` | `10` | Limite de atenção (GiB) |
| `DEV_STORAGE_CRIT_GIB` | `10` | Crítico (GiB); padrão = atenção |

Não criar daemon nem limpeza automática ao atingir limites. Os valores
não são requisitos rígidos para todas as máquinas.

Comandos de medição:

- macOS / Linux: `df -g <caminho>` ou `df -h <caminho>`
- Windows: `Get-PSDrive`

Medir o efeito de qualquer limpeza com `df` (ou equivalente) **antes e
depois**. Em APFS, `du` pode superestimar clones e montagens virtuais;
usar `du -x` e `mount` quando o número parecer inconsistente.

## 4. Área de rascunho opcional

Se `DEV_SCRATCH_DIR` existir e aceitar escrita, usar
`$DEV_SCRATCH_DIR/<agente>/` para ensaios, clones descartáveis e
artefatos de build, sempre por caminho explícito no comando. Sem a
variável, ou com o volume ausente, usar os caminhos padrão das
ferramentas. O ambiente não deve falhar por volume externo
desconectado, exceto para projetos que já residem nesse volume.

Não introduzir uma segunda estratégia concorrente de armazenamento
temporário. Não mover automaticamente projetos, SDKs ou dependências
para o volume externo. Não criar dependência obrigatória desse volume.

## 5. Recuperação de espaço

Ordem sugerida (maior benefício / menor risco):

1. Resíduos comprovadamente órfãos
2. Builds temporárias abandonadas
3. DerivedData / caches de build sem processo ativo
4. Worktrees comprovadamente descartáveis
5. Caches reconstruíveis de ferramentas
6. Artefatos volumosos de agentes, após verificar a função
7. Demais candidatos da auditoria

Classificar cada item como **ativo**, **reconstruível**, **órfão** ou
**sensível**. Antiguidade ou tamanho sozinhos não autorizam exclusão.

Proibido sem autorização explícita: exclusão em massa para atingir
meta de espaço; `git clean -fdx`; `git reset --hard`;
`git worktree remove --force`; `rm -rf` genérico; interrupção de
processos ativos; remoção de simuladores, SDKs, sessões, snapshots ou
volumes com uso incerto.

Preferir comandos oficiais da ferramenta (`xcrun simctl`, gerenciadores
de cache documentados) a remoção manual ampla.

## 6. Diagnóstico somente leitura

O script `scripts/storage-audit.sh` inventaria espaço livre, limites
configurados e worktrees de um repositório informado. Ele **não
exclui** nada e não exige privilégios administrativos.

```bash
./scripts/storage-audit.sh [caminho-do-repositório]
./scripts/storage-audit.sh --help
```

## 7. Adaptações por sistema

| Tema | macOS | Linux | Windows |
|---|---|---|---|
| Espaço livre | `df` | `df` | `Get-PSDrive` |
| Worktrees | `git worktree` | igual | igual (Git for Windows) |
| Builds Xcode | DerivedData, `simctl` | n/a | n/a |
| Android / Gradle | `~/.gradle`, SDK | iguais em `$HOME` | perfil do usuário + SDK |
| Node | `npm cache`, `~/.npm` | iguais | equivalentes no perfil do usuário |

## Referências

- Regras operacionais resumidas: `ai/shared/AGENTS.md` (seções
  "Armazenamento local" e fluxo Git)
- Evidências de incidentes: `ai/shared/knowledge/engineering-learnings.md`
  ("Armazenamento local no macOS — artefatos de build, simuladores e
  caches de agentes")
