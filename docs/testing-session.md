# Testing Session V2

## Objetivo

Este documento define um fluxo minimo de teste para a sessao V2 do `Axia-DE`
antes da shell propria em Astal estar pronta.

A ideia e validar o compositor com clientes reais, reduzindo o risco de
descobrir tarde que algum protocolo fundamental ficou incompleto.

## Sessao Canario

Pacote recomendado para a primeira rodada:

- `waybar`
- `fuzzel`
- `mako`
- `swaylock`
- `wlr-randr`
- `grim`
- `slurp`
- `foot`
- algum app GTK4 simples

No contexto de Arch ou CachyOS, a lista de instalacao costuma se parecer com:

```bash
sudo pacman -S --needed \
  waybar fuzzel mako swaylock \
  wlr-randr grim slurp foot
```

Observacao:

- o nome exato de alguns pacotes pode variar por repositorio
- a validacao principal aqui e comportamental, nao de empacotamento

## Bootstrap Manual

Fluxo base:

1. iniciar o compositor
2. exportar `WAYLAND_DISPLAY` correto para a sessao de teste
3. subir os clientes canario manualmente
4. executar o roteiro de smoke test

Exemplo conceitual:

```bash
WAYLAND_DISPLAY=wayland-1 waybar &
WAYLAND_DISPLAY=wayland-1 mako &
WAYLAND_DISPLAY=wayland-1 foot &
```

Quando existir um script dedicado, ele deve virar o entrypoint recomendado:

```bash
./scripts/axia-dev-session
```

O script usa configs locais do repositório em `dev/canary/` para:

- `waybar`
- `mako`
- `fuzzel`

Assim a sessao canario já sobe com um visual coerente com o Axia, sem depender
da configuração global do usuário.

Ele também exporta `AXIA_SHELL_MODE=canary`, desabilitando o spawn automático
da shell Zig legada para que a validação da nova fronteira de processo não
fique misturada com painel e dock antigos.

Quando a shell V2 existir como processo externo, o mesmo script pode subir esse
processo usando:

```bash
AXIA_EXTERNAL_SHELL_CMD='seu-comando-aqui' ./scripts/axia-dev-session
```

Nesse modo, `waybar` e `mako` nao sobem automaticamente.

Exemplo para o bootstrap inicial da shell V2:

```bash
./scripts/axia-dev-session
```

A shell V2 (`axia-shell` + `notifications-shell`) sobe por padrao quando os scripts em `shell-v2/scripts/` estao disponiveis. Para sobrescrever esse comportamento, defina `AXIA_EXTERNAL_SHELL_CMD`.

O comando da shell externa e supervisionado pelo compositor. Se a shell cair
durante a sessao, o compositor tenta reiniciar o processo principal da V2 com
limite de tentativas. O script `axia-dev-session` nao inicia uma copia extra da
shell quando `AXIA_EXTERNAL_SHELL_CMD` esta definido.

Para testar tambem a shell separada de notificacoes:

```bash
AXIA_EXTERNAL_SHELL_CMD='./shell-v2/scripts/run-axia-shell.sh' \
AXIA_V2_NOTIFICATIONS_CMD='./shell-v2/scripts/run-notifications-shell.sh' \
./scripts/axia-dev-session
```

Variaveis uteis do bootstrap GTK atual:

- `AXIA_V2_LAUNCHER_CMD`: sobrescreve o comando usado pelo botao `Aplicativos`
- `AXIA_V2_NOTIFICATIONS_CMD`: sobrescreve o comando usado pelo botao `Notif`

## Matriz de Validacao

### `waybar`

Valida:

- `layer-shell`
- anchor e exclusivity
- geometria por monitor
- comportamento de topo da tela
- parte do fluxo de taskbar quando habilitado

### `fuzzel`

Valida:

- launcher `layer-shell`
- foco de teclado
- `xdg-activation`
- interacao rapida de abrir app

### `mako`

Valida:

- notificacoes
- surfaces auxiliares
- posicionamento visual

### `swaylock`

Valida:

- `ext-session-lock`
- captura correta dos outputs
- takeover real de input

### `wlr-randr`

Valida:

- `wlr-output-management`
- `test/apply`
- hotplug e reconfiguracao

### `grim` + `slurp`

Valida:

- `wlr-screencopy`
- captura de output
- captura de regiao

### `foot`

Valida:

- `xdg-shell`
- foco
- teclado
- clipboard
- comportamento geral de janela normal

## Smoke Test Basico

### A. Startup

Esperado:

- compositor sobe sem crash
- seat e outputs aparecem
- `waybar` ancora no topo corretamente
- `mako` e `fuzzel` iniciam sem erro fatal

Critério de pronto:

- sessao inicia sem ajustes manuais estranhos

### B. Janelas Normais

Passos:

1. abrir `foot`
2. abrir um segundo `foot`
3. alternar foco com mouse
4. alternar foco com teclado, se suportado
5. mover e redimensionar
6. maximizar e restaurar, se houver suporte exposto

Esperado:

- foco coerente
- sem surfaces presas
- sem artefatos visuais graves

### C. Bar e Layer Shell

Passos:

1. subir `waybar`
2. validar ancoragem superior
3. validar reserva de area util
4. abrir janela maximizada
5. verificar se a janela respeita a area da bar

Esperado:

- exclusivity correta
- sem overlap inesperado na area reservada

### D. Launcher e Activation

Passos:

1. subir `fuzzel`
2. abrir um app pelo launcher
3. repetir com app ja aberto

Esperado:

- app novo abre focado
- app existente recebe foco corretamente
- nao ha roubo de foco invalido

### E. Notificacoes

Passos:

1. subir `mako`
2. disparar uma notificacao de teste

Exemplo:

```bash
notify-send "Axia Test" "Smoke test notification"
```

Esperado:

- notificacao aparece
- fecha corretamente
- nao quebra foco da sessao

### F. Screenshots

Passos:

1. executar captura de output com `grim`
2. executar captura de regiao com `slurp`

Esperado:

- ambos funcionam
- imagem final nao sai vazia

### G. Monitores

Passos:

1. listar outputs com `wlr-randr`
2. aplicar escala ou resolucao de teste
3. reverter

Esperado:

- `test/apply` responde corretamente
- geometria se mantem coerente

### H. Lock

Passos:

1. subir `swaylock`
2. validar takeover em todos os outputs
3. tentar interagir com janela por tras
4. desbloquear

Esperado:

- input fica bloqueado
- lock cobre todos os outputs
- unlock devolve a sessao inteira

## Smoke Test de Regressao

Este bloco deve ser repetido sempre que mexer em:

- seat
- focus
- outputs
- protocols
- layer-shell
- session-lock

Checklist curta:

- [ ] startup sem crash
- [ ] `waybar` ancora corretamente
- [ ] `foot` abre e recebe foco
- [ ] `fuzzel` abre app e ativa corretamente
- [ ] `mako` mostra notificacao
- [ ] `grim` captura output
- [ ] `wlr-randr` lista outputs
- [ ] `swaylock` bloqueia e desbloqueia

## Critério de Pronto da Sessao Canario

A sessao canario esta pronta quando:

- todos os clientes acima iniciam
- os fluxos principais funcionam
- nenhum deles exige patch especifico para o Axia
- regressao pode ser detectada com o checklist acima

## Proximos Passos

Depois que esta sessao estiver estavel:

1. substituir `waybar`, `fuzzel` e `mako` por `axia-shell`
2. validar `axia-lock` contra a mesma matriz
3. so entao entrar em blur compositor-side
