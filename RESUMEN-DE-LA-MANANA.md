# Resumen de la mañana — contrato para iOS, Android y `/c` (22-oct-2026)

Copia del resumen diario de Claude Duet, ajustado a las tendencias: tarjetas finitas como Pulse,
👍/👎 que ajustan el de mañana, audio como Huxe y el Daily Brief de Gemini, y opt-in (no gasta
saldo sin pedirlo).

## Qué ve la persona
- **Oferta (una sola vez)**, arriba de Chats: «¿Quieres tu resumen cada mañana?» con «Sí, a las 8»
  y «Ahora no». Cualquiera de los dos manda `offered: true`, y como `offered` vive en gs, la oferta
  no vuelve a salir en ninguna superficie. «Sí» pide además el permiso de avisos.
- **Perfil → «Resumen de la mañana»** (icono `sun.horizon`): el subtítulo dice «8:00 · L–V»,
  «8:00 · Todos los días» o «Apagado». Abre una hoja con:
  - el interruptor;
  - la hora;
  - los días (Lunes a viernes / Todos los días);
  - qué agente lo escribe (sólo los propios, no los compartidos);
  - «Probar ahora», que abre el hilo.

  Los cambios se guardan en el acto.
- **El hilo «Resumen de la mañana»** (`sessionId` == `brief.sessionId`):
  - Arriba va una barra con el reproductor del último audio («Escúchalo»), el estado («8:00 · L–V»),
    «Ajustar» (abre la hoja) y «Apagar», que cambia a «Prender».
  - La respuesta del agente se pinta como **tarjetas**, una por cada `## Título`.
  - Cada tarjeta lleva su cuerpo en markdown, un botón de acción si viene
    `→ Acción sugerida: …` y 👍/👎 propios.
  - Cierra con «Eso es todo por hoy.».
  - Si el texto no trae `## `, se pinta como cualquier respuesta.
- **La acción** NO se ejecuta en el cliente: se manda como mensaje normal al agente
  («De mi resumen («Título»): acción»), y el agente pide permiso como siempre.
- Kill switch remoto: el flag `brief` de `GET /api/v2/app/config`. Apagado, desaparecen el renglón,
  la oferta y la barra.

## API (gs)
`GET /api/v2/me/brief` regresa:
```json
{ "enabled": false, "hour": 8, "minute": 0, "days": [1,2,3,4,5],
  "agentId": "…", "timeZone": "America/Mexico_City", "sessionId": null, "offered": false }
```
- `days`: 0 = domingo … 6 = sábado.
- `PUT /api/v2/me/brief`: cuerpo parcial con cualquiera de esos campos. Manda siempre `timeZone`
  (la del teléfono) y regresa la forma completa. Prenderlo implica `offered: true`.
- `POST /api/v2/me/brief/run` («Probar ahora») regresa `{ agentId, sessionId, turnId }`. Tope:
  5 al día.
- Errores: `{ error, detalle }` (400/403/429). Enseña `detalle`.

**Voto por tarjeta**: `POST /api/v2/me/agents/:agentId/conversations/:sessionId/feedback` con
`{ turnId, rating: 1|-1|0, card: <índice desde 0>, surface }`. Sin `card` vale para la respuesta
entera, como hoy.

**Audio**: es un bloque `eb-audio` al PRINCIPIO del texto del mensaje del agente, como `voice.speak`
(con un campo `name` extra que sirve de rótulo):
```eb-audio
{"url":"https://…/u/<userId>/resumen/<turnId>/resumen-2026-10-23.mp3?X-Amz-…","waveform":"","durationMs":74000,"mime":"audio/mpeg","name":"resumen-2026-10-23.mp3"}
```
- La URL está firmada por 7 días; `/api/v2/me/files/fresh?u=<url>` la vuelve a firmar.
- No sale en `files[]`.
- El mensaje se guarda una sola vez y ya con el audio: `done` y el push esperan al TTS (tope ~2 min).
- La barra toma el último audio del hilo.
**Push**: igual que el de «contestó» (`kind: "reply"`, `agentId`, `sessionId`), con
`brief: "true"` (string) y el título «Tu resumen de la mañana». Si no hubo nada nuevo, no hay push.

## Referencia en iOS
- `Core/Data/MorningBrief.swift`: modelo, API y store.
- `Core/Chat/MorningBriefViews.swift`: el parser de tarjetas, las tarjetas y la barra.
- `Core/Chat/MorningBriefSheet.swift`: la hoja de ajustes.
- La oferta está en `GhostyApp/Screens/ConversacionesView.swift` (`MorningBriefOffer`) y el renglón
  en `PerfilView.swift`.
- Demo: `GHOSTY_DEMO_RESUMEN=1` (hilo) o `=oferta` (la tarjeta de Chats). Pruebas:
  `GhostyAppUITests/MorningBriefUITests.swift`.
