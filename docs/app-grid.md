# Grade de Aplicativos

`axia-app-grid` e a tela dedicada de todos os aplicativos do Axia-DE.

Objetivo:
- manter a dock enxuta e estavel
- abrir uma grade de aplicativos separada pelo botao fixo de `9 pontos`
- evitar acoplamento com o render e a animacao da dock

Arquivos principais:
- `src/apps/app_grid/app.zig`
- `src/apps/app_grid/model.zig`
- `src/apps/app_grid/render.zig`
- `src/apps/app_grid/icons.zig`

Comportamento atual:
- abre por clique no botao da direita da dock
- mostra todos os apps em grade
- pesquisa por nome, comando, palavras-chave e subtitulo
- aceita clique e `Enter` para abrir
- fecha ao abrir um aplicativo ou ao pressionar `Esc`
