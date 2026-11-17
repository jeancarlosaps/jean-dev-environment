---
name: pre-pr-audit
description: Audita o diff da branch contra a base antes de abrir ou atualizar um PR — API pública, disponibilidade de plataforma, pipeline versionado duplicado, contrato, nomenclatura, testes, segredos e escopo — e conduz a revisão adversarial com evidência arquivo:linha. Usar antes de publicar qualquer PR, ou quando pedirem para auditar a branch.
---

# Auditoria pré-PR

Etapa do fluxo do `ai/shared/AGENTS.md`, entre **Testes** e **Pull Request**:

```
Implementação → Testes → Auditoria pré-PR → PR → Review → Autorização → Merge
```

A auditoria produz evidência; não aprova, não autoriza nem publica nada.

## 1. Executar a verificação determinística

Pré-condições: o trabalho do PR está commitado (alteração não commitada
fica fora da auditoria e aparece como `CORE-UNCOMMITTED`) e a base é a da
regra do repositório — nunca assumida.

```bash
python3 "${DEV_ENV_HOME:-$HOME/Developer/dev-env}/scripts/pre-pr-audit.py" \
  --repo . --base <base-da-regra-do-repositório> \
  [--evidence evidencias.json] [--policy politica.json] [--scope 'Sources/Feature/*']
```

- Sem `--base`, usa `origin/HEAD` e, na falta dele, `origin/main`,
  `origin/master`, `origin/dev`, `origin/develop` — e diz qual usou.
- `--format json` para consumo por outra ferramenta; o padrão é Markdown.
- Saída: `0` sem BLOCKER · `1` com BLOCKER · `2` erro de uso ou leitura.

### Evidência de verificações

Registrar só o que foi executado de fato, com o status real:

```json
{"checks": [{"name": "tests", "command": "swift test", "exit": 0},
            {"name": "lint", "command": "swiftlint", "exit": 0}]}
```

Nunca escrever uma verificação que não rodou. Sem evidência, a auditoria
diz "sem evidência de execução" — e isso é o correto.

### Política opcional

Ordem: `--policy`, variável `PRE_PR_AUDIT_POLICY`, `.pre-pr-audit.json` na
raiz do repositório auditado. Sem política, rodam as verificações
universais. Política configurada e ausente, ou com chave desconhecida, é
erro. Chaves:

| Chave | Efeito |
|---|---|
| `scope_paths` | globs do escopo do PR; arquivo fora vira `CORE-SCOPE` |
| `ignore_paths` | globs fora da auditoria (arquivos gerados) |
| `required_checks` | nomes que precisam aparecer no arquivo de evidência |
| `verb_synonyms` | grupos de verbos equivalentes, além de `remove/delete/del` |
| `min_platforms` | plataforma mínima, ex. `{"ios": "15.0"}`, quando não há `Package.swift`/`project.pbxproj` |
| `library` | força (ou desliga) o tratamento de biblioteca para API pública |

Política de uma empresa ou time fica fora deste repositório, no local do
próprio time, e entra por `--policy` ou `PRE_PR_AUDIT_POLICY`.

## 2. Tratar os achados

| Severidade | Significa | Tratamento |
|---|---|---|
| BLOCKER | violação comprovada de requisito obrigatório | não publicar o PR até corrigir |
| WARNING | possível problema técnico | investigar e classificar antes de publicar |
| INFO | melhoria opcional | registrar; não bloqueia |

Cada WARNING é investigado no código e classificado (regressão, bug,
dívida existente, melhoria, fora do escopo — `AGENTS.md` → *Classificação
obrigatória dos achados*). Achado heurístico improcedente é descartado com
a razão escrita, nunca em silêncio. Um WARNING não vira BLOCKER só porque
um padrão casou, e um BLOCKER não vira WARNING sem prova de que a regra
não se aplica.

## 3. Revisão adversarial

Depois do relatório, ler o diff como um tech lead rigoroso e responder às
perguntas da seção *Revisão adversarial* do relatório. Regras:

- toda resposta cita `arquivo:linha` do diff (ou da base, quando o ponto é
  o que foi removido);
- "não se aplica" diz por quê;
- inferência é marcada como inferência; nada é dado como verificado sem
  ter sido lido ou executado;
- o que a auditoria lista em *Não avaliado* continua não avaliado —
  completar à mão ou declarar.

Entregar ao desenvolvedor: o relatório, a classificação de cada WARNING e
as respostas da revisão adversarial. O PR só é publicado depois disso.

## 4. O que a auditoria verifica

Universal (qualquer linguagem):

