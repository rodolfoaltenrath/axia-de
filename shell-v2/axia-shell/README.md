# axia-shell

Responsabilidade:

- bar
- launcher
- notifications
- OSDs
- taskbar
- workspace switcher

Entrada prevista:

- processo principal da shell V2
- iniciado por comando externo em `scripts/axia-dev-session`

Regras:

- capability detection no startup
- sem assumir protocolo exclusivo do Axia
- degradar para modo reduzido fora do compositor Axia
