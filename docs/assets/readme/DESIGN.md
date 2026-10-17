# Jean Dev Environment — sistema visual do README

## Conceito

**Control Center.** O `dev-env` é o núcleo que configura todos os projetos. As ilustrações mostram esse núcleo, os módulos reais do repositório e o que ele entrega a cada projeto, sempre com nomes de arquivos e comandos que existem.

Derivado de: o terminal do próprio projeto (capturas em `assets/*.png`, tema Powerlevel10k configurado por `scripts/mac-dev-setup.sh`): fundo grafite, segmento azul do prompt, verde de status.

## Paleta

| Token | Hex | Papel | Contraste no fundo |
|---|---|---|---|
| graphite | `#121418` | Fundo das ilustrações | — |
| panel | `#1B1E24` | Cartões e painéis | — |
| line | `#2A2F38` | Bordas, divisores | decorativo |
| text | `#ECEFF4` | Texto principal | 16,0 : 1 |
| muted | `#9AA3B2` | Texto secundário | 7,2 : 1 |
| prompt blue | `#7FA2F2` | Acento: núcleo, ligações, segmento `~` | 7,3 : 1 |
| status green | `#8FD19E` | Link criado, resolução para `ai/shared/` | 10,3 : 1 |

Contraste calculado pela fórmula de luminância relativa da WCAG 2.2. No `panel`, o menor valor é 6,6 : 1.

## Tipografia

| Papel | Pilha | Tamanho em 1600 px |
|---|---|---|
| Wordmark `dev-env` | `'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace`, 700, `textLength` fixo | 112 |
| Proposta | `'Helvetica Neue', Helvetica, Arial, 'Segoe UI', Roboto, 'Liberation Sans', sans-serif`, 600 | 40 |
| Caminhos e comandos | Pilha mono | 13–16 |
| Legendas | Pilha sans, 400 | 14–21 |

## Forma e linha

- Moldura com raio 24 px, margem externa 80 px, régua do cabeçalho em y = 94–98.
- O segmento de prompt (`~` em azul, com ponta de seta) é a marca do projeto.
- Linha azul contínua: ação do CLI. Linha verde tracejada: resolução dos symlinks. Caixa tracejada cinza: opcional ou ainda inexistente.
- Grade de pontos a 32 px, branco a 6% de opacidade.

## Movimento

- Só no `hero.svg`: o núcleo assenta, módulos e ligações acendem, o cartão do projeto desliza e os três ✓ ganham cor em sequência; termina em 2,8 s, sem repetição.
- Todo elemento é visível desde o primeiro quadro (nada parte de opacidade 0). As animações ficam dentro de `@media (prefers-reduced-motion: no-preference)`.
- `hero-still.svg` é gerado a partir do `hero.svg` (blocos `<!-- motion:start -->` / `<!-- motion:end -->`) com o validador do [Premium README Template](https://github.com/jeancarlosaps/premium-readme-template): `node validate-readme.mjs . --write-stills`. Não edite o still à mão.

## Arquivos

| Arquivo | Mostra | Atualizar quando |
|---|---|---|
| `hero.svg` / `hero-still.svg` | Núcleo, módulos do repositório, links do perfil `default`, o que o `init` configura | Mudarem os links do perfil `default`, os módulos ou os passos do `init` |
| `architecture.svg` | Repositório → `dev-env project` → projeto | Mudar o comportamento de `project`, o manifesto ou a estrutura de diretórios |
