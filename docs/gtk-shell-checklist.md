# Checklist da Shell GTK V2

## Objetivo

Este checklist traduz a migracao da shell V2 para `Astal + GTK4 + AGS` em
entregas pequenas, com criterio de pronto claro.

Ele existe para evitar duas armadilhas:

- ficar preso refinando a shell Zig legada
- iniciar a shell GTK sem um caminho de execucao real

## Estado Atual

- `compositor + protocolos`: avancado
- `shell legada`: ainda e a shell ativa do produto
- `sessao canario`: existe
- `shell GTK/Astal`: ainda nao entrou no codigo

## Fase 1: Bootstrap da Shell V2

- [x] Criar checklist executavel da shell GTK V2
- [x] Criar scaffold versionado para `axia-shell`, `axia-settings` e `axia-lock`
- [x] Criar documento de contratos minimos da shell com o compositor
- [x] Permitir que a sessao de desenvolvimento aceite uma shell externa por comando
- [x] Definir o gerenciador de dependencias da shell V2
- [x] Subir um primeiro `axia-shell` fora do compositor

Criterio de pronto:

- existe pasta canonica para a shell nova
- existe entrypoint de desenvolvimento para shell externa
- existe um primeiro processo visual fora do compositor

## Fase 2: Base Operacional

- [ ] Definir como a shell vai consumir estado: protocolos diretos, D-Bus ou `axia-shell-agent`
- [ ] Implementar capability detection de protocolos no startup
- [x] Definir padrao de restart da shell sem derrubar a sessao
- [ ] Escolher formato de configuracao de desenvolvimento
- [ ] Criar modo `dev` da shell com logs claros

Criterio de pronto:

- shell pode ser iniciada e reiniciada independentemente do compositor

Status atual de resiliencia:

- o compositor supervisiona o comando da shell V2 iniciado por `AXIA_EXTERNAL_SHELL_CMD` ou pelo fallback `run-shell-suite.sh`
- se o processo principal da shell V2 cair, o compositor tenta reiniciar com backoff curto
- loops de crash sao limitados para evitar reinicio infinito durante desenvolvimento
- `scripts/axia-dev-session` deixa o compositor gerenciar a shell externa, evitando duplicacao de processos

## Fase 3: Modulos Visuais Minimos

- [~] Bar em GTK/Astal
- [~] Dock em GTK/Astal
- [~] Launcher em GTK/Astal
- [ ] Notifications/OSD em GTK/Astal
- [ ] Tema inicial coerente com o vidro atual do Axia
- [ ] Fallback gracioso quando protocolos opcionais nao existirem

Criterio de pronto:

- `waybar`, `fuzzel` e `mako` deixam de ser necessarios para o fluxo principal

Status atual da bar:

- existe uma top-bar inicial em `GTK4 + gtk4-layer-shell`
- ainda nao esta em `Astal`
- ja valida processo externo, layer-shell, exclusive zone e layout base
- agora detecta protocolos automaticamente, sem depender do toggle `AXIA_V2_ENABLE_SHELL_PROTOCOLS`
- `Aplicativos` ja aciona launcher externo por comando/env com `xdg-activation`
- `Audio` ja reflete `wpctl` e alterna mute no clique
- `Power` ja abre menu real com `Travar`, `Encerrar Sessao`, `Suspender`, `Reiniciar` e `Desligar`
- `Notif` ja consegue abrir uma shell GTK separada de notificacoes

## Fase 4: Estado da Sessao

- [~] Taskbar via `wlr-foreign-toplevel-management`
- [~] Workspaces via `ext-workspace-v1`
- [ ] Activation/focus via `xdg-activation-v1`
- [ ] Integracao com servicos de desktop via D-Bus

Criterio de pronto:

- abrir, focar, fechar e alternar workspaces funciona pela shell nova

Status atual do estado de sessao:

- a top-bar V2 ja lista workspaces por `ext-workspace-v1`
- a top-bar V2 ja lista janelas por `wlr-foreign-toplevel-management`
- a barra principal ja opera sem `AXIA_IPC_SOCKET` para workspaces e taskbar
- a dock V2 ja opera sem `AXIA_IPC_SOCKET` para abrir, focar e fechar apps
- clique em workspace ja envia `activate + commit`
- clique em janela ja envia `activate` e restaura janela minimizada
- a taskbar da V2 ja mostra icone por `.desktop` quando possivel e fallback heuristico
- a taskbar da V2 ja mostra indicador visual de estado
- clique secundario em janela ja abre menu com ativar, minimizar, maximizar, tela cheia e fechar
- ainda falta evoluir isso para a shell final e cobrir menus/acoes mais ricas

Status atual de notificacoes:

- existe um processo `notifications-shell` separado em `GTK4 + gtk4-layer-shell`
- ele le o `AXIA_IPC_SOCKET`, mostra cards e permite alternar DND

## Fase 5: Lock e Settings

- [ ] `axia-lock` como processo separado
- [~] `axia-settings` como app separado
- [ ] Outputs via `wlr-output-management`
- [ ] Idle -> lock
- [ ] Hotplug durante lock

Criterio de pronto:

- shell nova cobre a sessao "usavel" de ponta a ponta

## Fase 6: Refinamento

- [ ] Blur compositor-side opcional por capability
- [ ] Polimento visual final
- [ ] Remocao gradual da shell legada
- [ ] Smoke tests repetiveis com shell V2

## Primeira Execucao Recomendada

O primeiro bloco que vale executar agora e:

1. scaffold da shell V2
2. comando de sessao para shell externa
3. documento de contratos
4. primeiro `axia-shell`

Este bloco foi iniciado nesta rodada.

Decisao atual:

- bootstrap inicial em `C + GTK4 + gtk4-layer-shell`
- migracao para `Astal/AGS` continua sendo o alvo da shell final
- esse bootstrap existe para validar processo externo, layer-shell e linguagem visual
