> Este documento registra aprendizados arquiteturais importantes.
> Não substitui documentação funcional nem ADRs.
> Deve servir como memória técnica para futuras implementações e para orientar agentes de IA durante desenvolvimento e investigação.

# Como utilizar este documento

Este documento é a **memória técnica** do ambiente: decisões e aprendizados
obtidos em investigações reais, reutilizáveis por qualquer agente.

Todo agente deve:

1. Procurar primeiro um aprendizado relacionado ao componente que será alterado.
2. Ler a investigação antes de propor qualquer implementação.
3. Não assumir que um aprendizado antigo continua válido sem verificar sua evolução.
4. Atualizar um aprendizado existente sempre que ele evoluir, em vez de criar um documento duplicado.

> Este documento complementa as regras do projeto.
> Ele registra decisões arquiteturais e aprendizados obtidos durante investigações reais.

---

# Confidence

Cada aprendizado (ou evolução relevante) deve declarar um nível de confiança.
Atualizar o nível conforme a investigação evolui. **Nunca remover histórico.**

Valores permitidos:

🟢 **Validado em produção**

- Implementação mergeada
- Revisada
- Sem regressões conhecidas

🟡 **Validado em laboratório / POC**

- Testes concluídos
- Ainda sem uso em produção

🟠 **Hipótese forte**

- Evidências técnicas consistentes
- Ainda aguardando validação

🔴 **Investigação em andamento**

- Ainda não existe conclusão definitiva

---

# Evolução dos aprendizados

Regras:

- Nunca criar um novo aprendizado para um assunto já existente.
- Sempre atualizar a entrada existente.
- Preservar a evolução arquitetural em um único lugar.

Exemplos (BottomSheet):

- investigação inicial
- solução adotada
- ajustes posteriores
- lições aprendidas

Tudo na mesma entrada. **Não** criar:

- BottomSheet v2
- BottomSheet Keyboard
- BottomSheet Final
- BottomSheet Correção
- BottomSheet Melhorias

---

# BottomSheet — Window Metrics e Keyboard Handling

## Contexto

No BottomSheet iOS apareceram dois problemas:

- Header quebrava com títulos longos (botão de fechar desalinhado).
- BottomSheet LG encolhia quando o teclado aparecia — visualmente parecia virar SM.
- O comportamento divergia do Android, onde a altura LG permanece estável com IME.

A primeira tentativa de correção (workarounds de teclado) introduziu regressões e foi descartada. A solução correta veio depois, e ainda recebeu ajustes incrementais na develop.

---

## Investigação

O `GeometryReader` continua correto para layout, overlay, drag e animação. O erro foi usá-lo como fonte da **altura nominal** do LG (`geometry.size.height * 0.9`).

Quando o teclado abre, o host aplica keyboard avoidance e a geometria encolhe. A altura LG acompanha esse encolhimento → efeito visual de “LG virou SM”, sem mudar o enum de size.

Diferenças de métrica:

- `geometry.size` — viewport SwiftUI atual (instável com teclado).
- `UIWindow.bounds` — bounds da window onde o sheet está hospedado (estável se for a window certa).
- `UIScreen.main` — screen global; falha em Split View / Stage Manager e não distingue overlay UIKit.

No Android, LG usa altura de tela/config estável (`screenHeightDp * 0.90`), não a área já reduzida pelo IME. iOS precisava da mesma ideia: métrica de apresentação estável + pan do painel.

---

## Primeira solução

Decisão arquitetural (não workaround):

- Descobrir a **presentation window** real via probe `UIView.window` (ThemeProvider e overlay do WindowManager).
- Calcular LG como `presentationWindow.bounds.height * 0.9`, com fallback para Geometry só sem window.
- Observar `keyboardWillChangeFrame` e aplicar **keyboard lift** no painel (`overlap - geometryShrink` para evitar double-lift).
- Manter GeometryReader para layout/drag/barrier; não reduzir a altura LG; não usar ScrollView nem `.ignoresSafeArea(.keyboard)` como “solução”.
- Corrigir Header com título flexível e botão com prioridade de layout (paridade Android).

