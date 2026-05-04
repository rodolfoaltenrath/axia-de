# Backlog V2 do Axia-DE

## Objetivo

Este backlog traduz a arquitetura V2 em trabalho executavel.

A prioridade geral e:

1. compatibilidade de sessao
2. shell canario
3. shell propria
4. lock robusto
5. blur e refinamentos

## Epico 0: Reset Arquitetural

Objetivo:
- parar de empurrar a base antiga para a direcao errada

Issues:
- `E0-01` Congelar shell Zig atual como legado de referencia
- `E0-02` Definir fronteiras oficiais entre compositor, shell e servicos
- `E0-03` Remover dependencias do caminho critico na shell antiga
- `E0-04` Criar checklist de smoke test da sessao
- `E0-05` Registrar o que sera reaproveitado e o que sera descartado

Criterio de pronto:
- compositor sobe sem depender da shell antiga
- existe documento curto de fronteiras e ownership

## Epico 1: ProtocolRegistry Novo

Objetivo:
- criar a nova base de protocolos do compositor

Issues:
- `E1-01` Criar `src/protocols/registry.zig`
- `E1-02` Migrar `wl_compositor`, `wl_subcompositor`, `wl_data_device_manager`
- `E1-03` Migrar `layer-shell`
- `E1-04` Migrar `xdg-shell`
- `E1-05` Migrar `xdg-decoration`
- `E1-06` Adicionar `wl_shm`
- `E1-07` Adicionar `linux-dmabuf`
- `E1-08` Adicionar `viewporter`
- `E1-09` Adicionar `xdg-output`
- `E1-10` Adicionar `fractional-scale`
- `E1-11` Adicionar `cursor-shape`
- `E1-12` Adicionar `presentation-time`
- `E1-13` Adicionar `xdg-activation`
- `E1-14` Adicionar `foreign-toplevel-management`
- `E1-15` Adicionar `output-management`
- `E1-16` Adicionar `screencopy`
- `E1-17` Adicionar `session-lock`
- `E1-18` Adicionar `idle-notify`
- `E1-19` Adicionar `idle-inhibit`
- `E1-20` Adicionar `primary-selection`
- `E1-21` Adicionar `data-control`
- `E1-22` Vendorizar e integrar `ext-workspace-v1`

Criterio de pronto:
- globals deixam de ser criados de forma espalhada
- todos os protocolos da fase aparecem no registry

## Epico 2: Policy e Integracao de Estado

Objetivo:
- ligar os protocolos ao estado real do compositor

Issues:
- `E2-01` Publicar estado atual de outputs em `output-management`
- `E2-02` Implementar fluxo `test/apply` de configuracao de outputs
- `E2-03` Criar handles de toplevel para janelas mapeadas
- `E2-04` Atualizar title, app_id, activated, minimized, maximized e fullscreen
- `E2-05` Implementar requests de taskbar: activate, close, maximize, minimize
- `E2-06` Publicar workspaces em `ext-workspace-v1`
- `E2-07` Implementar `workspace activate`
- `E2-08` Integrar `xdg-activation` com seat, serial e foco
- `E2-09` Integrar `idle-notify` ao loop de input
- `E2-10` Respeitar `idle-inhibit`
- `E2-11` Integrar `session-lock` por output
- `E2-12` Bloquear input corretamente durante lock

Criterio de pronto:
- clientes reais refletem o estado do compositor sem IPC textual

## Epico 3: Shell Canario

Objetivo:
- validar a sessao com clientes prontos antes da shell propria

Pacote canario:
- `waybar`
- `fuzzel`
- `mako`
- `swaylock`
- `wlr-randr`
- `grim` + `slurp`

Issues:
- `E3-01` Criar script `axia-dev-session`
- `E3-02` Config minima de `waybar`
- `E3-03` Config minima de `fuzzel`
- `E3-04` Config minima de `mako`
- `E3-05` Config minima de `swaylock`
- `E3-06` Smoke test manual de startup
- `E3-07` Smoke test manual de taskbar e workspaces
- `E3-08` Smoke test manual de lock
- `E3-09` Smoke test manual de outputs e screencopy

Criterio de pronto:
- sessao "minimamente usavel" existe sem shell Axia propria

## Epico 4: Shell Propria em Astal

Objetivo:
- substituir o pacote canario por shell propria sem reabrir a arquitetura

Issues:
- `E4-01` Criar repositorio ou pasta da shell V2
- `E4-02` Criar `axia-shell`
- `E4-03` Criar `axia-settings`
- `E4-04` Criar `axia-lock`
- `E4-05` Bar em Astal
- `E4-06` Launcher em Astal
- `E4-07` Notifications e OSDs em Astal
- `E4-08` Taskbar via `foreign-toplevel`
- `E4-09` Workspace switcher via `ext-workspace`
- `E4-10` Capability detection de protocolos
- `E4-11` Integracao com servicos via D-Bus
- `E4-12` Definir se sera necessario `axia-shell-agent`

Criterio de pronto:
- `waybar`, `fuzzel` e `mako` deixam de ser necessarios

## Epico 5: Sessao, Lock e Robustez

Objetivo:
- fechar o ciclo de sessao usavel

Issues:
- `E5-01` `axia-lock` cobre todos os outputs
- `E5-02` Unlock real e seguro
- `E5-03` Hotplug durante lock
- `E5-04` Idle -> lock
- `E5-05` Recuperacao quando shell cai
- `E5-06` Menu de energia e sessao
- `E5-07` Reinicio da shell sem derrubar compositor
- `E5-08` Logs e diagnostics basicos

Criterio de pronto:
- sessao continua funcional mesmo com falha de processo auxiliar

## Epico 6: Blur e Refinamento Visual

Objetivo:
- atingir a direcao visual "frosted glass" sem destruir performance

Issues:
- `E6-01` Reescrever manager de blur para operar sobre conteudo composto
- `E6-02` Definir policy de blur automatico restrito a shell
- `E6-03` Implementar blur GPU com dual Kawase
- `E6-04` Implementar cache por output e regiao
- `E6-05` Implementar damage tracking de backdrop
- `E6-06` Tratar geometria, output scale e hotplug
- `E6-07` Tornar blur opcional por capability
- `E6-08` Protocolo opcional `axia_blur_unstable_v1`

Criterio de pronto:
- painel, launcher e popups usam blur estavel sem recompor a tela inteira

## Ordem Recomendada

1. `E0`
2. `E1`
3. `E2`
4. `E3`
5. `E4`
6. `E5`
7. `E6`

## Primeiros 10 Tickets

1. Criar `src/protocols/registry.zig`
2. Migrar protocolos ja existentes para o registry
3. Adicionar `wl_shm`
4. Adicionar `linux_dmabuf`
5. Adicionar `viewporter`
6. Adicionar `xdg_output`
7. Adicionar `fractional_scale`
8. Adicionar `cursor_shape`
9. Criar script da sessao canario
10. Criar `docs/testing-session.md`

## Definition of Done

Uma issue nova so esta pronta quando:

- existe teste com cliente real
- existe criterio de regressao claro
- nao depende da shell antiga
- se aplica, sobrevive a restart da shell

## O que Nao Fazer Agora

- nao portar widgets da shell antiga para Astal um por um
- nao gastar tempo com theming da shell canario
- nao implementar blur global em qualquer janela
- nao fazer protocolo custom para tudo
- nao usar o socket textual atual como integracao definitiva
- nao tratar lock screen como overlay comum
