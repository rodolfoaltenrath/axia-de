# Backlog de Tasks para Uso de Escritório

Este documento quebra a evolução do Axia-DE em tasks menores, independentes o bastante para implementação incremental.

Objetivo:
- transformar o shell atual em um desktop utilizável para trabalho diário
- priorizar compatibilidade, estabilidade e fluxos reais de escritório
- permitir desenvolvimento por etapas sem perder visão de produto

## Como usar este backlog

Cada task abaixo tenta responder quatro perguntas:
- o que precisa ser entregue
- por que isso importa para uso real
- onde a implementação provavelmente toca no código
- o que conta como "pronto"

Convenção:
- `AX-xxx` = identificador da task
- `P0` = bloqueadora de uso real
- `P1` = muito importante para alpha de escritório
- `P2` = importante, mas pode entrar depois do alpha inicial

---

## Fase 1: Estabilidade da Sessão

### `AX-001` Supervisão de `panel` e `dock`
Prioridade: `P0`

Entregar:
- detectar quando `axia-panel` ou `axia-dock` encerram
- reiniciar automaticamente quando fizer sentido
- evitar spawn duplicado do mesmo componente
- registrar motivo de restart no log

Áreas prováveis:
- `src/core/server.zig`
- `src/panel/process.zig`
- `src/dock/process.zig`

Pronto quando:
- matar `axia-panel` manualmente faz o processo voltar
- matar `axia-dock` manualmente faz o processo voltar
- o compositor continua vivo durante a recuperação
- não surgem processos duplicados após reinícios repetidos

### `AX-002` Supervisão de `launcher` e `app-grid`
Prioridade: `P0`

Entregar:
- subir `launcher` e `app-grid` sob o mesmo modelo de supervisão
- reiniciar os auxiliares quando caírem
- garantir que o core conheça o estado desses processos

Áreas prováveis:
- `src/core/server.zig`
- `src/apps/launcher/process.zig`
- `src/apps/app_grid/`

Pronto quando:
- launcher e app grid não ficam "mortos" após crash
- o shell recupera sem reiniciar a sessão inteira

### `AX-003` Layout inicial previsível da sessão
Prioridade: `P1`

Entregar:
- definir ordem clara de bootstrap da sessão
- garantir estado inicial consistente do painel, dock e wallpaper
- evitar corrida entre socket Wayland, IPC e auxiliares

Áreas prováveis:
- `src/core/server.zig`
- `src/render/wallpaper.zig`
- `src/ipc/server.zig`

Pronto quando:
- três inicializações seguidas produzem a mesma disposição inicial
- painel e dock aparecem sem glitches de startup

### `AX-004` Smoke test manual da sessão
Prioridade: `P1`

Entregar:
- checklist curto de boot, foco, popup, dock, launcher e apps
- roteiro reproduzível para validar regressão

Áreas prováveis:
- `docs/`

Pronto quando:
- existe checklist de validação antes de merge em áreas críticas

---

## Fase 2: Compatibilidade de Desktop

### `AX-005` Suporte a XWayland
Prioridade: `P0`

Entregar:
- inicializar XWayland junto com a sessão
- mapear superfícies X11 para o modelo de views do shell
- foco, mover, redimensionar, minimizar e fechar

Áreas prováveis:
- `src/core/server.zig`
- `src/shell/`
- `src/wl.zig`
- `build.zig`

Pronto quando:
- apps X11 abrem no Axia-DE
- conseguem receber foco e participar das workspaces
- fechar app X11 não deixa estado inválido no compositor

### `AX-006` Clipboard básico Wayland
Prioridade: `P0`

Entregar:
- suporte a copy/paste por data device
- seleção copiada entre apps Wayland
- fluxo mínimo robusto entre apps nativas e externas

Áreas prováveis:
- `src/core/`
- `src/input/`
- `src/shell/`

Pronto quando:
- copiar texto entre duas apps funciona
- copiar de navegador/editor para app nativa funciona

### `AX-007` Primary selection
Prioridade: `P1`

