# Roadmap do Axia-DE

## Objetivo
Este roadmap define o que precisa estar pronto para iniciar um `teste alpha` real do Axia-DE.

Para um backlog mais detalhado e orientado a execução, veja:
- [docs/office-readiness-tasks.md](office-readiness-tasks.md)

O foco aqui nao e "ter todas as ideias do produto prontas".
O foco e chegar num ponto em que:
- a sessao inicializa de forma confiavel
- os componentes principais do shell funcionam juntos
- o fluxo basico de uso diario existe
- os bugs restantes sao toleraveis para teste controlado
- a experiencia e coerente o bastante para receber feedback real

---

## Criterio de entrada para alpha
O Axia-DE entra em alpha quando estes criterios estiverem atendidos:

- sessao inicia sem depender de gambiarras manuais
- painel, dock, launcher e grade de aplicativos funcionam sem travar ou quebrar a sessao
- gerenciamento basico de janelas esta confiavel
- configuracoes principais do shell sao persistidas
- `axia-files` cobre o fluxo basico de arquivos
- rede, audio, bluetooth, bateria e energia estao usaveis no painel
- feedback visual do sistema esta coerente
- os principais bugs visuais e de performance do shell foram reduzidos
- existe um fluxo minimo de teste repetivel para validar regressao

---

## Estado atual resumido
Hoje o projeto ja tem uma base forte:

- compositor Wayland funcional
- painel superior
- dock com auto-hide, preview e glassmorphism
- central de configuracoes funcional
- `axia-files` com abrir, criar pasta, renomear, excluir e lixeira
- audio, bluetooth, rede, bateria e energia no painel
- notificacoes e toasts basicos
- grade de aplicativos em implementacao inicial
- glass compositor-side para `top-bar` e `dock`

O que falta agora e transformar esse conjunto em uma experiencia estavel de alpha.

---

## Bloco 1: Shell Critico
Estas features sao bloqueadoras de alpha.

### 1. Sessao e inicializacao
- garantir spawn confiavel de `panel`, `dock`, `launcher` e `app-grid`
- evitar duplicacao de processos do shell
- melhorar recuperacao quando um processo auxiliar cair
- garantir que a sessao suba com layout inicial previsivel

### 2. Gerenciamento de janelas
- revisar foco entre janelas, launcher e grade de aplicativos
- finalizar comportamento de minimizar, restaurar e focar pela dock
- revisar snapping e preview de encaixe
- validar comportamento com multiplas workspaces
- corrigir casos em que surfaces especiais ficam em estado estranho ao abrir/fechar

### 3. Dock
- estabilizar completamente o auto-hide
- garantir que o glass acompanhe a dock sem artefatos
- fechar bugs de hover, foco e apps abertas
- consolidar o botao fixo da grade de aplicativos
- impedir regressao visual quando houver apps maximizadas ou fullscreen

### 4. Grade de aplicativos
- terminar a feature como modulo independente
- limitar a lista a aplicativos relevantes para usuario final
- remover launchers tecnicos, applets e entradas de configuracao
- deixar abertura instantanea e sem congelamento perceptivel
- implementar comportamento de toggle limpo pelo botao da dock
- lapidar busca, scroll e foco por teclado

### 5. Painel superior
- revisar alinhamento e consistencia visual dos popups
- garantir que audio, rede, bluetooth, bateria e energia estejam estaveis
- padronizar toggles e interacoes
- fechar glitches visuais e de posicionamento

---

## Bloco 2: Fluxo Basico de Uso
Estas features sao essenciais para o usuario conseguir realmente usar a alpha.

### 6. Arquivos
- revisar o fluxo de lixeira
- validar `Shift+Delete` para exclusao permanente
- melhorar visual e consistencia do `axia-files`
- fechar bugs de scroll, selecao e toolbar
- decidir se havera restauracao da lixeira ja na alpha ou so depois

### 7. Configuracoes
- finalizar a aba `Dock`
- revisar persistencia e aplicacao em tempo real das preferencias
- consolidar paginas principais:
  - aparencia
  - papel de parede
  - painel superior
  - monitores
  - areas de trabalho
  - dock
- remover textos, labels e fluxos provisiorios que ainda soam como prototipo

### 8. Launcher
- validar busca, favoritos e recentes
- garantir que launchers tecnicos nao poluam o resultado
- revisar foco, navegação por teclado e abertura
- manter coerencia com a grade de aplicativos

