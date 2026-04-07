# Glassmorphism no Axia-DE

## Objetivo

Implementar um efeito de glassmorphism real no `axia-de`, começando apenas por:

- `top-bar`
- `dock`

O efeito deve ser visualmente consistente entre os dois, ter custo baixo o bastante para GPUs integradas e virar uma base reaproveitável para outros componentes no futuro.

## Escopo Inicial

Entram nesta primeira fase:

- blur real atrás da `top-bar`
- blur real atrás da `dock`
- acabamento compartilhado de vidro: `tint`, `noise`, borda interna e highlight
- atualização com cache e damage tracking

Não entram nesta fase:

- blur em janelas comuns
- blur em menus e popups
- blur global do desktop
- blur por software via CPU/Cairo

## Princípio Central

O blur real não deve ser implementado dentro de [src/panel/render.zig](/home/altenrath/axia-de/src/panel/render.zig) nem [src/dock/render.zig](/home/altenrath/axia-de/src/dock/render.zig).

Esses módulos podem continuar desenhando:

- transparência
- bordas
- highlights
- ruído

Mas o desfoque real deve ser produzido no compositor, porque só ele conhece o conteúdo que está atrás dessas surfaces.

Os pontos naturais para isso hoje são:

- [src/core/server.zig](/home/altenrath/axia-de/src/core/server.zig)
- [src/core/output.zig](/home/altenrath/axia-de/src/core/output.zig)
- [src/shell/xdg.zig](/home/altenrath/axia-de/src/shell/xdg.zig)

## Arquitetura Proposta

### 1. Efeito Compartilhado

Criar uma base única do efeito, conceitualmente algo como:

```zig
pub const GlassKind = enum {
    top_bar,
    dock,
};

pub const GlassStyle = struct {
    blur_radius: f32,
    downsample_factor: u8,
    tint_rgba: [4]f32,
    border_rgba: [4]f32,
    highlight_rgba: [4]f32,
    noise_opacity: f32,
    corner_radius: f32,
};
```

Essa base define o visual e o custo do efeito. `top-bar` e `dock` usam o mesmo pipeline, mudando apenas dimensões, raio de canto e intensidade.

### 2. Responsabilidades

Compositor:

- capturar a região atrás da surface
- reduzir a resolução
- aplicar blur em GPU
- cachear o resultado
- invalidar só quando houver dano real atrás da surface

Cliente `panel` e cliente `dock`:

- desenhar a casca do vidro
- aplicar o preenchimento translúcido
- desenhar ruído fino e borda interna
- manter o layout e os controles

### 3. Pipeline do Blur

Para cada região de vidro:

1. descobrir a área real ocupada pela `top-bar` ou `dock`
2. capturar somente a área atrás dela
3. fazer `downsample` para `1/4` ou `1/8`
4. aplicar blur separável horizontal + vertical, ou `kawase blur`
5. reutilizar esse resultado enquanto o fundo não mudar
6. compor o resultado final antes da surface cliente

## Estratégia de Performance

Para manter o custo baixo:

- limitar o blur apenas a `top-bar` e `dock`
- usar `downsample_factor = 4` como padrão inicial
- recalcular blur apenas em regiões com dano
- não fazer leitura GPU -> CPU -> GPU
- não atualizar o blur se nada se moveu atrás da região

Perfil inicial sugerido:

- `top-bar`: blur mais leve, porque é uma faixa longa
- `dock`: blur um pouco mais forte, porque a área é menor e mais “hero”

## Acabamento Visual Compartilhado

Mesmo com blur real, o “efeito vidro” depende do acabamento. O pacote visual compartilhado entre `top-bar` e `dock` deve ter:

- `tint` escuro translúcido
- highlight superior sutil
- borda interna clara de 1px
- ruído muito leve, entre `0.02` e `0.05`
- sombra mínima ou nenhuma, para não pesar

Referência de linguagem visual:

- discreto
- nítido
- sem excesso de opacidade leitosa
- com legibilidade acima do efeito

## Contrato de Reuso

O sistema deve ser pensado desde o começo para servir depois a:

- menus do painel
- launcher
- popups de áudio, bluetooth, rede e bateria
- future control center

Para isso, a parte compartilhada deve nascer com:

- estilo único do efeito
- enum de tipos de superfície
- invalidação por região
- política de qualidade configurável

## Estratégia de Qualidade

Criar três níveis internos de qualidade:

- `low`
- `balanced`
- `high`

Sugestão inicial:

- `low`: downsample `8x`, blur curto
- `balanced`: downsample `4x`, padrão
- `high`: downsample `2x`, mais caro

O Axia-DE pode começar em `balanced`.

## Ordem de Implementação

### Etapa 1

- criar o documento e fechar o contrato do efeito
- definir o estilo compartilhado do vidro

### Etapa 2

- implementar blur compositor-side só para `top-bar`
- validar custo e dano

### Etapa 3

- aplicar o mesmo pipeline à `dock`
- alinhar o acabamento visual entre os dois

### Etapa 4

- extrair a base compartilhada como infraestrutura reutilizável
- preparar expansão para menus e popups

## Regras de UX

- a `top-bar` deve continuar legível em qualquer wallpaper
- a `dock` deve continuar com ícones nítidos e contraste consistente
- o vidro não pode reduzir a clareza dos ícones, texto e indicadores
- se necessário, a camada translúcida deve priorizar legibilidade em vez de “efeito”

## Decisão Técnica Recomendada

Para o `axia-de`, a direção recomendada é:

- blur real no compositor
- acabamento visual nos clientes
- efeito compartilhado entre `top-bar` e `dock`
- expansão posterior para outras superfícies

Em outras palavras:

`top-bar` e `dock` não devem “inventar” seus próprios blurs. Os dois devem consumir o mesmo efeito base.

## Próximo Passo

Depois deste documento, a próxima implementação deve ser:

- criar a infraestrutura do blur compartilhado no compositor
- aplicar primeiro na `top-bar`
- depois reaproveitar na `dock`