Entregar:
- seleção primária estilo middle-click
- suporte opcional onde fizer sentido

Áreas prováveis:
- mesma base de `AX-006`

Pronto quando:
- selecionar texto em uma app e colar com clique do meio funciona onde suportado

### `AX-008` Drag and drop entre superfícies
Prioridade: `P1`

Entregar:
- base de DnD para arquivos e texto
- integração mínima com `axia-files`

Áreas prováveis:
- `src/core/`
- `src/shell/`
- `src/apps/files/`

Pronto quando:
- arrastar arquivo para uma app compatível funciona
- o compositor não entra em estado inválido ao cancelar DnD

---

## Fase 3: Segurança e Presença de Sessão

### `AX-009` Lockscreen real
Prioridade: `P0`

Entregar:
- tela de bloqueio própria ou fluxo confiável integrado
- lock manual pelo painel
- bloqueio sem vazar interação com apps abaixo

Áreas prováveis:
- `src/panel/app.zig`
- novo módulo em `src/lock/` ou `src/apps/lockscreen/`
- `src/layers/`

Pronto quando:
- bloquear a sessão cobre a tela inteira
- teclado e ponteiro não alcançam apps até desbloquear

### `AX-010` Idle timeout
Prioridade: `P1`

Entregar:
- detectar inatividade
- bloquear após tempo configurável
- resetar o timer em atividade de input

Áreas prováveis:
- `src/input/`
- `src/core/server.zig`
- `src/settings/`

Pronto quando:
- sessão bloqueia após o tempo definido
- movimento de mouse e teclado reiniciam a contagem

### `AX-011` Idle inhibit
Prioridade: `P1`

Entregar:
- respeitar clientes que pedem para inibir idle
- não bloquear a tela durante vídeo, apresentação ou chamada

Áreas prováveis:
- `src/core/`
- `src/shell/`

Pronto quando:
- app com inhibit ativo impede bloqueio automático
- ao fechar a app o comportamento normal volta

---

## Fase 4: Ferramentas de Trabalho Diário

### `AX-012` Screenshot de tela e janela
Prioridade: `P0`

Entregar:
- screenshot de tela inteira
- screenshot de janela focada
- atalho global
- salvar em diretório padrão com notificação

Áreas prováveis:
- `src/core/`
- `src/render/`
- `src/input/`
- `src/notification/`

Pronto quando:
- `Print` salva captura com feedback visual
- existe opção de capturar janela focada

### `AX-013` Área de seleção para screenshot
Prioridade: `P1`

Entregar:
- overlay para selecionar região
- cancelar com `Esc`

Áreas prováveis:
- novo módulo visual em `src/apps/` ou `src/overlay/`
- `src/layers/`

Pronto quando:
- usuário consegue desenhar uma seleção e salvar a captura

### `AX-014` Screencast básico
Prioridade: `P0`

Entregar:
- base de compartilhamento de tela
- exportar fluxo de monitor ou janela

Áreas prováveis:
- `src/core/`
- integração com portal

Pronto quando:
- navegador/app consegue iniciar compartilhamento de tela

### `AX-015` Integração com `xdg-desktop-portal`
Prioridade: `P0`

Entregar:
- caminho mínimo para screenshot e screencast via portal
- compatibilidade com apps que dependem disso

Áreas prováveis:
- integração externa e documentação em `docs/`
- possivelmente módulo de serviço específico depois

Pronto quando:
- apps modernas conseguem pedir screenshot ou screen sharing

---

## Fase 5: Input e Localização

### `AX-016` Layout de teclado configurável
Prioridade: `P0`

Entregar:
- escolher layout e variante
- persistir configuração
- aplicar na inicialização

Áreas prováveis:
- `src/input/manager.zig`
- `src/config/preferences.zig`
- `src/apps/settings/`

Pronto quando:
- usuário troca entre `us`, `br-abnt2` e variantes suportadas
- a configuração persiste após reiniciar

### `AX-017` Repetição de tecla configurável
Prioridade: `P1`

