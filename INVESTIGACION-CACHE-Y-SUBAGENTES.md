# Investigación conjunta iOS + Android (8-oct): caché de hilos y acceso a subagentes

La parte de Android está en `~/ghosty-android/docs/investigacion-conjunta-ios-android.md`.
Lo marcado **[inf]** es inferencia, no viene de una fuente.

## A. Caché local
- **Mensajes por chat:** ninguna app de mensajería los limita de entrada.
  - iMessage borra por antigüedad («Conservar mensajes»), no por uso. Fuentes: [HowToGeek](https://www.howtogeek.com/710714/how-to-automatically-delete-old-text-messages-on-iphone-or-ipad/), [Macworld](https://www.macworld.com/article/672217/how-to-delete-all-old-messages-from-iphone.html).
  - Signal (GRDB + SQLCipher) tiene un tope opcional por conversación y borra lo más viejo al entrar algo nuevo. Fuentes: [soporte de Signal](https://support.signal.org/hc/articles/360049673331), [DeepWiki](https://deepwiki.com/signalapp/Signal-iOS/3-database-and-storage).
- **Telegram desaloja los medios por uso, no el texto.** Fuente: [telegram.org](https://telegram.org/blog/cache-and-stickers). Además marca «huecos» que rellena al hacer scroll **[inf]**; hay reportes de huecos que nunca se llenan: [bugs.telegram](https://bugs.telegram.org/c/14753/183).
- **Qué protegen:** el chat abierto y los fijados nunca se desalojan **[inf]**.
- **iOS hoy:** GRDB en el App Group, 200 mensajes por hilo y 20 hilos por agente. Desaloja por uso (`touchedAt`) y la precarga entra fría (sin contar como uso).
- **Falta en iOS:**
  - proteger favoritos y los hilos con turno o permiso vivo;
  - desalojar mensajes en vez de filas de hilo (como `trimAllThreads` de Signal);
  - el marcador «hay más antes» (`hasMoreBefore`): ya existe con sync v2.

## B. Acceso a los subagentes
- **ChatGPT:** Deep Research sólo avisa al terminar. Su Live Activity es para Voz, no para el agente. Fuentes: [OpenAI](https://openai.com/index/introducing-deep-research/), [Thurrott](https://www.thurrott.com/a-i/338971/chatgpts-voice-mode-now-supports-live-activities-on-ios).
- **Claude iOS:** las sesiones viven en la pestaña Code, separadas del chat. Fuentes: [docs](https://code.claude.com/docs/en/mobile), [#18189](https://github.com/anthropics/claude-code/issues/18189).
- **Cursor:** lista de agentes y aviso al completar. Fuente: [docs](https://docs.cursor.com/get-started/web-and-mobile-agent).
- **Apps de terceros para agentes:** usan la Dynamic Island; se pone roja cuando falta tu aprobación. Fuente: [AgentsRoom](https://agentsroom.dev/docs/live-activities).
- **Límites de Live Activities:** 8 h activas + 4 h en la pantalla bloqueada, 4 KB de datos, actualización por push con el token de cada actividad, push-to-start desde iOS 17.2. Fuente: [Apple](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
- **Patrón común:** el progreso vive dentro del chat; afuera de la app sólo se avisa «terminó» o «te necesita». Nadie muestra cada subagente por separado.

## Opciones para B
1. **Píldora en la cabecera** («2 ● 1:23») en lugar de la barra sobre el compositor. Abre la misma hoja. Lo que dice un subagente al terminar entra al hilo como tarjeta.
2. **Barra plegada en una línea**, sólo mientras hay trabajo. Sin trabajo, «Subagentes» queda en el menú «⋯».
3. **Una Live Activity o notificación en curso por conversación:** contador y reloj, en rojo si hay un permiso pendiente. La mueve gs por push, a lo mucho cada 10 s, con el payload común `{turnId, hechos, total, estado}`.
