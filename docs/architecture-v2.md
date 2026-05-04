# Arquitetura V2 do Axia-DE

## Objetivo

Este documento define a arquitetura alvo da proxima base do `Axia-DE`.

A intencao nao e evoluir a shell atual escrita em Zig como se ela fosse o
produto final. A intencao e:

- manter o compositor como nucleo em `Zig + wlroots`
- mover shell visual para clientes Wayland separados
- usar protocolos Wayland e servicos de desktop como fronteira de integracao
- reduzir retrabalho antes da fase "usavel"

Em termos praticos:

- compositor continua responsavel por input, output, renderer, foco,
  workspaces, scene graph, policy de janelas e protocolos
- shell passa a ser composta por processos externos
- a stack principal da shell sera `Astal` com `GTK4` e `AGS`
- features exclusivas do Axia devem ser opcionais e nao obrigar acoplamento

## Principios

### 1. O compositor e o core do sistema

Tudo que define o comportamento do desktop mora no compositor:

- gerenciamento de superficies
- foco e ativacao
- workspaces
- output layout
- lock de sessao
- screencopy
- policy de blur compositor-side

### 2. A shell e cliente, nao modulo interno

Painel, launcher, notificacoes, OSDs, settings e lock screen devem ser
processos separados.

Eles conversam com o compositor por:

- protocolos Wayland padrao
- protocolos custom opcionais quando realmente necessario
- D-Bus para servicos que nao sao naturalmente surface-centric

### 3. Process boundary e feature, nao gambiarra

A fronteira de processo existe para:

- preservar a simplicidade e o desempenho do core em Zig
- permitir shell declarativa com GTK4/Astal sem contaminar o compositor
- reduzir o custo de reiniciar a shell durante desenvolvimento
- evitar que falhas da UI derrubem o compositor

### 4. O shell deve degradar bem fora do Axia

Idealmente a shell deve funcionar em qualquer compositor que expose:

- `xdg-shell`
- `layer-shell`
- `xdg-activation`
- `foreign-toplevel`
- `ext-workspace`
- `output-management`

Quando algum protocolo nao existir:

- o modulo correspondente deve desaparecer ou entrar em modo reduzido
- a shell nao deve falhar no startup

### 5. Features exclusivas precisam ser opcionais

Blur, metadata extra de shell, hooks visuais e qualquer refinamento exclusivo
do Axia devem ser:

- opt-in
- capability-driven
- isolados em protocolos ou servicos proprios pequenos

## Estado Atual e Direcao de Reescrita

Hoje a base mistura:

- compositor Wayland em Zig
- shell parcial em processos separados
- bastante UI ainda escrita "na unha"
- IPC textual ad-hoc entre componentes

Essa base nao deve ser migrada diretamente.

### O que reaproveitar

- `src/core/server.zig` como referencia do bootstrap geral
- `src/input/*` como base de input e seat
- `src/shell/xdg.zig` como base do gerenciador de janelas
- `src/layers/*` como base de `layer-shell`
- `src/render/scene.zig` e estruturas de scene/output
- parte da modelagem de workspaces e foco

### O que tratar como legado

- `src/panel/*`
- `src/dock/*`
- `src/apps/*`
- `src/ipc/*` como contrato principal da shell
- pipeline atual de glass baseado principalmente em wallpaper

Esses modulos ainda podem servir como:

- referencia de UX
- referencia de layout
- base para assets e heuristicas

Mas nao devem ditar a nova arquitetura.

## Estrutura de Modulos Proposta

```text
src/
  main.zig

  compositor/
    app.zig
    server.zig
    lifecycle.zig

  backend/
    backend.zig
    renderer.zig
    allocator.zig
    session.zig

  protocols/
    registry.zig
    core.zig
    xdg_shell.zig
    layer_shell.zig
    decorations.zig
    shm.zig
    linux_dmabuf.zig
    viewporter.zig
    xdg_output.zig
    fractional_scale.zig
    cursor_shape.zig
    presentation.zig
    xdg_activation.zig
    foreign_toplevel.zig
    ext_foreign_toplevel_list.zig
    output_management.zig
    screencopy.zig
    session_lock.zig
    idle_notify.zig
    idle_inhibit.zig
    primary_selection.zig
    data_control.zig
    ext_workspace.zig
    custom/
      axia_blur_unstable_v1.xml
      axia_blur.zig

  desktop/
    scene.zig
    outputs.zig
    output_layout.zig
    workspaces.zig
    seats.zig
    focus.zig
    idle.zig
    session_lock_state.zig

  shell/
    xdg_manager.zig
    layer_manager.zig
    view.zig
    toplevel_handle.zig
    workspace_model.zig
    activation.zig

  input/
    manager.zig
    keyboard.zig
    pointer.zig
    cursor.zig
    constraints.zig
    gestures.zig

  render/
    scene_graph.zig
    output_frame.zig
    damage.zig
    blur/
      manager.zig
      pipeline.zig
      kawase.zig
      region.zig
      policy.zig

  services/
    notifications.zig
    screenshots.zig
    outputs.zig
    session.zig

  compat/
    xwayland.zig

  util/
    log.zig
    geometry.zig
    listeners.zig
```