Entregar:
- ajustar repeat rate e repeat delay
- aplicar sem recompilar

Áreas prováveis:
- `src/input/manager.zig`
- `src/apps/settings/`

Pronto quando:
- alterar preferências muda repetição de teclado na sessão

### `AX-018` Localização básica do shell
Prioridade: `P2`

Entregar:
- idioma base do shell
- formato regional de data/hora
- ponto inicial para internacionalização

Áreas prováveis:
- `src/panel/calendar.zig`
- `src/apps/settings/`
- strings espalhadas no shell

Pronto quando:
- data, hora e labels principais respeitam locale selecionado

---

## Fase 6: Gerenciamento de Monitores

### `AX-019` Persistência de resolução, escala e monitor principal
Prioridade: `P0`

Entregar:
- salvar estado de monitores conectados
- reaplicar resolução, escala e principal
- restaurar ao reiniciar a sessão

Áreas prováveis:
- `src/core/output.zig`
- `src/settings/manager.zig`
- `src/apps/settings/`

Pronto quando:
- reconectar monitor preserva preferências conhecidas
- sessão sobe com configuração esperada

### `AX-020` Posicionamento relativo de monitores
Prioridade: `P1`

Entregar:
- escolher disposição esquerda/direita/acima/abaixo
- refletir isso na área de trabalho

Áreas prováveis:
- `src/core/output.zig`
- `src/apps/settings/render.zig`

Pronto quando:
- mover o cursor entre telas respeita layout configurado

### `AX-021` Hotplug robusto
Prioridade: `P1`

Entregar:
- conectar e desconectar monitor sem quebrar painel, dock ou views
- recalcular áreas utilizáveis corretamente

Áreas prováveis:
- `src/core/output.zig`
- `src/layers/manager.zig`
- `src/render/glass/manager.zig`

Pronto quando:
- hotplug não deixa superfícies fora de posição

---

## Fase 7: Apps do Shell para Trabalho Real

### `AX-022` Finalizar aba de monitores em `axia-settings`
Prioridade: `P1`

Entregar:
- substituir placeholder por UI funcional
- mostrar outputs reais e ações suportadas

Áreas prováveis:
- `src/apps/settings/render.zig`
- `src/apps/settings/app.zig`

Pronto quando:
- a página deixa de parecer provisória
- ações principais estão disponíveis

### `AX-023` Finalizar aba de impressoras
Prioridade: `P1`

Entregar:
- listar impressoras detectadas
- exibir estado básico da fila
- abrir fluxo de configuração quando necessário

Áreas prováveis:
- `src/apps/settings/render.zig`
- novo módulo em `src/panel/` ou `src/settings/`

Pronto quando:
- impressoras aparecem na UI
- usuário entende se a impressora está pronta ou com erro

### `AX-024` Integração básica com CUPS
Prioridade: `P1`

Entregar:
- descobrir impressoras locais
- ler fila e estado

Áreas prováveis:
- novo módulo de integração de sistema

Pronto quando:
- o shell consegue consultar informações de impressão sem travar UI

### `AX-025` Melhorias de escritório em `axia-files`
Prioridade: `P1`

Entregar:
- restaurar da lixeira
- ações mais claras de copiar, mover e excluir
- refinamento visual de seleção, toolbar e navegação

Áreas prováveis:
- `src/apps/files/app.zig`
- `src/apps/files/browser.zig`
- `src/apps/files/render.zig`

Pronto quando:
- fluxo de arquivo cobre abrir, mover para lixeira, restaurar e excluir permanente

---

## Fase 8: Shell e UX Operacional

### `AX-026` Atalhos globais de produtividade
Prioridade: `P1`

Entregar:
- `Super+L` para bloquear
- `Print` para screenshot
- atalhos para launcher, app grid e settings

Áreas prováveis:
- `src/input/manager.zig`
- `src/core/server.zig`

Pronto quando:
- atalhos principais funcionam de forma consistente

### `AX-027` Centro de notificações utilizável
Prioridade: `P1`

