# Known Issues da Pre-Alpha

Esta lista define limitacoes aceitas para uma rodada de pre-alpha tecnica. Itens aqui nao devem ser apresentados como prontos em notas de release.

## Compatibilidade

- XWayland ainda nao esta implementado; apps X11 nao sao alvo desta pre-alpha.
- `xdg-desktop-portal` ainda nao tem integracao propria; screencast e sharing de tela de apps modernas podem falhar.
- Clipboard existe apenas no nivel basico fornecido pelo data device atual; primary selection e fluxos avancados de DnD ainda nao estao fechados.
- System tray/status notifier ainda nao existe.

## Sessao e seguranca

- `Super+L` chama `loginctl lock-session`, mas o Axia-DE ainda nao possui lockscreen compositor-side propria.
- Idle timeout e idle inhibit ainda nao estao implementados.
- Nao ha fluxo completo de encerramento de sessao com salvamento/restauracao de estado.

## Input e monitores

- Layout de teclado usa o keymap padrao do sistema/wlroots e ainda nao tem UI de configuracao.
- Repeat rate e repeat delay estao fixos no codigo.
- Configuracao persistente de resolucao, escala, monitor principal e layout relativo ainda nao esta pronta.
- Hotplug de monitores precisa de mais validacao.

## Apps do shell

- Paginas de rede, Bluetooth e impressoras em `axia-settings` ainda sao placeholders.
- `axia-files` cobre fluxo basico, mas restauracao da lixeira ainda nao esta implementada.
- Abertura de arquivos depende de `xdg-open` ou `gio open`.

## Dependencias externas

- Audio depende de `wpctl`.
- Rede depende de `nmcli`.
- Bluetooth depende de `bluetoothctl` e `rfkill`.
- Screenshot depende de `grim`; selecao de area depende de `slurp`.
- Conversao de wallpaper nao-PNG depende de `magick`.

## QA

- Ainda nao ha suite automatizada ampla para compositor, renderizacao ou input.
- `zig build test` cobre apenas checks iniciais de release; o smoke test manual continua obrigatorio.
