# La computadora del agente en el teléfono (1.0.16)

El agente pide ayuda en su navegador → push → un toque → tomas el control por WebRTC → lo devuelves.

## Qué hace la app

- **En el hilo**: cada `CUSTOM ghosty.browser` de un run vivo (AG-UI) llega a `AgentComputerStore`
  (`Core/Computer/AgentComputer.swift`). Con `needsHuman` sale «Te necesito aquí» + **Tomar el control** /
  **Sólo mirar** encima del compositor; sin él, **Ver mi computadora en vivo**. Textos iguales a Android. Se quita al terminar el run.
- **Pases**: `POST /api/v2/me/agents/:agentId/browser/(watch|takeover) {sessionId: <sesión del NAVEGADOR>}`
  con el bearer de la app. 410 = «Tu agente ya cerró ese navegador».
- **Pantalla** (`GhostyApp/Computer/TakeoverView.swift`, LiveKit Swift 2.17.0 exacta): video del
  participante `agent-browser` ajustado al `viewport`; tocar = `mouse down+up`; arrastrar = `scroll {dy}`;
  pellizcar = zoom LOCAL (las coordenadas se convierten con `TakeoverGeometry`, nunca se manda); campo
  nativo → `type {text}` (en trozos de 2000), botón «Contraseña» → `SecureField` con
  `textContentType = .password` (llavero); Enter / Borrar / Tab → `key`; «Copiar selección» = RPC `gc.copy`.
  Entrada en orden por el canal confiable `gc.input`, compactada con `HumanInput.enqueue`.
- **Latido**: cada 30 s `POST inputUrl {"type":"ping"}` (como la web); 404/410 = la toma terminó.
- **Devolver el control**: RPC `gc.release` y `POST releaseUrl` a la vez; el POST es el que despierta al
  agente (`releaseHandoff`) y se manda aunque no haya sala.
- Sin `livekit` en el pase o sin video en 5 s: estado claro («todavía no transmite en vivo al teléfono» /
  «No pude conectar… Reintentar»). ⚠️ **El respaldo SSE (`liveUrl` JPEG + `inputUrl`) NO está** en el
  teléfono; con la toma abierta sin LiveKit sólo se puede devolver el control.
- El contrato de entrada es espejo de `~/ghosty-studio/packages/computer/src/protocol.ts`
  (`Core/Computer/TakeoverProtocol.swift`); `GhostyCoreTests/TakeoverProtocolTests.swift` repite los
  casos de `computer.test.ts`. Si cambia allá, cambia aquí.

## Lo que falta en gs (no existe hoy)

gs **no manda push** cuando el agente llama `cloud_browser_ask_human`. La app ya entiende este aviso;
gs debe mandarlo **una vez por pedido** (la primera llamada, no en cada tramo de espera de 2 min) desde
`cloud-browser.server.ts`, resolviendo el `LiveTurn` por `turn.turnId` (`CloudBrowserTurn` sólo trae
`agentId/partnerTurnId/turnId`) y con la misma puerta que `avisarDePermiso` (`isPersonalThreadOf`):

```ts
await avisarA(turn.userId, {
  titulo: `${header.agent} te necesita`,
  subtitle: header.subtitle,
  cuerpo: instructions,                       // el texto de needsHuman
  sonido: "gota.caf",
  threadId: turn.sessionId,                   // la CONVERSACIÓN
  collapseId: `help:${browserSessionId}`,
  urgente: true,                              // espera a una persona: time-sensitive
  datos: {
    kind: "browser_help",
    agentId: turn.agentId,
    sessionId: turn.sessionId,                // la conversación
    turnId: turn.turnId,
    browserSessionId,                         // la sesión del NAVEGADOR (args.session_id)
    instructions,                             // ≤300; mismo nombre que Android
    agentName: header.agent,
  },
});
```

Al tocarlo la app abre la conversación y la toma (`Avisos` → `AgentComputerStore.openFromPush`).
Mismos nombres que Android (`~/ghosty-android/docs/tomar-el-control.md`, 422b7c3). La app también acepta
`needsHuman` en lugar de `instructions`.

## Probar

- Simulador sin servidor: `SIMCTL_CHILD_GHOSTY_DEMO=1 SIMCTL_CHILD_GHOSTY_EN_HILO=1 SIMCTL_CHILD_GHOSTY_AYUDA=demo-1/s-larga/b1`
  pinta «Te necesito aquí»; tocarlo abre la pantalla (en demo, sin transmisión). Prueba de UI:
  `testTomarElControl` en `RecorridoUITests`.
- Con servidor: `SIMCTL_CHILD_GHOSTY_TOKEN=… SIMCTL_CHILD_GHOSTY_AYUDA=<agentId>/<conversación>/<browserSessionId>`
  hace lo mismo que tocar el push, con un navegador vivo de un turno real (pedirle al agente «abre
  <sitio> en tu computadora y pídeme la contraseña»; el `browserSessionId` sale en el `ghosty.browser` del turno).
- iPhone: `./instalar.sh` y pedirle eso mismo al agente; con el push de gs, bloquear el teléfono y tocar el aviso.