Entregar:
- histórico simples
- limpar notificações
- diferenciar toast de notificação persistente

Áreas prováveis:
- `src/notification/`
- `src/panel/notifications_popup.zig`
- `src/ipc/server.zig`

Pronto quando:
- mensagens importantes não se perdem após desaparecer o toast

### `AX-028` Status notifier / system tray
Prioridade: `P1`

Entregar:
- suporte básico a ícones de bandeja
- exibir apps comuns de sync, VPN e mensageria

Áreas prováveis:
- `src/panel/`
- integração externa específica

Pronto quando:
- apps compatíveis mostram presença no painel

### `AX-029` Sessão de energia confiável
Prioridade: `P1`

Entregar:
- revisar lock, suspend, reboot e shutdown
- melhorar feedback de erro/sucesso

Áreas prováveis:
- `src/panel/power_popup.zig`
- `src/panel/app.zig`

Pronto quando:
- ações de energia funcionam de forma previsível

---

## Fase 9: Performance e Robustez

### `AX-030` Reduzir polling e redraw desnecessário
Prioridade: `P1`

Entregar:
- revisar loops de painel, dock e apps auxiliares
- reduzir wakeups sem perder responsividade

Áreas prováveis:
- `src/panel/app.zig`
- `src/dock/app.zig`
- `src/apps/app_grid/app.zig`

Pronto quando:
- uso ocioso de CPU cai de forma perceptível

### `AX-031` Revisar robustez de IPC
Prioridade: `P1`

Entregar:
- tratamento melhor de desconexões, payload inválido e timeouts
- logs claros para debugging

Áreas prováveis:
- `src/ipc/server.zig`
- `src/ipc/client.zig`
- `src/panel/ipc.zig`
- `src/dock/ipc.zig`
- `src/apps/settings/ipc.zig`

Pronto quando:
- falhas de IPC não travam a sessão

### `AX-032` Revisar limpeza de recursos do compositor
Prioridade: `P1`

Entregar:
- fechar caminhos de leak e estados pendurados
- robustez ao fechar cliente durante interação

Áreas prováveis:
- `src/shell/xdg.zig`
- `src/shell/view.zig`
- `src/render/`

Pronto quando:
- abrir/fechar muitas janelas não degrada a sessão rapidamente

---

## Ordem Recomendada de Execução

Se a meta for chegar ao primeiro alpha de escritório sem dispersão:

1. `AX-001` Supervisão de `panel` e `dock`
2. `AX-002` Supervisão de `launcher` e `app-grid`
3. `AX-005` Suporte a XWayland
4. `AX-006` Clipboard básico Wayland
5. `AX-009` Lockscreen real
6. `AX-012` Screenshot de tela e janela
7. `AX-015` Integração com `xdg-desktop-portal`
8. `AX-016` Layout de teclado configurável
9. `AX-019` Persistência de monitores
10. `AX-023` Finalizar aba de impressoras
11. `AX-025` Melhorias de escritório em `axia-files`
12. `AX-030` Reduzir polling e redraw desnecessário

---

## Marco de Alpha para Escritório

O Axia-DE entra em um alpha realmente interessante para trabalho quando estes itens estiverem prontos:

- [ ] `AX-001` concluída
- [ ] `AX-002` concluída
- [ ] `AX-005` concluída
- [ ] `AX-006` concluída
- [ ] `AX-009` concluída
- [ ] `AX-012` concluída
- [ ] `AX-015` concluída
- [ ] `AX-016` concluída
- [ ] `AX-019` concluída
- [ ] `AX-023` concluída
- [ ] `AX-025` concluída
- [ ] `AX-030` concluída

---

## Próxima task recomendada

A melhor próxima task para implementação imediata é:

- `AX-001` Supervisão de `panel` e `dock`

Motivo:
- melhora a confiabilidade da sessão sem exigir uma expansão grande do protocolo
- reduz a sensação de fragilidade do desktop
- prepara a base para o restante do shell auxiliar