## ProtocolRegistry

O compositor deve ter um registro central de protocolos.

Objetivos:

- concentrar criacao de globals
- evitar `wlr_*_create()` espalhado
- deixar claro o que e "helper wlroots" e o que tem policy propria
- facilitar testes e migracoes

Esboco:

```zig
pub const ProtocolRegistry = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    renderer: [*c]c.struct_wlr_renderer,
    seat: [*c]c.struct_wlr_seat,
    output_layout: [*c]c.struct_wlr_output_layout,

    core: CoreProtocols,
    xdg_shell: XdgShellProtocol,
    layer_shell: LayerShellProtocol,
    decorations: DecorationProtocol,

    shm: ShmProtocol,
    linux_dmabuf: LinuxDmabufProtocol,
    viewporter: ViewporterProtocol,
    xdg_output: XdgOutputProtocol,
    fractional_scale: FractionalScaleProtocol,
    cursor_shape: CursorShapeProtocol,
    presentation: PresentationProtocol,

    xdg_activation: XdgActivationProtocol,
    foreign_toplevel: ForeignToplevelProtocol,
    ext_foreign_toplevel_list: ExtForeignToplevelListProtocol,
    output_management: OutputManagementProtocol,
    screencopy: ScreencopyProtocol,
    session_lock: SessionLockProtocol,
    idle_notify: IdleNotifyProtocol,
    idle_inhibit: IdleInhibitProtocol,
    primary_selection: PrimarySelectionProtocol,
    data_control: DataControlProtocol,
    ext_workspace: ExtWorkspaceProtocol,
};
```

Regra:

- `protocols/*` registram globals e requests
- `desktop/*` guarda o estado canonico
- `shell/*` conecta state do compositor com surfaces e toplevels

## Comunicacao Com a Shell

### Wayland primeiro

Use Wayland para tudo que estiver naturalmente ligado a:

- `wl_surface`
- `wl_output`
- `wl_seat`
- foco
- ativacao
- workspaces
- toplevels
- layer surfaces

### D-Bus para servicos

Use D-Bus para:

- notificacoes desktop
- energia
- sessao
- rede
- bluetooth
- audio
- launchers de apps
- settings backend

### Evitar socket proprio como API principal

O socket textual atual pode continuar como ferramenta de debug temporaria,
mas nao deve ser o contrato principal da shell nova.

## Shell V2

O shell deve ser dividida em processos claros:

- `axia-shell`
  - bar
  - launcher
  - notifications
  - OSDs
  - taskbar
  - workspace switcher
- `axia-settings`
  - configuracao de monitores
  - preferencias visuais
  - preferencias de shell
- `axia-lock`
  - lock screen
  - fluxo de unlock

### Porque separar `axia-lock`

Lock screen tem exigencias diferentes:

- precisa usar `ext-session-lock`
- precisa dominar todos os outputs
- nao pode depender de estado fragil da shell
- precisa continuar segura mesmo com o resto da shell reiniciando

## Blur

### Decisao

Adotar dois niveis:

- primeiro blur automatico compositor-side restrito a superficies da shell
- depois protocolo explicito opcional para refinamento

### O que isso significa

No MVP:

- cliente so precisa usar translucencia real
- compositor decide quando aplicar blur
- policy inicial restrita a superficies conhecidas da shell

Depois:

- protocolo `axia_blur_unstable_v1` pode permitir regioes seletivas
- blur continua opcional e capability-based

### Nao fazer

- blur real no cliente
- blur global para todas as janelas arbitrarias logo no inicio
- pipeline final baseado apenas em wallpaper

## Milestones Arquiteturais

### M1: Core de protocolos

- `ProtocolRegistry`
- `wl_shm`
- `linux_dmabuf`
- `viewporter`
- `xdg_output`
- `fractional_scale`
- `cursor_shape`

### M2: Shell protocols

- `xdg_activation`
- `foreign_toplevel_management`
- `output_management`
- `screencopy`
- `idle_notify`
- `idle_inhibit`

### M3: Sessao funcional

- `session_lock`
- `ext_workspace`
- shell canario com clientes reais

### M4: Shell propria

- `axia-shell`
- `axia-settings`
- `axia-lock`
- blur compositor-side

## Definition of Done

Uma feature nova so esta pronta quando:

- existe cliente real usando
- existe smoke test repetivel
- o comportamento sobrevive a restart da shell
- o compositor continua estavel sem depender da shell antiga

## Nao Fazer Agora

- nao portar a shell atual widget por widget
- nao inventar mega protocolo custom de shell
- nao colocar blur em janelas arbitrarias
- nao prender a shell a um socket textual proprio
- nao gastar tempo em polimento visual antes da sessao canario existir
