# Contratos Minimos

## Shell -> Compositor

A shell nova deve assumir apenas estes contratos obrigatorios:

- `xdg-shell`
- `layer-shell`
- `xdg-activation-v1`
- `wlr-foreign-toplevel-management`
- `ext-workspace-v1`
- `wlr-output-management`
- `ext-session-lock-v1`

## Shell -> Servicos de Desktop

Usar D-Bus para:

- notificacoes
- energia e sessao
- rede
- bluetooth
- audio

## Regras

- nenhuma dependencia de IPC textual legado
- features exclusivas do Axia devem ser opcionais
- ausencia de protocolo opcional nao pode impedir startup
