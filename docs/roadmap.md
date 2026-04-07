# Axia-DE Roadmap

## Fase 1: Core Boot
- `build.zig` funcional e stack linkada
- `wl_display`, backend, renderer e allocator inicializados
- loop principal do Wayland em execução

## Fase 2: Outputs
- listener de `new_output`
- configuracao do modo preferido
- `wl_output` global criado
- loop de `frame` ativo
- fundo solido renderizado via `wlr_render_pass`

## Fase 3: Input Base
- `wlr_seat` criado
- listener de `new_input`
- teclado com keymap padrao
- `Escape` encerra o compositor de forma limpa

## Fase 4: Pointer
- registrar ponteiros no `seat`
- capacidades dinamicas de teclado e ponteiro
- cursor basico e movimento

## Fase 5: Shell de Janelas
- `xdg_shell` inicial
- map/unmap de superficies
- foco de teclado e ponteiro
- renderizacao de views simples
- maximize/fullscreen/minimize basicos
- inicio de interacao por `request_move/request_resize`

## Fase 6: Layout e UX
- clique no fundo limpa foco
- movimento e resize interativos das janelas
- layout basico, gaps e areas de trabalho
- animacoes e efeitos visuais incrementais

## Fase 7: Ecossistema DE
- `wlr-layer-shell`
- painel, dock e launcher em modulos dedicados
- protocolos auxiliares do desktop

## Proximas Iteracoes
- manager de `layer-shell` integrado ao compositor
- surfaces de layer conectadas na scene graph
- `axia-panel` separado com auto-spawn pelo compositor
- barra superior inicial com relogio central e popup de calendario
- botao `Aplicativos` como launcher minimo para `alacritty`
- validar drag de mover via barra do cliente
- validar resize pelos cantos/bordas do cliente
- corrigir restauracao visual de janelas minimizadas
- criar o primeiro painel/top bar do Axia-DE em modulo proprio
- expandir o `axia-files` com acoes utilitarias pendentes: nova pasta, renomear e excluir
