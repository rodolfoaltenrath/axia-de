# Plano Técnico: Glassmorphism Compartilhado

## Objetivo

Transformar o documento de visão em um plano de implementação real para o `axia-de`, com um efeito de glassmorphism compartilhado entre:

- `top-bar`
- `dock`

Nesta fase, o efeito deve nascer no compositor e ser reutilizado pelos dois componentes.

## Estado Atual do Projeto

Hoje o projeto está dividido assim:

- compositor com `wlroots` e `wlr_scene`
- `top-bar` como cliente separado
- `dock` como cliente separado
- desenho visual de `panel` e `dock` via Cairo

Arquivos-chave já existentes:

- [build.zig](/home/altenrath/axia-de/build.zig)
- [src/core/server.zig](/home/altenrath/axia-de/src/core/server.zig)
- [src/core/output.zig](/home/altenrath/axia-de/src/core/output.zig)
- [src/render/scene.zig](/home/altenrath/axia-de/src/render/scene.zig)
- [src/panel/render.zig](/home/altenrath/axia-de/src/panel/render.zig)
- [src/dock/render.zig](/home/altenrath/axia-de/src/dock/render.zig)

Conclusão prática:

- o blur real precisa entrar no compositor
- o acabamento de vidro continua no cliente

## Meta do MVP

Entregar um blur real funcional e barato, aplicado primeiro na `top-bar` e depois reaproveitado na `dock`, com estas regras:

- blur compositor-side
- apenas regiões fixas
- baixo custo em GPU integrada
- atualização por dano
- estilo compartilhado entre os dois

## Estratégia Técnica

### Camada 1: Estilo Compartilhado

Criar um módulo para descrever o efeito visual unificado.

Arquivo sugerido:

- [src/render/glass/style.zig](/home/altenrath/axia-de/src/render/glass/style.zig)

Responsabilidades:

- definir tipos de superfície de vidro
- definir presets visuais de `top-bar` e `dock`
- definir níveis de qualidade

Estrutura sugerida:

```zig
pub const GlassKind = enum {
    top_bar,
    dock,
};

pub const GlassQuality = enum {
    low,
    balanced,
    high,
};

pub const GlassStyle = struct {
    downsample_factor: u8,
    blur_radius: f32,
    corner_radius: f32,
    tint_rgba: [4]f32,
    border_rgba: [4]f32,
    highlight_rgba: [4]f32,
    noise_opacity: f32,
};
```

### Camada 2: Região e Ciclo de Vida

Criar um módulo para registrar regiões de blur compartilhadas.

Arquivo sugerido:

- [src/render/glass/region.zig](/home/altenrath/axia-de/src/render/glass/region.zig)

Responsabilidades:

- representar uma região de vidro por output
- armazenar bounds
- armazenar estado de invalidação
- guardar cache do resultado do blur

Estrutura sugerida:

```zig
pub const GlassRegion = struct {
    kind: GlassKind,
    output: [*c]c.struct_wlr_output,
    box: c.struct_wlr_box,
    dirty: bool,
    enabled: bool,
    style: GlassStyle,
};
```

### Camada 3: Pipeline do Blur

Criar o módulo que executa o blur compositor-side.

Arquivo sugerido:

- [src/render/glass/pipeline.zig](/home/altenrath/axia-de/src/render/glass/pipeline.zig)

Responsabilidades:

- recortar a área atrás da região
- fazer downsample
- aplicar blur horizontal/vertical ou kawase
- devolver textura final reutilizável

Observação importante:

O objetivo da primeira versão não é criar um framework genérico de pós-processamento do compositor inteiro. O objetivo é resolver `2` regiões fixas com um pipeline controlado.

### Camada 4: Orquestração

Criar um manager central para o efeito.

Arquivo sugerido:

- [src/render/glass/manager.zig](/home/altenrath/axia-de/src/render/glass/manager.zig)

Responsabilidades:

- registrar `top-bar` e `dock`
- atualizar bounds quando layout mudar
- marcar regiões como dirty quando houver dano atrás delas
- disparar recomposição do blur
- expor API simples para o compositor

API sugerida:

```zig
pub fn registerRegion(self: *GlassManager, kind: GlassKind, output: [*c]c.struct_wlr_output, box: c.struct_wlr_box) !void
pub fn updateRegion(self: *GlassManager, kind: GlassKind, output: [*c]c.struct_wlr_output, box: c.struct_wlr_box) void
pub fn markDamage(self: *GlassManager, output: [*c]c.struct_wlr_output, damage: c.struct_wlr_box) void
pub fn render(self: *GlassManager, output: [*c]c.struct_wlr_output) void
```

## Integração com o Código Atual

### 1. Scene Manager

Arquivo:

- [src/render/scene.zig](/home/altenrath/axia-de/src/render/scene.zig)

