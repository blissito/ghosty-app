# Lo que la app necesita del relé

Estado a 2026-09-10. Nada de esto se puede resolver desde el teléfono.

## 1. Webhook de turno — el bloqueador real

Hoy los webhooks emiten `file.*` y `website.*`. **No hay ningún evento de turno**, y ése es
el que hace falta: la app se va al fondo, iOS mata el socket, el turno termina en la caja
y no se entera nadie.

```
turn.completed        { agentId, sessionId, turnId, terminadoEn }
permission.requested  { agentId, sessionId, turnId, herramienta }
```

Con eso, gs dispara el APNs. La app ya tiene la otra mitad: entitlements, token registrado
(`POST /api/v2/me/devices`), sonidos y apertura de la conversación al tocar el aviso.

**El de «terminó» tiene que ser un push VISIBLE** (`apns-push-type: alert`,
`apns-priority: 10`, `sound: "burbuja.caf"`, `thread-id: <sessionId>`). El silencioso no
llega si el usuario mató la app desde el conmutador, no llega en Bajo Consumo, y iOS lo
limita a unos pocos por hora **entre todas las apps del teléfono**: sirve para adelantar la
recogida, no para avisar.

El de permiso va igual pero con `interruption-level: time-sensitive`: es un turno DETENIDO
esperando a una persona, y eso atraviesa un Focus con razón.

Idempotente por `turnId`: el mismo push puede llegar dos veces.

## 2. Un cursor en `session/load`

Hoy devuelve el hilo entero. Al volver del fondo eso es traerse toda la conversación para
descubrir si hay una respuesta nueva, y con hilos largos se nota.

```
session/load { sessionId, since: <cursor> }
  → { events: [...], cursor: <nuevo> }
  → o { gap: true } si ese cursor ya no está en el buffer, y el cliente recarga entero
```

Es lo que hacen Slack y Telegram. Sin el `gap: true`, un hueco se convierte en pérdida
silenciosa de mensajes.

## 3. `session/load` no reconstruye el contexto del modelo

Ya reportado. Al reabrir una sesión, el agente no recuerda de qué iba la conversación
aunque el replay sí traiga los mensajes. La app lo parchea mandando la conversación previa
dentro de cada turno (`BloqueDeHistorial.swift`), que es caro y hay que borrar en cuanto
esto se arregle.

## 4. `ghosty/artifact` para todo lo que produce el agente

Hoy sólo llega para algunas cosas, y el resto viaja como un bloque ```` ```eb-file ````
dentro del texto que la app tiene que parsear a mano (`BloqueEbFile.swift`).