Contrato público inalterado. Helper interno concentra window + overlap de teclado.

---

## Ajustes posteriores

Após o merge, ajustes incrementais na develop (não reimplementação):

- Barrier: se teclado visível, tap fecha teclado; senão, dismiss do sheet.
- `simultaneousGesture(TapGesture)` no painel para resign sem competir com `DragGesture`.
- `.ignoresSafeArea()` → `.ignoresSafeArea(.container, edges: .all)` (mais honesto com a região de teclado; pan continua explícito).
- Drawer SM: simplificação do offset off-screen (menos estado de altura medida).
- Testes fortalecidos para overlap de teclado, box da window e barrier com teclado.

Essas mudanças complementam a solução existente (presentation window + lift + header). O núcleo não foi removido nem substituído.

---

## Lições aprendidas

- Sempre investigar a causa raiz antes de usar workarounds.
- Evitar soluções específicas para uma versão de iOS quando o bug é de métrica/arquitetura.
- Preferir alinhar arquitetura entre plataformas quando possível (Android já usava altura estável + IME).
- Validar UIKit e SwiftUI (paths de apresentação diferentes).
- Validar comportamento em iPad e multitarefa (window ≠ screen).
- Quando uma implementação boa receber melhorias, registrar o porquê dessas melhorias.
- Overlay modal precisa de política explícita: fechar teclado vs fechar sheet.
- Helper de métricas testável protege o contrato melhor que hacks espalhados no layout.

---

## Recomendações futuras

Quando implementar componentes semelhantes (sheets, drawers, overlays com input):

- Validar keyboard handling desde o início do desenho.
- Pensar em Window Scene / presentation window antes de `UIScreen`.
- Separar lógica de layout (altura nominal, geometry) da lógica de interação (IME, barrier, drag).
- Fortalecer testes do contrato de métricas antes de encerrar a task.
- Levar playground de regressão no Sample no mesmo ciclo do fix do DS.
- Não mascarar keyboard avoidance com `.ignoresSafeArea(.keyboard)` sem pan/offset explícito.

---

# ListLine/ListContent UIKit — accessories interativos e hit-testing

## Confidence

🟡 Validado em laboratório / POC

## Contexto

Report do produto (VirtuCard): `BradsButtonIcon` (SwiftUI) hospedado no
`trailingItem: UIView` do `BradsUIListContent` renderizava mas não recebia
clique. O time suspeitava do hosting/adapter.

## Investigação

- Hosting **não** era o problema: `UIButton` UIKit puro no mesmo slot falhava igual.
- `BradsUIListLine.configurePressHandling()` fazia `isUserInteractionEnabled = false`
  quando `onPress == nil` — em UIKit isso exclui **toda a subárvore** do hit-testing.
- `BradsUIListContent` sempre cria o ListLine com `onPress: nil` → slots mortos.
- Acessibilidade agravava: row achatada em um único elemento `.staticText` e
  slots com `isAccessibilityElement = false` → accessory interativo invisível
  ao VoiceOver.
- Referências que distinguem row × accessory: `UITableViewCell.accessoryView`,
  `UICellAccessory`, Compose (nested clickable, filho consome). O DS Android
  com a mesma API de slots funciona de graça; só o iOS divergia.

## Causa raiz

Gate de interação implementado no nível errado: `isUserInteractionEnabled`
(afeta a árvore inteira) em vez do nível do gesture (afeta só a row).

## Solução adotada

Branch `fix/list-line-accessory-interaction` (DS iOS):

1. ListLine não desliga mais `isUserInteractionEnabled`; sem `onPress` apenas
   não instala gesture nem highlight.
2. Exclusão row × accessory: `UIGestureRecognizerDelegate.gestureRecognizer(_:shouldReceive:)`
   + guard no `touchesBegan` ignoram toques originados em descendentes que
   tratam o próprio toque.
3. Heurística genérica (`UIView+InteractiveDescendant.swift`, internal):
   `UIControl` || gesture recognizers habilitados (cobre `_UIHostingView`) ||
   elemento de acessibilidade com trait interativo (cobre `BradsUISwitch`,
   que trata toque via `touchesBegan`).
