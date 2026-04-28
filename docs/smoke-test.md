# Smoke Test de Pre-Alpha

Este roteiro valida se um build do Axia-DE esta pronto para uma rodada pequena de pre-alpha.

## Build

Execute antes de abrir a sessao:

```bash
scripts/prealpha-check.sh
```

Resultado esperado:
- os comandos terminam sem erro
- o script executa `zig build`, `zig build test`, `zig build -Doptimize=ReleaseSafe` e `git diff --check`
- o prefixo temporario contem `axia-de`, `axia-panel`, `axia-dock`, `axia-launcher`, `axia-app-grid`, `axia-files`, `axia-settings` e `axia-session`
- o prefixo temporario contem assets, docs, `.desktop` de apps e `.desktop` da sessao Wayland

Para escolher um prefixo especifico:

```bash
AXIA_PREALPHA_PREFIX=/tmp/axia-prealpha scripts/prealpha-check.sh
```

## Fluxo de desenvolvimento instalado

Para dogfood enquanto edita o repo, use:

```bash
scripts/dev-session.sh
```

Em outro terminal, depois de editar algum componente:

```bash
scripts/dev-restart.sh dock
scripts/dev-restart.sh panel
scripts/dev-restart.sh settings
scripts/dev-restart.sh files
```

Use `scripts/dev-restart.sh compositor` para reinstalar o compositor no prefixo dev; depois reinicie a sessao para carregar essa parte.

## Boot da sessao

1. Inicie em ambiente aninhado com `zig build run`, ou instale em um prefixo temporario com `zig build -p /tmp/axia-prealpha` e rode `/tmp/axia-prealpha/bin/axia-session`.
2. Confirme que o wallpaper aparece.
3. Confirme que painel e dock aparecem sem duplicacao.
4. Espere 10 segundos e observe se a sessao continua responsiva.

## Shell basico

1. Abra o launcher com `Super+Espaco` e `Alt+Espaco`.
2. Abra e feche a app grid com `Super+A`.
3. Abra `axia-files` pelo launcher ou dock.
4. Abra `axia-settings` com `Super+,`.
5. Troque workspaces com `Super+1..4`.
6. Mova uma janela para outra workspace com `Super+Shift+1..4`.
7. Mova e redimensione uma janela com `Super + botao esquerdo/direito`.
8. Arraste uma janela para bordas e cantos para validar snap preview.

## Apps nativas

### Arquivos

1. Abra uma pasta.
2. Crie uma pasta.
3. Renomeie a pasta.
4. Mova para a lixeira.
5. Abra a lixeira.
6. Use `Shift+Delete` em um item de teste para exclusao permanente.

### Configuracoes

1. Troque o wallpaper por um preset.
2. Troque a cor de destaque.
3. Ative e desative segundos/data no painel.
4. Altere tamanho da dock, tamanho dos icones e auto-hide.
5. Feche e reabra `axia-settings`; confirme que as preferencias persistem.

## Painel

1. Abra calendario, notificacoes, energia, bateria, rede, Bluetooth e audio.
2. Confirme que cada popup abre e fecha sem deslocamento estranho.
3. Teste volume/mute quando `wpctl` estiver disponivel.
4. Teste Wi-Fi/Ethernet quando `nmcli` estiver disponivel.
5. Teste Bluetooth quando `bluetoothctl` e `rfkill` estiverem disponiveis.

## Screenshot

1. `Print`: captura tela cheia.
2. `Shift+Print`: captura janela focada.
3. `Super+Print`: captura area com `slurp`.
4. Confirme que um toast informa sucesso ou dependencia ausente.

## Resiliencia

Durante a sessao, em outro terminal:

```bash
pkill -x axia-panel
pkill -x axia-dock
pkill -x axia-launcher
pkill -x axia-app-grid
```

Resultado esperado:
- painel e dock voltam automaticamente
- launcher/app-grid voltam quando ainda estavam solicitados
- o compositor nao encerra
- nao ficam processos duplicados apos repetir o teste

## Criterio para liberar build

Um build pode virar `prealpha.N` quando:
- todos os passos acima passam ou a falha esta documentada em `docs/known-issues.md`
- o README reflete os binarios e dependencias atuais
- o build foi validado em Debug e ReleaseSafe
- a sessao foi testada pelo menos uma vez fora do diretorio do repo
