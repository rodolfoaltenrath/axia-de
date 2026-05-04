# Axia-DE

> Ambiente desktop e compositor Wayland escrito do zero em Zig, com foco em modularidade, identidade visual própria e evolução incremental do shell.

## Visão Geral

O `Axia-DE` é um desktop environment experimental construído sobre `wlroots`, com uma arquitetura separada por domínios do sistema. A proposta do projeto é evoluir o shell aos poucos, mantendo controle sobre compositor, painel, dock, launcher e apps nativas.

Hoje o projeto já vai além de um protótipo visual: ele possui fluxo real de sessão, apps integradas, configurações persistidas, popups do sistema e recursos de shell como preview de janelas, encaixe por arrasto e efeitos de vidro na top bar e na dock.

## Destaques Atuais

### Shell e compositor

- compositor Wayland com `wl_display`, backend, renderer, allocator e scene graph
- suporte a `xdg-shell` e `layer-shell`
- gerenciamento de saídas, input de teclado e ponteiro
- workspaces com troca, ciclo e movimentação de janelas
- mover e redimensionar janelas com `Super + mouse`
- snap preview ao arrastar janelas para topo, metades e cantos
- mini preview de apps abertas na dock

### Interface do sistema

- top bar com efeito glassmorphism real
- dock V2 em `GTK4 + gtk4-layer-shell`, fixa, com preview, reorder e preferências persistidas
- launcher com descoberta dinâmica de apps via `.desktop`
- recentes e favoritos persistidos
- ícones reais na dock e no launcher

### Painel e controles do sistema

- popup de calendário
- controle de áudio com volume, mute e troca de dispositivo
- popup de Bluetooth com toggle e conexão de dispositivos
- popup de rede com Wi‑Fi/Ethernet
- indicador de bateria condicional para notebooks
- menu de energia com bloquear, sair, suspender, reiniciar e desligar

### Apps nativas

- `axia-files`
  - navegação por pastas
  - seleção visual
  - abertura com app padrão
  - rolagem e barra de scroll
- `axia-settings`
  - aparência
  - painel superior
  - monitores
  - áreas de trabalho
  - dock
  - wallpaper com fluxo interno

## Arquitetura

O projeto é organizado por domínio para facilitar evolução e manutenção:

```text
src/core/      bootstrap do compositor, outputs e servidor principal
src/input/     teclado, ponteiro e atalhos
src/shell/     xdg-shell, views, workspaces, snapping e previews
src/layers/    integração com layer-shell
src/render/    scene graph, wallpaper e efeitos visuais
src/apps/      files, settings e apps nativas restantes em Zig
src/config/    preferências persistidas e estado local
src/ipc/       comunicação entre compositor e componentes do shell
src/protocols/ bootstrap dos protocolos Wayland do compositor
shell-v2/      top bar, dock, launcher, power e shells GTK da V2
protocols/     XMLs vendorizados dos protocolos Wayland
docs/          roadmap, notas técnicas e planejamento
```

## Binários Gerados

Ao compilar, o projeto instala estes componentes principais:

- `axia-de`
<<<<<<< HEAD
- `axia-panel`
- `axia-dock`
- `axia-launcher`
- `axia-app-grid`
=======
>>>>>>> 4b191f5 (refactor: migra shell para arquitetura V2 externa)
- `axia-files`
- `axia-settings`

## Requisitos

Ambiente recomendado:

- CachyOS / Arch Linux
- Zig `0.15.x`
- `wlroots 0.18`
- sessão Wayland para testes aninhados

Pacotes principais no Arch/CachyOS:

```bash
sudo pacman -S --needed \
  zig base-devel pkgconf \
  wlroots0.18 wayland wayland-protocols \
  libxkbcommon pixman mesa libinput seatd cairo
```

Pacotes úteis para os recursos atuais do shell:

```bash
sudo pacman -S --needed \
  networkmanager bluez bluez-utils rfkill \
  pipewire wireplumber \
  ghostty firefox code grim slurp imagemagick
```

Observação:

- áudio usa `wpctl`
- rede usa `nmcli`
- Bluetooth usa `bluetoothctl` e `rfkill`
- ações de sessão usam `loginctl` e `systemctl`
- screenshot usa `grim`
- selecao de area usa `slurp`
- conversao de wallpaper nao-PNG usa `magick`

## Compilação

```bash
zig build
```

Checks recomendados antes de abrir uma build para teste:

```bash
scripts/prealpha-check.sh
```

O script roda build Debug, testes, build `ReleaseSafe`, `git diff --check`, instala a release em um prefixo temporario e sobe uma sessao headless curta para validar binarios, assets, docs, metadados `.desktop`, output, painel e dock.

Para preparar o smoke visual manual com relatorio preenchivel:

```bash
AXIA_PREALPHA_PREFIX=/tmp/axia-prealpha-manual scripts/prepare-manual-smoke.sh
```