4. Acessibilidade em camadas no ListContent: com accessory interativo a row
   vira container (`accessibilityElements` = accessory + conteúdo agrupado);
   sem accessory interativo, comportamento original preservado.

Sem mudança de API pública. ListSelect preservado por design: os controles
espelhados têm `isAccessibilityElement = false` e não são detectados como
interativos → row inteira continua sendo o alvo.

## Lições aprendidas

- Nunca usar `isUserInteractionEnabled = false` num container que embute
  conteúdo do consumidor; o gate correto é no gesture.
- Bugs de "SwiftUI dentro de UIKit não clica" devem ser triados com um
  `UIButton` puro no mesmo lugar antes de culpar o hosting.
- Conteúdo SwiftUI hospedado instala gesture recognizers de forma lazy
  (ao entrar na window) — detecção de interatividade precisa reavaliar em
  `didMoveToWindow`.
- `swift test` (macOS) não valida o DS; a suíte real roda via
  `xcodebuild test -scheme BdsCore` em iOS Simulator.

## Recomendações futuras

- Aplicar o mesmo contrato em futuros Lists (`ListNavigation`, `ListInfo`)
  e revisar Cards/Accordion com trailing interativo.
- Considerar documentar oficialmente o contrato dos slots em `docs/`.

## Referências

- Investigação: `docs/local/INVESTIGACAO_LISTCONTENT_TRAILING_INTERACTION.md` (DS iOS)
- PR #39 (origem do ListLine/ListContent UIKit, 2026-05-19)
- Arquivos: `Sources/BradsCoreUIKit/Components/ListLine/BdsUIListLine.swift`,
  `Sources/BradsCoreUIKit/Components/ListContent/BdsUIListContent.swift`,
  `Sources/BradsCoreUIKit/Extensions/UIView+InteractiveDescendant.swift`

---

# Paridade entre SwiftUI, UIKit e Android deve prevalecer sobre criação de novas APIs

## Confidence

🟢 Validado em produção

---

## Contexto

Durante a evolução de `BradsUIHeading` e `BradsUIDescription`, surgiu a
necessidade de adicionar suporte à customização de cor de texto nos
componentes UIKit do DS.

A investigação mostrou que:

- SwiftUI já possuía `color: Color?` (desde a criação dos componentes).
- Android já possuía `color: Color? = null` (desde o first commit).
- Apenas o UIKit não possuía essa capacidade.

Ou seja, o problema não era de Design nem de arquitetura.
Era apenas uma **lacuna de paridade**.

---

## Investigação

Levantamento completo antes de qualquer proposta de API:

- API pública e resolução de cor nas três plataformas.
- Histórico de commits e PRs (iOS e Android) — o parâmetro nunca foi
  removido; o UIKit simplesmente nunca o recebeu.
- Figma — a spec usa tokens padrão (`text-color/heading`,
  `text-color/description`, `inverse/*`); não define enum semântico de cor.
- Padrão já consolidado em outros componentes UIKit (`BradsUIParagraph`,
  `BradsUILabel`, `BdsIcon`): `color: Color?` + `update(color: Color?? = .none)`.

Alternativas descartadas:

- `foregroundColor: BradsColor?` — nome divergente do resto do DS e
  `BradsColor` não é tipo de parâmetro (é paleta de helpers no Adapter).
- Token/enum semântico novo — sem respaldo no Figma nem no Android;
  `inverse` já cobre o caso semântico oficial.

---

## Causa raiz

Lacuna de paridade entre camadas do DS: o contrato de customização de cor
já existia e estava validado em duas plataformas, mas a camada UIKit foi
criada sem ele e nunca foi alinhada.

---

## Solução adotada

Alinhar o UIKit ao contrato já consolidado, sem criar API nova:

- `public var color: Color?` + `init(..., color: Color? = nil)` +
  `update(..., color: Color?? = .none)` em `BradsUIHeading` e
  `BradsUIDescription`.
- Precedência idêntica ao SwiftUI e ao Android:
  `color` custom → `inverse` → token padrão do tema.
