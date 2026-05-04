# Shell V2

Esta pasta e a casa canonica da proxima shell do Axia.

Direcao:

- `Astal + GTK4 + AGS`
- processos separados do compositor
- sem dependencia da shell Zig legada

Estrutura planejada:

```text
shell-v2/
  axia-shell/
  axia-settings/
  axia-lock/
  contracts/
  scripts/
```

Nesta primeira rodada, o scaffold e documental e operacional:

- ownership claro
- integracao prevista com a sessao de desenvolvimento
- contratos minimos com o compositor ja registrados

O proximo passo aqui e colocar o primeiro processo visual real para subir via
`scripts/axia-dev-session`.

Entrypoints atuais da V2:

```bash
./shell-v2/scripts/run-axia-shell.sh
./shell-v2/scripts/run-axia-dock.sh
./shell-v2/scripts/run-axia-settings.sh
./shell-v2/scripts/run-axia-launcher.sh
./shell-v2/scripts/run-notifications-shell.sh
./shell-v2/scripts/run-shell-suite.sh
```

O bootstrap atual da barra ja e um `axia-shell` inicial:

- `GTK4`
- `gtk4-layer-shell`
- ancorada no topo
- `exclusive zone` automatica
- relogio vivo
- deteccao automatica de `ext-workspace-v1`, `xdg-activation-v1` e `wlr-foreign-toplevel-management`
- workspaces reais via `ext-workspace-v1`
- lista de janelas real via `wlr-foreign-toplevel-management`
- execucao de launcher e comandos com `xdg-activation`
- taskbar com icone heuristico por app e indicador discreto de estado
- taskbar com resolucao de icone via `.desktop`/`GDesktopAppInfo` quando possivel
- menu contextual de janela por clique secundario
- launcher externo por comando
- sem dependencia de `AXIA_IPC_SOCKET` para a barra principal
- dock V2 com apps abertas via `wlr-foreign-toplevel-management`
- dock V2 no boot padrao da suite V2
- dock V2 sem dependencia de `AXIA_IPC_SOCKET` para abrir, focar e fechar apps, mas usando o socket quando disponivel para preview e glass
- shell de notificacoes separada em `GTK4 + gtk4-layer-shell`
- estado de audio via `wpctl`, com toggle de mute no clique
- menu de energia com acoes reais de sessao

Para subir junto da sessao Axia:

```bash
./scripts/axia-dev-session
```

A sessao de desenvolvimento passa a preferir automaticamente `./shell-v2/scripts/run-shell-suite.sh` quando ele esta disponivel. Para sobrescrever isso, defina `AXIA_EXTERNAL_SHELL_CMD`.

O compositor agora supervisiona o processo principal da shell V2:

- `AXIA_EXTERNAL_SHELL_CMD` e o fallback `run-shell-suite.sh` sao executados pelo compositor
- se a shell sair inesperadamente, o compositor tenta reiniciar com limite de tentativas
- `scripts/axia-dev-session` apenas passa o comando para o compositor, sem iniciar uma segunda copia
