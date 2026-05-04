# Matriz de Protocolos da Shell V2

## Objetivo

Esta matriz define quais protocolos o compositor do Axia-DE precisa expor para
uma shell moderna funcionar bem e mostra o estado aproximado da base atual.

Legenda:

- `Atual`: existe algo implementado hoje
- `Novo core`: deve entrar no `ProtocolRegistry` novo
- `Helper wlroots`: existe `wlr_*_create()` ou helper pronto
- `Policy propria`: wlroots ajuda, mas o comportamento real e do compositor

## Core e Compatibilidade Basica

| Protocolo | Necessidade | Atual | Novo core | Helper wlroots | Observacoes |
| --- | --- | --- | --- | --- | --- |
| `wl_compositor` | obrigatorio | sim | sim | sim | ja existe na base atual |
| `wl_subcompositor` | obrigatorio | sim | sim | sim | ja existe na base atual |
| `wl_shm` | obrigatorio | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `zwp_linux_dmabuf_v1` | obrigatorio | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `wl_data_device_manager` | obrigatorio | sim | sim | sim | ja existe, precisa migrar |
| `wl_seat` | obrigatorio | sim | sim | sim | precisa serial e foco corretos |
| `wp_viewporter` | recomendado cedo | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `zxdg_output_manager_v1` | recomendado cedo | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `wp_fractional_scale_manager_v1` | recomendado cedo | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `wp_cursor_shape_manager_v1` | recomendado cedo | sim | sim | sim | registrado no `ProtocolRegistry` V2 e integrado ao seat/cursor |
| `wp_presentation` | recomendado cedo | sim | sim | sim | registrado no `ProtocolRegistry` V2 |

## Janelas e Shell Basica

| Protocolo | Necessidade | Atual | Novo core | Helper wlroots | Observacoes |
| --- | --- | --- | --- | --- | --- |
| `xdg-shell` | obrigatorio | sim | sim | sim | ja existe na base atual |
| `xdg-decoration` | recomendado | sim | sim | sim | ja existe, precisa migrar |
| `wlr-layer-shell` | obrigatorio | sim | sim | sim | ja existe na base atual |
| `xdg-activation-v1` | obrigatorio | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `wlr-foreign-toplevel-management` | obrigatorio para taskbar | sim | sim | sim | registrado no `ProtocolRegistry` V2 e sincronizado com views XDG |
| `ext-foreign-toplevel-list-v1` | opcional | sim | sim | sim | registrado no `ProtocolRegistry` V2 e sincronizado com views XDG |
| `ext-workspace-v1` | fortemente recomendado | sim | sim | nao | vendorizado e integrado manualmente com grupo global de workspaces |

## Outputs, Captura e Sessao

| Protocolo | Necessidade | Atual | Novo core | Helper wlroots | Observacoes |
| --- | --- | --- | --- | --- | --- |
| `wlr-output-management` | obrigatorio para settings | sim | sim | sim | registrado no `ProtocolRegistry` V2 |
| `wlr-screencopy` | obrigatorio para screenshot | sim | sim | sim | registrado no `ProtocolRegistry` V2 para validacao com `grim/slurp` |
| `ext-session-lock-v1` | obrigatorio para lock real | sim | sim | sim | registrado no `ProtocolRegistry` V2 e ligado ao caminho de input |
| `ext-idle-notify-v1` | obrigatorio para idle/lock | sim | sim | sim | registrado no `ProtocolRegistry` V2 e alimentado por teclado e ponteiro |
| `idle-inhibit-unstable-v1` | obrigatorio para comportamento correto | sim | sim | sim | registrado no `ProtocolRegistry` V2 com inibicao baseada em superfícies mapeadas |

## Clipboard, Selecao e Ergonomia

| Protocolo | Necessidade | Atual | Novo core | Helper wlroots | Observacoes |
| --- | --- | --- | --- | --- | --- |
| `primary-selection-unstable-v1` | recomendado | sim | sim | sim | registrado no `ProtocolRegistry` V2 e aceito no seat |
| `wlr-data-control` ou `ext-data-control` | recomendado | sim | sim | sim | registrado no `ProtocolRegistry` V2 e espelhado pelo seat |

## Depois da Sessao Usavel

| Protocolo | Necessidade | Atual | Novo core | Helper wlroots | Observacoes |
| --- | --- | --- | --- | --- | --- |
| `pointer-constraints` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e integrado ao foco/motion do seat |
| `relative-pointer` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e alimentado pelo caminho de motion bruto |
| `keyboard-shortcuts-inhibit` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e integrado ao caminho de atalhos globais |
| `output-power-management` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e aplicando modo on/off em outputs reais |
| `content-type-v1` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e consultado no frame pipeline como hint de low-latency |
| `tearing-control-v1` | depois | sim | sim | sim | registrado no `ProtocolRegistry` V2 e integrado ao frame pipeline para `tearing_page_flip` |

## Protocolos Custom do Axia

Regra geral:

- nao criar protocolo custom antes da hora
- criar apenas para capacidades que sejam naturalmente surface-centric
- versionar desde o primeiro dia

### Candidato real

`axia_blur_unstable_v1`

Uso:
- regioes de blur seletivo
- hints de policy visual
- opcional, nunca obrigatorio para shell basica

### Nao criar agora

- protocolo proprio de workspace
- protocolo proprio de taskbar
- protocolo proprio de launcher
- protocolo proprio de settings

Essas areas ja possuem caminhos melhores com protocolos padrao ou D-Bus.

## Matriz de Validacao por Cliente Real

| Cliente | O que valida |
| --- | --- |
| `waybar` | `layer-shell`, exclusive zone, monitor binding, taskbar em parte |
| `fuzzel` | launcher `layer-shell`, teclado e ativacao |
| `mako` | notificacoes e surfaces auxiliares |
| `swaylock` | `ext-session-lock` |
| `wlr-randr` | `output-management` |
| `grim` + `slurp` | `screencopy` |
| `foot` | `xdg-shell`, foco e clipboard |
| `gtk4-demo` ou app GTK4 simples | `dmabuf`, escala, output, ativacao |

## Sequencia Recomendada

1. compatibilidade basica
2. shell protocols
3. outputs, captura e lock
4. clipboard e ergonomia
5. refinamentos