- Links do Description **não** são afetados pelo override do corpo.
- **Não** copiar o comportamento do `BradsUIParagraph`, que possui uma
  inconsistência conhecida onde `inverse` vence `color`.

Resultado: mesma API pública, mesma precedência, mesma semântica,
nenhuma nova abstração. Mudança aditiva e retrocompatível.

---

## Lições aprendidas

Antes de propor uma nova API pública para um componente do DS, validar
obrigatoriamente:

1. SwiftUI
2. UIKit
3. Android
4. Histórico de commits
5. Histórico de PRs
6. Figma
7. Tokens
8. Assets

Se uma plataforma já definiu o contrato e ele atende ao Design, a
prioridade deve ser **convergir para esse contrato**. Criar uma terceira
API deve ser considerado apenas quando houver justificativa arquitetural
forte.

---

## Recomendações futuras

Esse padrão deve ser seguido em futuras evoluções de:

- Badge
- Chip
- Banner
- Tooltip
- Toast
- Card
- Avatar
- Inputs
- qualquer componente implementado em múltiplas plataformas

---

## Referências

- PR #102 (liquid-design-system-ios) — commit `28a5daa`
- `Sources/BradsCoreUIKit/Components/Heading/BdsHeading.swift`
- `Sources/BradsCoreUIKit/Components/Description/BdsDescription.swift`
- Contrapartes: `BradsHeading` / `BradsDescription` (SwiftUI) e
  `BradsHeading` / `BradsDescription` (Android, Compose)

---

# Inspeção da árvore real de acessibilidade em apps iOS/SwiftUI via LLDB

## Confidence

🟡 Validado em laboratório / POC

Técnica reproduzida em investigações de acessibilidade no simulador, com
resultados coerentes entre SwiftUI e UIKit e com o comportamento relatado
pelo QA. Ainda não confrontada com captura de fala em device físico.

---

## Contexto

Investigações de acessibilidade no DS (agrupamento indevido, ordem de foco,
traits, ícones decorativos) exigem ver **o que o VoiceOver enxerga**, não o
que a hierarquia de views sugere. As ferramentas usuais falham:

- **Accessibility Inspector** — depende de conceder acesso ao processo
  `axAuditService`; nesse ambiente esse acesso não é concedível, então o
  Inspector fica inutilizável.
- **Ajustes de VoiceOver no simulador** — versões recentes do runtime iOS
  não expõem VoiceOver em Ajustes; não há como ligar o leitor e ouvir.
- **`XCUIApplication.debugDescription`** — lista views subjacentes de forma
  praticamente idêntica sob `.ignore` e `.contain`, então **não** serve como
  oráculo de agrupamento nem de ordem de foco. Além disso exige target de
  teste, o que polui o projeto do app de amostra.
- **Caminhar `subviews` por conta própria** — em SwiftUI não retorna nada:
  a hierarquia visível é de `_UIHostingView`, `HostingScrollView` e views
  internas, todas com `isAccessibilityElement = false`, `accessibilityLabel`
  nulo e `accessibilityElementCount == 0`.

---

## Investigação

Ao caminhar a hierarquia de um app SwiftUI dentro do processo, todos os nós
aparecem vazios: nenhum rótulo, nenhuma trait, contagem de elementos zero.
A mesma varredura em telas UIKit devolve os elementos normalmente
(`BradsUIHeading`, `UILabel`, etc.).

A diferença é que o UIKit **é** a árvore de acessibilidade — cada `UIView`
implementa o protocolo informal `UIAccessibility`. Já o SwiftUI mantém uma
árvore própria e só a projeta para o mundo `UIAccessibility` quando existe
um cliente assistivo. Sem cliente, os nós simplesmente não são construídos.

---

## Causa raiz

Os nós `SwiftUI.AccessibilityNode` são **materializados sob demanda**.

O SwiftUI não cria um objeto de acessibilidade por view: ele guarda os
modificadores (`accessibilityLabel`, `accessibilityElement(children:)`,
traits, ações) na sua própria árvore de render e só instancia os
`AccessibilityNode` — que são os `UIAccessibilityElement` expostos ao
`_UIHostingView` — quando o runtime de acessibilidade do processo está
ativo. Esse runtime é ligado por um cliente assistivo (VoiceOver, Switch
Control) ou pelo modo de automação usado pelo XCTest/XCUITest.

