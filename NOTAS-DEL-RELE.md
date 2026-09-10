# Lo que la app necesita del otro lado

Estado a 2026-09-10. Nada de esto se puede resolver desde el teléfono.

> ⚠️ **Este archivo se llamaba `NOTAS-PARA-EASYBITS.md` y estaba mal dirigido.** Al medirlo,
> nada de lo que pedía era de EasyBits: tres cosas eran de **gs** y la cuarta de
> **ghosty-lite**. El teléfono habla con gs (`www.ghosty.studio`) y con la caja que gs
> aprovisiona; EasyBits sólo aparece en el dominio del sandbox y en el POST que despierta la
> caja.

## Lo que ya se hizo (2026-09-10)

| Lo que pedía | Dónde estaba de verdad | Estado |
|---|---|---|
| Evento de turno para disparar el APNs | gs no tenía **ni ruta, ni tabla, ni APNs**. La app llevaba meses mandando su token a `/api/v2/me/devices` y comiéndose el 404. | ✅ hecho |
| `permission.requested` | No faltaba un evento: **gs auto-aprobaba** todo (`allow_once` elegido solo, sin preguntar a nadie). | ✅ hecho |
| Cursor en `session/load` | `_meta.replayTail` **ya existía** en la caja y no lo mandaba nadie. | ✅ parcial |
| `session/load` no reconstruye el contexto | Bug de `ghosty-lite`, localizado. | ✅ arreglado, falta rebake |
| `ghosty/artifact` sin `sessionId` | El relé acuñaba el token por **socket**, y gs multiplexa varias conversaciones por enlace. | ✅ hecho, falta rebake |

### 1. Avisos

`POST /api/v2/me/devices` existe (contrato tal cual lo mandaba la app). El aviso sale del
`finally` de `startTurn` en gs, que es el único punto donde sabe con certeza que el turno
terminó, y **sólo si nadie está mirando**.

⚠️ **Falta poner la llave de Apple**: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` (y
`APNS_BUNDLE_ID` si no es `com.fixtergeek.ghostyapp`). Sin ellas `pushConfigurado()` es
`false` y no se manda nada — en silencio y a propósito, para no ensuciar el log en local.

### 2. Permisos

El turno se DETIENE de verdad. `event: permission` por el SSE, se contesta con
`POST …/conversations/:sid/permission`, y hay plazo (10 min → se deniega): un pedido sin
dueño retiene una ranura de la caja y desde fuera se lee como un agente colgado.

⚠️ **El default sigue siendo `auto`.** Sólo un cliente que sabe pintar la tarjeta y
contestarla manda `permisos: "preguntar"` al encargar el turno. La app ya tiene la mitad
(`PermissionsPane`, `LiveAgentStore.decide`), y lo enciende cuando migre de transporte.

### 3. El contexto

**Causa encontrada**: el cerebro del teléfono es el binario `claude`, o sea un proveedor ACP
**anidado**. `messages_to_prompt` sólo le manda el último mensaje del usuario; el historial
vive dentro de su proceso. La red de seguridad es el memo de traspaso, que es de un solo uso
**por proveedor** — y el proveedor se reusa entre `session/load`. Turno 1 lo gasta, turno 2
encuentra al sub-agente en blanco y el memo ya está marcado como enviado. Ni contexto ni
memo, y sin un solo error en el log.

Arreglado: un resume fallido rearma el memo.

⚠️ **`BloqueDeHistorial.swift` se borra cuando el rebake esté puesto y medido**, no antes.
Son 14 mensajes / 6000 caracteres por turno.

### 4. Entregas

`ghosty/artifact` ya lleva `sessionId`, y la app lo usa (con respaldo para cajas con el relé
viejo). `BloqueEbFile.swift` sigue vivo mientras el agente escriba ```` ```eb-file ```` en su
texto.

---

## Lo que queda

- **La mudanza de transporte.** El WS directo a la caja es la razón de fondo de casi todo:
  iOS mata el socket al irse al fondo y el turno muere con él. gs ya tiene el camino donde
  *el host es dueño del trabajo* (`turns.server.ts`): `POST …/conversations/:sid/messages`
  (202 + `turnId`), SSE en `…/events`, `…/cancel`. Con eso, `asegurarHilo` y su
  `session/load` por turno desaparecen.
  ⚠️ **Antes hay que añadir `tools=1` al ticket que firma gs** (`acpTicketUrl`), o el agente
  pierde `entregar_archivo` y `crear_artefacto` al mudarse y parecerá que la migración lo rompió.
- **El cursor `since` de verdad.** `replayTail` es un tope por la cola, no un cursor. El
  sustrato para uno real está y es persistido: `messages(created_timestamp, id)` en el SQLite
  de la caja.
  ⚠️ Sería por **mensaje**: los trozos sueltos de un mensaje a medias no se guardan en ningún
  lado y no se pueden reconstruir.
- **`goose-acp` tiene su propia copia del relé** y no lleva el arreglo del `sessionId`.
