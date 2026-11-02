# Brief de la mañana — contrato para iOS (2-nov-2026)

Desde gs `28fedd52` [brief-unico] hay UN solo aviso matutino: el brief corto (`daily-digest/` en gs). El
«Resumen de la mañana» del 22-oct (turno completo, tarjetas, hilo fijo, oferta) se retiró; `/me/brief*`
sigue respondiendo para builds viejas.

## Preferencia
`GET /api/v2/me/digest` → `{ enabled, voice, hour, minute, days (0=dom..6=sáb), timeZone }`; `PUT` acepta
cualquier subconjunto (la app manda sólo lo que cambió y siempre `timeZone`). Default: prendido, con voz,
7:30, todos los días. iOS: `Core/Data/DailyDigest.swift` (modelo, API, store) y el panel
`Core/Chat/DailyDigestSheet.swift` (Perfil → «Brief de la mañana»).

## El mensaje
Mensaje del agente principal en el hilo personal más reciente:
```
*☀️ Brief de la mañana · <fecha>*        (los del 2-nov traen `---` antes)
```eb-audio {...}```                      (opcional, si «Con voz»)
**encabezado**
- renglones
¿Te sirve? [Sí](…/brief/r/<token>?a=yes) · [No](…?a=no) · [Ya no me lo mandes](…?a=off)
```
- `BloqueEbFile` saca el audio como entrega (reproductor de siempre, sin autoplay).
- `DigestMessage.split` (`Core/Chat/DigestMessage.swift`) lo reconoce en `AgentBubble`: etiqueta ámbar, cuerpo y
  pie chico gris. El pie hace `POST /api/v2/digest/r/<token>` con `{a: yes|no|off|on}` sin sesión y sin salir del
  chat; lo contestado se guarda por token en `UserDefaults` (`app.digest.reactions`).
- Push: `kind: reply` + `digest: "true"`, abre el hilo.
- Demo: `GHOSTY_DEMO_BRIEF=1` (hilo «Pendientes de hoy»). Pruebas: `GhostyAppUITests/DailyDigestUITests.swift`
  y `GhostyCoreTests/DigestMessageTests.swift`.