| Regra | Método |
|---|---|
| `CORE-SECRET` formato conhecido de credencial (BLOCKER) | determinística |
| `CORE-SECRET-LIKE` valor literal em `password`/`token`/`api_key` | heurística |
| `CORE-LOCAL-PATH` caminho pessoal (`/Users/<nome>/`, `/home/<nome>/`) | determinística |
| `CORE-TESTS-MISSING` código alterado sem teste no diff (por linguagem, ou teste que cite o arquivo) | heurística |
| `CORE-DUPLICATION` 6+ linhas adicionadas idênticas em dois lugares | heurística |
| `CORE-NAMING` verbo sinônimo novo contra o vocabulário do módulo na base | heurística |
| `CORE-SCOPE` arquivo fora do escopo declarado | determinística |
| `CORE-CHECK-UNPROVEN` / `CORE-CHECK-FAILED` verificação obrigatória sem evidência / com falha | determinística |

Swift/iOS (quando há `.swift` alterado):

| Regra | Método |
|---|---|
| `SWIFT-AVAILABILITY` API acima da plataforma mínima, fora de `#available`/`@available`/`#unavailable … else` (tabela curada) | BLOCKER só quando comprovado; WARNING quando há dúvida (abaixo) |
| `SWIFT-API-BREAK` declaração `public`/`open`, membro de `public extension`, `case` de `public enum`, requisito de protocolo público ou conformidade da base sem equivalente compatível no HEAD (inclui arquivos excluídos) | determinística no nível da declaração |
| `SWIFT-API-DEPRECATED` API antiga mantida como deprecated — confirmar delegação e teste | heurística |
| `SWIFT-PROTOCOL-REQUIREMENT` requisito novo em protocolo público sem implementação padrão | heurística |
| `SWIFT-PIPELINE-DUPLICATED` cases de `switch` de versão com a mesma cadeia de operadores (idêntica, ou uma só acrescentando operadores) | heurística |
| `SWIFT-CONTRACT-KEYS` chave de `CodingKeys` removida/renomeada em tipo existente | determinística |
| `SWIFT-MUTATION-FALLBACK` função de mutação que, no caminho de erro, chama versão anterior | heurística |
| `SWIFT-CONCURRENCY-UNSAFE` `@unchecked Sendable`, `nonisolated(unsafe)` | determinística |
| `SWIFT-DEPRECATED-NO-MESSAGE` deprecated sem `message:`/`renamed:` (fora de testes) | determinística |
| `SWIFT-TEST-FRAMEWORK-MIX` XCTest e Swift Testing no mesmo arquivo | determinística |

### Quando `SWIFT-AVAILABILITY` é BLOCKER

Só quando tudo abaixo vale; caso contrário é WARNING, e a evidência diz o
que não está comprovado:

- o símbolo é inequívoco na tabela e o projeto não declara um tipo ou
  função com o mesmo nome (backport);
- a plataforma mínima vem do `Package.swift` mais próximo do arquivo, da
  política, ou de um `project.pbxproj` com um único valor por plataforma;
- o uso não está dentro de `#if … #endif`;
- nenhuma proteção cobre o uso: `if #available`, `guard #available`,
  `@available(iOS 16, *)`, `@available(iOS, introduced: 16)` ou o `else`
  de `if #unavailable`.

### Compatibilidade de assinatura

A comparação usa rótulo externo, tipo e se o argumento pode ser omitido.
Trocar só o nome local ou o valor de um padrão, ou acrescentar um padrão,
não é quebra; remover um padrão ou trocar um rótulo externo é.

## 5. Limites

- Erro de leitura do git, política ou evidência inválida, caminho com quebra
  de linha ou erro interno encerram com status 2: a auditoria nunca devolve
  relatório vazio com status 0 por falha própria.
- Nenhum texto de achado sai com credencial reconhecível: todo achado é
  mascarado antes do relatório, seja qual for a regra.
- Sem compilador: tipos, sobrecargas, macros e código gerado não são
  resolvidos. Declarações com cabeçalho em várias linhas antes da `{` do
  tipo podem escapar.
- A tabela de disponibilidade é curada e não exaustiva.
- Pipeline com troca ou remoção de operador entre versões não é
  sinalizado: pode ser diferença legítima de transporte ou de erro.
- Nome inconsistente que já existia na base não é sinalizado; a regra
  olha só o que a mudança introduz.
- Requisições duplicadas entre cliente e servidor e mudanças de
  comportamento em execução dependem da revisão adversarial.

## 6. Dependências

Python 3.9+ (biblioteca padrão) e git 2.20+. Os testes usam também `jq`.
Funciona em macOS e Linux, sem rede e sem configuração corporativa.

## 7. Uso por ferramenta

O arquivo é o mesmo para qualquer agente. Claude Code e Cursor leem skills
no formato `SKILL.md` com `name` e `description`; a ligação deste arquivo
nos diretórios de skills de cada ferramenta é feita na instalação do
ambiente, não aqui. Sem a ligação, a skill pode ser seguida lendo este
arquivo e executando o script.