Consequência prática: **a árvore não está "escondida", ela não existe**
enquanto o runtime estiver desligado. Qualquer inspeção feita antes de
ligá-lo produz falso negativo — inclusive a conclusão errada de que um
componente "não expõe nada para o VoiceOver".

---

## Solução adotada — técnica de inspeção via LLDB

Ligar o runtime de acessibilidade dentro do próprio processo e caminhar a
árvore resultante. Não requer target de teste, não altera código do app nem
do DS, e não deixa resíduo no repositório.

### Passo a passo

1. **Rodar o app no simulador** (build de debug) e deixá-lo na tela que será
   analisada. A árvore é materializada por tela: navegar antes, inspecionar
   depois.

2. **Anexar o LLDB ao processo** — `process attach --pid <pid>`. O pid é o
   devolvido por `xcrun simctl launch`. Anexar **congela** o app; ele volta
   a rodar no `detach`.

3. **Carregar `libAccessibility.dylib`** —
   `(void*)dlopen("/usr/lib/libAccessibility.dylib", 2)`. A biblioteca
   normalmente não está no processo; sem carregá-la o símbolo do passo
   seguinte não resolve. O `2` é `RTLD_NOW`.

4. **Ligar o modo de automação** — `(void)_AXSSetAutomationEnabled(1)`. É o
   mesmo interruptor que o XCUITest usa. A partir daqui o SwiftUI passa a
   construir os `AccessibilityNode`. Conferir com
   `@((int)_AXSAutomationEnabled())` — deve retornar `1`.

5. **Caminhar a árvore** com uma expressão Objective-C que, para cada nó,
   registra `isAccessibilityElement`, `accessibilityElementsHidden`,
   `accessibilityTraits`, `accessibilityLabel`, `accessibilityValue` e
   `accessibilityHint`, e então:
   - se `accessibilityElementCount > 0`, desce por
     `accessibilityElementAtIndex:` (essa é a rota de container que o
     VoiceOver usa);
   - senão, desce por `subviews` (caso UIKit puro);
   - e **para de descer quando `isAccessibilityElement == 1`**, porque o
     VoiceOver não entra dentro de um elemento. Sem essa parada, o dump
     mostra o `UILabel` interno de um componente que já é elemento e cria a
     ilusão de leitura duplicada.

   Gravar o resultado em arquivo (`writeToFile:atomically:encoding:`) em vez
   de imprimir: a saída passa de alguns KB e o `-O` do LLDB fica ilegível.

6. **`detach`** para liberar o app.

### Detalhes de execução que economizam tempo

- O avaliador do LLDB roda como Objective-C++, não ObjC puro: `NSNotFound`
  não resolve (usar o literal ou um limite), funções com retorno inferido
  precisam de cast explícito (`(NSString*)NSStringFromClass(...)`) e
  variádicos como `appendFormat:` falham — montar a string com
  `appendString:` e `[@(x) stringValue]`.
- Em arquivo de comandos (`lldb -b -s script.lldb`), a expressão precisa
  caber em **uma linha**; gerar essa linha a partir de um arquivo auxiliar.
- Recursão dentro da expressão: bloco `__block void (^walk)(id,int)` que se
  invoca. Limitar profundidade evita travar em hierarquias patológicas.
- Escrever em `/tmp` a partir do app do simulador cai no `/tmp` do **host**,
  o que facilita ler o dump.

### Quando funciona, limitações e cuidados

- Funciona em **simulador com build de debug**, SwiftUI e UIKit, e em telas
  mistas (host SwiftUI embrulhando view UIKit) — é justamente o caso em que
  comparar as duas camadas importa.
- Não funciona contra build de release assinada nem em device físico sem
  depuração habilitada.
- `_AXSSetAutomationEnabled` é **API privada**: serve para investigação
  local e **nunca** deve entrar em código de produção, de teste versionado
  ou de CI.
- O flag vale enquanto o processo viver; ao reiniciar o app, repetir os
  passos 3 e 4.
