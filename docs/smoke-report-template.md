# Relatorio de Smoke Test

Build:
- commit:
- tag candidata:
- prefixo instalado:
- data:
- testador:

## Resultado

- [ ] Aprovado para publicar pre-alpha
- [ ] Aprovado com known issues documentadas
- [ ] Reprovado, precisa de correcoes antes da publicacao

## Build Automatizado

- [ ] `scripts/prealpha-check.sh` passou
- [ ] smoke headless da sessao instalada passou
- [ ] prefixo instalado foi testado fora do diretorio do repo

Notas:

## Boot da Sessao

- [ ] wallpaper aparece
- [ ] painel aparece uma unica vez
- [ ] dock aparece uma unica vez
- [ ] sessao segue responsiva apos 10 segundos

Notas:

## Shell Basico

- [ ] launcher abre com `Super+Espaco`
- [ ] launcher abre com `Alt+Espaco`
- [ ] app grid abre e fecha com `Super+A`
- [ ] `axia-files` abre
- [ ] `axia-settings` abre
- [ ] workspaces trocam com `Super+1..4`
- [ ] janela move para workspace com `Super+Shift+1..4`
- [ ] `Super + botao esquerdo` move janela
- [ ] `Super + botao direito` redimensiona janela
- [ ] snap preview aparece em bordas e cantos
- [ ] janela maximizada volta para floating ao arrastar pela barra
- [ ] snap preserva geometria floating anterior
- [ ] maximizar/restaurar janela encaixada volta para geometria floating anterior

Notas:

## Apps Nativas

- [ ] Files navega entre pastas
- [ ] Files cria pasta
- [ ] Files renomeia item
- [ ] Files move item de teste para lixeira
- [ ] Files executa exclusao permanente de item de teste
- [ ] Settings troca wallpaper por preset
- [ ] Settings troca cor de destaque
- [ ] Settings altera painel
- [ ] Settings altera dock
- [ ] preferencias persistem apos reabrir Settings

Notas:

## Painel

- [ ] calendario abre e fecha
- [ ] notificacoes abre e fecha
- [ ] energia abre e fecha
- [ ] bateria abre e fecha ou mostra ausencia de bateria sem quebrar
- [ ] rede abre e fecha
- [ ] Bluetooth abre e fecha
- [ ] audio abre e fecha
- [ ] popups nao aparecem deslocados ou cortados

Notas:

## Screenshot

- [ ] `Print` captura tela cheia ou informa dependencia ausente
- [ ] `Shift+Print` captura janela focada ou informa dependencia ausente
- [ ] `Super+Print` captura area ou informa dependencia ausente
- [ ] toasts de sucesso/falha aparecem corretamente

Notas:

## Resiliencia

- [ ] `pkill -x axia-panel` faz painel voltar
- [ ] `pkill -x axia-dock` faz dock voltar
- [ ] `pkill -x axia-launcher` nao quebra compositor
- [ ] `pkill -x axia-app-grid` nao quebra compositor
- [ ] repetir o teste nao deixa processos duplicados

Notas:

## Bugs Encontrados

1.

## Known Issues a Documentar

1.

## Decisao

Proxima acao:
- [ ] corrigir bugs e repetir smoke
- [ ] atualizar `docs/known-issues.md`
- [ ] mover tag local para o commit aprovado
- [ ] publicar branch e tag
