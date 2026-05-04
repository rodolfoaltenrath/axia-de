# Scripts

Esta pasta vai receber os comandos de desenvolvimento da shell V2.

Enquanto a shell GTK ainda nao tem binario proprio, a sessao pode ser iniciada
com um comando externo usando:

```bash
AXIA_EXTERNAL_SHELL_CMD='seu-comando-aqui' ./scripts/axia-dev-session
```

Entrypoints atuais da V2:

```bash
./shell-v2/scripts/run-axia-shell.sh
./shell-v2/scripts/run-axia-dock.sh
./shell-v2/scripts/run-axia-settings.sh
./shell-v2/scripts/run-axia-launcher.sh
./shell-v2/scripts/run-notifications-shell.sh
./shell-v2/scripts/run-shell-suite.sh
```

Observacao:

- `run-shell-suite.sh` agora sobe a `axia-dock` por padrao
- `run-shell-suite.sh` exporta `AXIA_IPC_SOCKET` automaticamente quando `dock` ou `notifications-shell` estao habilitados
- a `axia-shell` principal ja sobe apenas com protocolos Wayland e utilitarios do desktop
- a `axia-dock` continua funcionando sem `AXIA_IPC_SOCKET`, mas usa o socket quando disponivel para preview e glass da dock
- dentro de `scripts/axia-dev-session`, `AXIA_EXTERNAL_SHELL_CMD` e repassado ao compositor; o script nao inicia uma segunda copia da shell