- Anexar o depurador pausa o app: capturar screenshot **antes** de anexar,
  se a evidência visual for necessária.
- A árvore muda com a tela e com o estado; sempre registrar qual tela e qual
  configuração do playground geraram o dump.

---

## Evidências e validação

O que valida o dump como sendo a árvore do VoiceOver:

- **É a mesma rota de leitura.** A varredura usa exatamente as APIs que o
  VoiceOver consome (`accessibilityElementCount` /
  `accessibilityElementAtIndex:` / propriedades de `UIAccessibility`), com a
  mesma regra de não descer dentro de um elemento.
- **Reage aos modificadores.** Trocar `.ignore` por `.contain`, ou esconder
  um ícone decorativo, muda o dump de forma correspondente — comportamento
  que o `debugDescription` do XCUITest não reproduzia.
- **Traits conferem com a semântica declarada.** A bitmask lida bate com os
  modificadores aplicados: 1 = Button, 2 = Link, 4 = Image, 8 = Selected,
  64 = StaticText, 256 = NotEnabled, 4096 = Adjustable, 65536 = Header
  (`262144` aparece em campos de texto e é privada).
- **Comparação controlada.** Reproduzir a condição antiga em cópia local do
  componente e comparar os dois dumps isola a causa com precisão, sem
  depender de memória de comportamento.

Limitações que permanecem:

- O dump é **entrada** do VoiceOver, não a **fala**. Como a fala é
  sintetizada pelo leitor a partir do rótulo, das traits e do idioma do
  bundle, o texto efetivamente ouvido — e a pronúncia de caracteres sem
  nome Unicode — só se confirma em **device físico com VoiceOver ligado**.
- Ordem de foco: o dump dá a ordem dos elementos na árvore, que é a base do
  swipe do VoiceOver, mas heurísticas geométricas e agrupamentos do leitor
  só se confirmam com gesto real em device.
- Não substitui teste com usuário nem auditoria formal.

---

## Quando utilizar

Usar esta técnica **antes** de qualquer conclusão em investigações de:

- divergência de acessibilidade entre UIKit e SwiftUI do mesmo componente;
- comparação de comportamento entre plataformas (iOS × Android), onde o lado
  Android é medido com dump de semântica do Compose;
- validação de `.combine` / `.contain` / `.ignore` e de agrupamento indevido;
- ordem de foco e quantidade de paradas de foco;
- traits e papéis (botão, cabeçalho, texto estático, ajustável);
- ícones e assets decorativos que vazam para o leitor de tela;
- rótulos vazios, duplicados ou compostos incorretamente;
- qualquer relato de QA que não seja reproduzível pela leitura do código.

---

## Lições aprendidas

1. **Não depender do Accessibility Inspector.** Ele é frequentemente
   indisponível no ambiente e não é a única fonte de verdade.
2. **Inspecionar a árvore real do runtime.** Hierarquia de views, código-
   fonte e `debugDescription` são aproximações; a árvore materializada é o
   contrato efetivo.
3. **Ausência de nós não é prova de nada** enquanto o runtime de
   acessibilidade estiver desligado — é o erro mais caro dessa classe de
   investigação.
4. **Parar a varredura no elemento** ao interpretar o dump; caso contrário
   surgem "duplicações" que não existem para o usuário.
5. **Divergência entre esperado e observado é gatilho para medir**, não para
   argumentar a partir do código.
6. Separar sempre **rótulo** (conteúdo, definido pelo componente) de
   **tipo/estado/dica** (gerado pelo leitor a partir das traits e do idioma
   do bundle do app hospedeiro) — são causas-raiz diferentes e times
   diferentes.

---

## Recomendações futuras

Orientação permanente: em qualquer investigação de acessibilidade nos
projetos iOS deste ambiente, **considerar esta técnica antes de recorrer a
alternativas** (criar target de teste, instrumentar o app, pedir validação
manual ao QA ou concluir a partir da leitura do código).

Sequência recomendada:

1. Reproduzir a tela no app de amostra.
2. Coletar o dump da árvore com a técnica acima.
3. Só então formular a causa raiz.
4. Reproduzir a condição contrária (com e sem o modificador suspeito) e
   comparar dumps.