O build tambem instala assets e metadados de sessao no prefixo:

```text
share/axia-de/assets/
bin/axia-session
share/wayland-sessions/axia-de.desktop
share/applications/axia-files.desktop
share/applications/axia-settings.desktop
share/doc/axia-de/
```

## Desenvolvimento instalado

Para testar uma sessao instalada sem tocar em `/usr`, use um prefixo temporario:

```bash
scripts/dev-install.sh
scripts/dev-session.sh
```

Por padrao isso usa `/tmp/axia-dev`. Para escolher outro prefixo:

```bash
AXIA_DEV_PREFIX=/tmp/meu-axia-dev scripts/dev-session.sh
```

Enquanto a sessao esta aberta, edite o repo normalmente e reinicie componentes individuais:

```bash
scripts/dev-restart.sh dock
scripts/dev-restart.sh panel
scripts/dev-restart.sh settings
scripts/dev-restart.sh files
```

`panel` e `dock` sao supervisionados pelo compositor e voltam automaticamente depois do `pkill`. Mudancas em `axia-de` exigem reiniciar a sessao:

```bash
scripts/dev-restart.sh compositor
```

## Execução

Para rodar o Axia-DE dentro da sua sessão Wayland atual:

```bash
zig build run
```

Isso inicia o compositor e sobe os componentes do shell necessários para a sessão.

Também é possível rodar componentes isolados durante desenvolvimento:

```bash
zig build run-panel
zig build run-dock
zig build run-launcher
zig build run-app-grid
zig build run-files
zig build run-settings
```

## Wallpaper

Wallpaper padrão:

```text
assets/wallpapers/axia-aurora.png
```

Para sobrescrever na execução:

```bash
AXIA_WALLPAPER=/caminho/para/wallpaper.png zig build run
```

Em builds instalados, os assets sao procurados em `share/axia-de/assets` relativo ao prefixo. Durante desenvolvimento, `assets/` no repositorio continua funcionando. Para sobrescrever o diretorio de assets:

```bash
AXIA_ASSET_DIR=/caminho/para/assets axia-de
```

## Atalhos

### Teclado

- `Escape`: encerra o Axia-DE
- `Super+1..4`: troca de workspace
- `Super+Shift+1..4`: move a janela focada para outra workspace
- `Super+Tab`: cicla entre workspaces
- `Super+Espaço`: abre o launcher
- `Alt+Espaço`: abre o launcher
- `Super+A`: abre ou fecha a grade de aplicativos
- `Super+,`: abre Configurações
- `Super+L`: bloqueia a sessão
- `Print`: salva screenshot em `~/Pictures/Screenshots`, `~/Imagens/Screenshots` ou `~/Screenshots`
- `Shift+Print`: salva screenshot da janela focada
- `Super+Print`: abre seleção de área para screenshot

### Mouse

- `Super + botão esquerdo`: mover janela
- `Super + botão direito`: redimensionar janela
- arrastar para bordas/cantos: snap preview e encaixe

## Estado do Projeto

O `Axia-DE` está em fase de prototipação avançada, caminhando para um ciclo de testes `pré-alpha/alpha`. A base principal do shell já existe, mas o projeto ainda está em evolução rápida, com ajustes frequentes de UX, polimento visual e comportamento do compositor.

Em outras palavras: já é um projeto usável para desenvolvimento e experimentação, mas ainda não é um ambiente “finalizado”.

## Roadmap

O roadmap vivo do projeto está em:

- [docs/roadmap.md](docs/roadmap.md)
- [docs/office-readiness-tasks.md](docs/office-readiness-tasks.md)
- [docs/smoke-test.md](docs/smoke-test.md)
- [docs/known-issues.md](docs/known-issues.md)

Documentos técnicos relacionados:

- [docs/glassmorphism.md](docs/glassmorphism.md)
- [docs/glassmorphism-plan.md](docs/glassmorphism-plan.md)
- [docs/architecture-v2.md](docs/architecture-v2.md)
- [docs/backlog-v2.md](docs/backlog-v2.md)
- [docs/gtk-shell-checklist.md](docs/gtk-shell-checklist.md)
- [docs/protocol-matrix.md](docs/protocol-matrix.md)
- [docs/testing-session.md](docs/testing-session.md)

## Filosofia do Projeto

O objetivo do Axia-DE não é apenas “subir um compositor”, mas construir um shell com identidade própria:

- base técnica controlada em Zig
- arquitetura modular
- integração forte entre compositor e apps do shell
- espaço para experimentar UX de desktop sem depender de um stack monolítico

## Observações

- painel e dock são processos separados do compositor
- boa parte do shell conversa por IPC com o core da sessão
- o projeto prioriza recursos reais do desktop antes de polimento absoluto
- mudanças visuais e comportamentais ainda acontecem com bastante frequência