Mudança:

- adicionar uma árvore dedicada para efeitos de vidro ou overlays do compositor

Sugestão:

```zig
glass_effect_tree: [*c]c.struct_wlr_scene_tree,
```

Posição sugerida na ordem da scene:

- fundo
- bottom layer
- janelas
- efeitos de vidro
- top layer
- overlay layer

Isso permite compor o blur atrás de `top-bar` e `dock`, mas ainda abaixo dos próprios clientes.

### 2. Server

Arquivo:

- [src/core/server.zig](/home/altenrath/axia-de/src/core/server.zig)

Mudanças:

- criar `GlassManager`
- injetar dependências de renderer/scene/output layout
- repassar eventos de output/layout para o manager

Campos sugeridos:

```zig
glass: GlassManager,
```

### 3. Output

Arquivo:

- [src/core/output.zig](/home/altenrath/axia-de/src/core/output.zig)

Mudanças:

- no `frame`, deixar o glass manager validar e atualizar caches quando necessário
- associar regiões por output

Ponto de entrada mais natural:

- `renderFrame()`

### 4. Layer Layout

Arquivo provável:

- [src/core/server.zig](/home/altenrath/axia-de/src/core/server.zig)
- integração indireta com `LayerManager`

Mudanças:

- quando `top-bar` ou `dock` mudarem de tamanho/posição, atualizar os bounds da região de vidro correspondente

Regra:

- a região do blur deve acompanhar a geometria real da surface layer-shell

## Reuso entre Top-Bar e Dock

O compartilhamento não deve ser só “visual”; deve ser também arquitetural.

Os dois componentes devem usar:

- o mesmo `GlassKind`
- o mesmo `GlassManager`
- o mesmo pipeline
- estilos derivados do mesmo módulo

Diferenças permitidas:

- `corner_radius`
- intensidade do tint
- raio do blur
- opacidade do noise

## Papel dos Clientes

Mesmo com blur no compositor, ainda vale manter refinamentos em:

- [src/panel/render.zig](/home/altenrath/axia-de/src/panel/render.zig)
- [src/dock/render.zig](/home/altenrath/axia-de/src/dock/render.zig)

Esses arquivos continuam responsáveis por:

- pintura translúcida final
- borda interna
- highlight
- acabamento visual

Mas devem parar de tentar “simular” blur pesado.

## Ordem de Implementação

### Etapa 1: Infra

Criar:

- `src/render/glass/style.zig`
- `src/render/glass/region.zig`
- `src/render/glass/manager.zig`

Objetivo:

- fechar tipos
- registrar regiões
- integrar ao `Server`

### Etapa 2: MVP na Top-Bar

Arquivos principais:

- [src/core/server.zig](/home/altenrath/axia-de/src/core/server.zig)
- [src/core/output.zig](/home/altenrath/axia-de/src/core/output.zig)
- [src/render/scene.zig](/home/altenrath/axia-de/src/render/scene.zig)
- novo `pipeline.zig`

Objetivo:

- blur real só atrás da `top-bar`
- cache por output
- atualização só com dano

Critério de pronto:

- `top-bar` com blur real estável
- sem degradação perceptível de input/frame pacing

### Etapa 3: Reuso na Dock

Arquivos principais:

- mesmos da etapa anterior
- eventual ajuste em [src/dock/render.zig](/home/altenrath/axia-de/src/dock/render.zig)

Objetivo:

- plugar `dock` no mesmo pipeline
- validar convivência com hover, preview e indicadores da dock

Critério de pronto:

- `dock` com blur igual em linguagem visual
- sem engasgo ao abrir ou focar apps

### Etapa 4: Polimento

Objetivo:

- ruído fino compartilhado
- highlight consistente
- borda interna refinada
- toggle de qualidade, se necessário

## Performance e Guardrails

Regras obrigatórias:

- nunca usar CPU para fazer o blur
- nunca copiar textura para RAM e devolver para GPU
- nunca recalcular blur completo sem dano atrás da região
- começar com `balanced`

Fallbacks recomendados:

- se a região estiver inválida, mostrar só tint translúcido
- se a qualidade cair demais, usar blur mais curto
- se o backend não suportar o caminho completo, desativar o blur real e manter acabamento visual

## Critérios de Aceite

### MVP

- `top-bar` com blur real
- `dock` com blur real
- efeito compartilhado entre ambos
- visual consistente
- sem impacto forte perceptível ao mover janelas atrás

### Pronto para expansão

- estrutura reaproveitável para menus e popups
- estilo centralizado
- invalidação por região
- integração limpa no compositor

## Próximo Passo Recomendado

Começar pela `Etapa 1`, criando a infraestrutura mínima:

- `style.zig`
- `region.zig`
- `manager.zig`

Depois disso, atacar só a `top-bar` primeiro.