5. Guardar os dumps como evidência junto do relatório da investigação.
6. Escalar para device físico apenas o que depende de fala ou de gesto real.

Manter os dumps em pasta local de documentação (não versionada) e referi-los
no relatório, para que a conclusão possa ser reconferida depois.

---

## Referências

- `Sources/BradsCore/Components/Content/Icon/Icon.swift` — caso típico de
  ícone decorativo cuja exposição só é observável no dump.
- `Sources/BradsCore/Layout/Card/Base/Card+Base.swift` — estratégia
  `.contain` / `.ignore` cujo efeito real só se comprova na árvore.
- `Sources/BradsCoreUIKit/Components/Icon/BdsIcon.swift` — contraparte UIKit,
  onde a árvore existe sem depender do runtime de automação.
- `/usr/lib/libAccessibility.dylib` — `_AXSSetAutomationEnabled` /
  `_AXSAutomationEnabled` (API privada, uso restrito a investigação local).

---

# `UIViewRepresentable`: autoridade única do estado de foco

## Confidence

🟡 Validado em laboratório / POC

Correção reproduzida e verificada em simulador (ciclo de foco convergindo, layout
constante) e coberta por testes unitários do bridge, incluindo teste de regressão
de sessão completa de edição. Ainda sem uso em produção.

---

## Contexto

Um componente SwiftUI às vezes precisa embrulhar uma view UIKit
(`UIViewRepresentable`) para obter capacidade que o framework nativo não oferece
— camada de display separada do valor, controle fino de seleção/cursor, teclado
customizado. A troca parece local: "só o widget de dentro muda".

Não é. Junto com o widget muda **quem é dono do foco**. O SwiftUI tem seu próprio
sistema (`FocusState` + `.focused`), e a view embrulhada participa da cadeia de
responders do UIKit (`becomeFirstResponder` / `resignFirstResponder`,
`textFieldDidBeginEditing` / `textFieldDidEndEditing`). Ambos os lados acham que
mandam, e nenhum sabe da existência do outro.

Some-se a isso a assimetria temporal: o foco iniciado pelo usuário chega
**primeiro** ao UIKit; o estado do SwiftUI só é atualizado depois, e por escrita
assíncrona (escrever em `FocusState` durante uma atualização de view provoca
mutação de estado no meio do ciclo). Existe portanto uma janela em que os dois
lados discordam **legitimamente** — e é nessa janela que o bridge decide errado.

---

## Causa raiz

O defeito não está na funcionalidade que motivou o embrulho (no caso original,
uma máscara de texto). Está em haver **duas fontes de verdade** para o mesmo
estado:

- `FocusState` do SwiftUI;
- `UIResponder` / first responder do UIKit.

Com duas fontes, o bridge só consegue perguntar "eles estão diferentes?" — e essa
pergunta é ambígua: a diferença pode significar "o SwiftUI quer mudar o foco" ou
"o UIKit já mudou e o SwiftUI ainda não sabe". Tratar o segundo caso como se
fosse o primeiro faz o bridge **desfazer** a ação do usuário.

O loop se fecha assim:

```
usuário toca → UIKit vira first responder → delegate avisa
             → escrita assíncrona no estado do SwiftUI
             → atualização de view acontece antes da escrita chegar
             → bridge compara e vê divergência → ordena resignFirstResponder
             → delegate avisa que perdeu foco → nova escrita → ...
```

Cada correção do bridge alimenta a próxima divergência. O sintoma visível é
teclado abrindo e fechando e o campo "não aceitando" o toque; o log do sistema
mostra centenas de conexões/desconexões de teclado por segundo.

---

## Princípio arquitetural

> **O estado de foco deve possuir uma única autoridade.**

O bridge UIKit **sincroniza transições**, não estados. Concretamente:

- guardar o último valor já conciliado entre os dois lados;
- agir **apenas** quando o lado dono (SwiftUI) muda em relação a esse valor —
  *edge-trigger*;
- quando não houve mudança do lado dono, a cadeia de responders é a autoridade e
  o bridge não faz nada, mesmo que os estados pareçam divergentes;