### 9. App Grid
- definir papel da grade versus launcher
- grade = exploracao visual de apps
- launcher = abertura rapida por busca/teclado
- garantir que os dois coexistam sem duplicar comportamento de forma confusa

---

## Bloco 3: Polimento Visual e UX
Estas features nao sao bloqueadoras absolutas, mas elevam muito a qualidade do alpha.

### 10. Glassmorphism do shell
- consolidar glass compartilhado em componentes fixos do shell
- validar performance do efeito em uso real
- expandir depois para:
  - popups do painel
  - launcher
  - grade de aplicativos
- evitar aplicar blur generico em janelas arbitrarias na alpha

### 11. Consistencia visual
- revisar icones do painel
- revisar titlebars e chrome das janelas nativas
- padronizar espacos, sombras, bordas e raios
- revisar empty states
- revisar indicadores de app aberta/focada na dock

### 12. Feedback visual
- manter toasts para fluxos transacionais
- consolidar centro de notificacoes
- revisar quando usar toast e quando usar notificacao persistente
- melhorar mensagens de erro e sucesso em acoes do sistema

---

## Bloco 4: Estabilidade e Performance
Esses itens separam um prototipo bonito de uma alpha testavel.

### 13. Performance do shell
- reduzir congelamentos ao abrir surfaces especiais
- revisar custo de loading de catalogo e icones
- validar comportamento da dock e do painel em maquinas reais
- reduzir redraw desnecessario
- revisar frequencia de polling e sincronizacao via IPC

### 14. Robustez do compositor
- revisar caminhos criticos de preview, glass e snap
- melhorar tratamento de erro no IPC
- evitar estados invalidos quando cliente fecha durante interacao
- revisar limpeza de recursos e buffers

### 15. Resiliencia dos processos
- supervisionar `panel`, `dock`, `launcher` e `app-grid`
- reiniciar componentes quando apropriado
- evitar que uma falha auxiliar derrube a experiencia inteira

---

## Bloco 5: Preparacao para Teste Alpha
Esses itens fecham a transicao de desenvolvimento para teste controlado.

### 16. Ambiente de teste
- definir fluxo de boot do Axia-DE para teste real
- testar fora de outra DE completa sempre que possivel
- separar o que e gargalo do Axia-DE e o que e interferencia do ambiente hospedeiro

### 17. QA minimo
- montar checklist de smoke test da sessao
- abrir e fechar apps
- testar dock, painel, launcher e app grid
- testar workspaces
- testar configuracoes principais
- testar `axia-files`
- testar audio, rede, bluetooth, bateria e energia

### 18. Documentacao de alpha
- instrucoes de execucao
- lista do que funciona
- lista do que ainda e experimental
- roteiro de teste para feedback
- forma de reportar bugs

---

## Ordem recomendada
Esta e a ordem que mais faz sentido para chegar no alpha sem dispersao:

1. estabilizar `dock`
2. finalizar `grade de aplicativos`
3. revisar `launcher`
4. consolidar `painel superior`
5. fechar fluxo principal do `axia-files`
6. revisar `configuracoes`
7. corrigir gargalos de performance do shell
8. adicionar resiliencia dos processos
9. montar checklist de QA
10. iniciar rodada de alpha

---

## Antes do alpha
Checklist final:

- [ ] dock estavel
- [ ] app grid estavel
- [ ] launcher estavel
- [ ] painel estavel
- [ ] `axia-files` utilizavel
- [ ] configuracoes principais prontas
- [ ] audio, rede, bluetooth, bateria e energia confiaveis
- [ ] gerenciamento basico de janelas confiavel
- [ ] glass do shell sem artefatos graves
- [ ] sem travamentos perceptiveis nas acoes principais
- [ ] sem duplicacao estranha de processos do shell
- [ ] smoke test documentado

---

## Depois do alpha
Itens importantes, mas que podem esperar:

- restaurar itens da lixeira
- recursos avancados de monitores
- bluetooth com pareamento completo
- menu rapido/control center mais rico
- mais personalizacao visual do shell
- glass em mais superficies
- onboarding/welcome app
- empacotamento e distribuicao mais refinados

---

## Backlog Detalhado

O roadmap acima continua sendo a visao macro.

Para implementar por tasks menores, com prioridade, criterio de pronto e ordem sugerida, use:

- [docs/office-readiness-tasks.md](office-readiness-tasks.md)