- o caminho inverso (UIKit → SwiftUI) apenas **publica** o que já aconteceu, e
  registra o novo valor de forma síncrona antes da publicação assíncrona, para
  que a própria publicação não seja lida depois como um novo comando.

Por que edge-trigger elimina o loop: um comando só existe quando há **transição**
do lado dono. A divergência temporária causada pela latência da escrita deixa de
ser interpretável como ordem — ela é simplesmente o estado ainda não propagado.
Sem comando espúrio, não há reação; sem reação, não há realimentação. O
level-trigger, ao contrário, transforma toda latência em comando e é, por
construção, um oscilador.

---

## Anti-pattern

Sinalizadores que existem só para silenciar a própria sincronização:

- `isProgrammaticFocusChange`
- `suppressRefocus`
- "ignorar o próximo evento", supressões por `DispatchQueue.main.async`,
  contadores de reentrância e afins.

Essas flags são **cheiro arquitetural**: indicam que não existe autoridade única
sobre o estado. Elas mascaram o loop nos caminhos que alguém lembrou de cobrir e
falham nos demais, além de crescer em número a cada bug novo.

Regra: ao sentir vontade de adicionar mais uma flag desse tipo, parar e
investigar quem é o dono do estado. A correção quase sempre é redefinir a
autoridade e sincronizar transições — o que costuma **remover** flags, não somar.

---

## Recomendações futuras

Para qualquer `UIViewRepresentable` novo ou existente:

- **definir claramente quem é dono do estado** (foco, seleção, texto, scroll) e
  registrar essa decisão junto ao código;
- **sincronizar apenas transições**, nunca reconciliar continuamente;
- **evitar comparação contínua de estado** entre os dois mundos como gatilho de
  ação (`estadoSwiftUI != estadoUIKit` não é um comando);
- **evitar bindings concorrentes** sobre o mesmo estado: um canal de entrada e um
  de saída, não dois canais bidirecionais;
- **manter o bridge idempotente**: publicar valor igual ao atual não pode gerar
  evento nem trabalho;
- **separar sincronização de atualização de UI**: aplicar aparência/conteúdo é
  uma coisa, conciliar estado de foco é outra — misturar as duas na mesma função
  esconde a corrida;
- lembrar que um `Binding` (inclusive `FocusState.Binding`) passado ao
  representable **não invalida** a view: quando a mudança precisa disparar
  atualização, passar valor e receber a notificação por closure;
- cuidar também da **medição**: uma `UIView` embrulhada com content hugging baixo
  aceita a altura proposta pelo container e estica. Se a intenção é "uma linha de
  texto", fixar as prioridades de conteúdo do eixo correspondente — caso
  contrário o componente muda de tamanho por causa de uma feature que só deveria
  mudar texto.

Cobertura mínima de teste ao introduzir um bridge: foco não é republicado quando
já está no valor desejado; transição do lado dono aplica a mudança; sessão real
de uso (digitar, trocar configuração, continuar digitando) preserva valor,
cursor, foco e altura.

---

## Reutilização

Este aprendizado vale para **qualquer componente que faça bridge entre SwiftUI e
UIKit** — não só campos de texto e não só foco. `UIViewRepresentable`,
`UIViewControllerRepresentable`, `UIHostingController` embutido em UIKit e
qualquer ponte com estado compartilhado (seleção, scroll, edição, apresentação
modal) estão sujeitos ao mesmo padrão de falha.

Antes de escrever a sincronização, responder: quem é o dono? O que é comando e o
que é notificação? Se a resposta não for óbvia, o loop já está no projeto.

---

## Referências

- `Sources/BradsCore/Layout/Input/Base/InputTransformedTextField.swift`
- `Sources/BradsCore/Layout/Input/Base/Input+Base.swift`
- `Tests/BdsCoreTests/Components/Inputs/InputTransformedTextFieldTests.swift`
- Contraparte Android: `layout/input/base/InputBase.kt` — no Compose a máscara é
  `VisualTransformation` no próprio `BasicTextField`: mesmo widget, mesma
  medição, foco com dono único.
