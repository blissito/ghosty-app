# Lo que la app espera del otro lado

Estado a 2026-09-11, de madrugada. La app ya **no habla con la caja**: habla con gs
(`www.ghosty.studio`) por HTTP+SSE, y gs habla con la caja.

## Por qué se mudó

El teléfono se duerme. Con el WebSocket directo, el turno era del teléfono y moría con él
— medido: mandar, cortar el socket a los 3 s, esperar 25 y pedir el hilo devuelve **cero
caracteres**. El relé cierra el socket hacia el motor cuando cae el del cliente, y en Rust
soltar la conexión cancela el futuro del `session/prompt`. **Un turno era su socket.**

En gs el turno vive en su propia tarea, fuera del request. Medido: matar la app a los 8 s y
volver a los 40 → la respuesta está entera.

## El contrato que usa la app

| Operación | Ruta |
|---|---|
| Mandar turno | `POST …/conversations/:sid/messages` → 202 `{turnId, estado, enCola}` |
| Escuchar | `GET …/conversations/:sid/events` (SSE, re-suscribible) |
| El hilo | `GET …/conversations/:sid?tail=N` → `{messages, saltados}` |
| Permiso | `POST …/conversations/:sid/permission` `{id, optionId}` |
| Detener | `POST …/conversations/:sid/cancel` |
| Conversaciones | `GET`/`POST …/conversations`, `DELETE …/:sid` — cada fila y el hilo llevan `ultimoTurno {turnId, state, error, startedAt, endedAt}` (persistido en `TurnRecord`) y `permisoPendiente {id, title}` o `null` (de MEMORIA, ver abajo) |

Eventos: `chunk`, `thought`, `tool`, `artifact`, `usage`, `permission`,
`permission-resolved`, `status`, `caps`, `title`, `done`, `error`.

### Tres filos que ya cortaron

1. **El `done` de bienvenida.** Quien se suscribe a una conversación en reposo recibe un
   `done` de entrada. Lleva `reposo: true` para distinguirlo — sin mirarlo, cada turno sale
   «cerró sin texto», y si se aplica mientras mandas, apaga el turno que acabas de encargar.
2. **Los permisos abiertos se reenvían en CADA suscripción.** Sin memoria de lo ya avisado,
   cada reenganche pinta otra tarjeta del mismo pedido.
3. **El backlog no sustituye a `?tail=N`.** Dura unos minutos y vive en memoria de gs: para
   «me fui un rato» hay que PEDIR la conversación.

### La lista es el único estado que hay de las otras superficies

gs **no tiene stream por cuenta ni por agente**: todo SSE es `(agentId, sessionId)`. Así
que lo que el agente hace desde la Mac o desde la web sólo se sabe por
`GET /conversations`, y de ahí salen dos cosas distintas:

- **`ultimoTurno`** es HISTORIAL (`TurnRecord`, en la DB). Su `startedAt` es lo que deja
  caducar un `running`: la app deja de creérselo a los 15 min (`UltimoTurno.frescura`).
  ⚠️ Sin `startedAt` la app **no afirma nada** — un servidor que no manda la fecha no la
  autoriza a inventar trabajo en curso.
- **`permisoPendiente`** es ESTADO de un turno vivo (`permisosAbiertosDe`, memoria de gs,
  no se persiste). Existe porque «espera tu visto bueno» sólo salía por el SSE de esa
  conversación: un permiso pedido desde la Mac llegaba al teléfono como push y la lista no
  podía decir nada hasta abrir el hilo, siendo el estado más urgente que hay — el turno
  está DETENIDO. ⚠️ Es memoria de la instancia: con blue/green sólo la activa ve los suyos.

El push **nunca** puede encender «trabajando»: es siempre `alert` y sólo sale al TERMINAR
el turno o al pedir permiso, nunca al arrancar. Por eso la app repregunta al volver del
fondo y al entrar a la lista (con freno de 30 s), y no hay ningún temporizador.

⚠️ gs **no distingue la superficie**: web, Mac y teléfono son todos `canal: "chat"`. Por
eso la app dice «Trabajando en otra conversación…» y nunca «desde tu Mac», que sería
inventado. Para poder decirlo habría que mandar `source` en el POST y persistirlo.

### `usage`

`used`/`size` son el acumulado de la sesión contra el límite del modelo — tras una
compactación `used` se pasa de `size`, y pintarlo como tokens del turno es de donde salió
el «14xxk». Los buenos son `input`/`output`, y **se omiten** si la caja no los sabe: hay que
distinguir «cero» de «no lo sé».

## Lo que se arregló en gs el 2026-09-10/11

- `tools=1` en el ticket firmado: sin eso el agente pierde `entregar_archivo` y
  `crear_artefacto`.
- Evento `artifact` en el SSE: gs recibía `ghosty/artifact` del relé y **la tiraba**.
- Push: no había ni ruta, ni tabla, ni APNs. Y la supresión «si alguien mira» se disparaba
  justo con el teléfono suspendido —una conexión muerta no se detecta como muerta— o sea
  **en el único caso que el push existe para cubrir**.
- El barrido de huérfanas destruía la caja del teléfono cada 15 min (su fila conserva el
  template legacy `goose-acp` y la exención sólo miraba `goose`/`ghosty-lite`).
- Al caer el socket nadie avisaba al turno en vuelo: quedaba `running` para siempre **con la
  ranura ocupada**. Con el cupo lleno de zombis, todo lo demás hace cola hasta reiniciar gs.

## Lo que queda

- **Turno mudo de 10 min en la caja del teléfono (2026-09-11 15:22–15:32 UTC).** gs lo
  cortó por el lease y avisó. Medido en sandbox-host (box-b): la caja `sb_c575155c…`
  estaba DESPIERTA (resume 15:16:58, sin suspend en la ventana), así que el silencio fue
  dentro del agente (ghosty-lite): un comando o una llamada al modelo que no volvió.
  Falta un tope por herramienta del lado ghosty-lite; aquí la red es el lease.
  **Actualización (16:20 UTC): reproducido y resuelto.** La causa es `session/load` a la
  caja con un turno EN MARCHA (lo hace `GET /conversations/:sid`): goose se queda mudo y
  la herramienta pendiente no se lanza. Lo disparaba el reenganche tras dormirse el
  teléfono (`engancharse(ponerseAlDia: true)`) y cerrar/reabrir la app. gs (`d9d6934`) ya
  no carga historial con turno vivo: contesta `enCurso: true` y el backlog del SSE trae lo
  nuevo. ⚠️ El loader del chat web hace el mismo `loadHistory`: un F5 a media respuesta
  debería reproducirlo — pendiente del lado web/Teams.

- ~~**Lease con vencimiento por turno**~~ **hecho**. `PROMPT_TIMEOUT_MS` nunca existió en
  gs (era de otro repo; esta nota mandó a buscar donde no había). Lo que sí hay, en
  `turns.server.ts`: `TURN_SILENCE_MS` = 10 min sin emitir NADA —rearmado en cada evento—
  y `TURN_HARD_CAP_MS` = 1 h de tope duro. Queda el residuo: `acquire` hace `busy++`
  siempre y sólo el `finally` lo libera (un turno que no llega ahí deja la ranura inflada
  para siempre), el tope duro sólo hace `abort()` y no llama a `transportFor(fa).cancel`
  como sí hace `stopTurn`, y `stopTurn` exige `userId` así que un reaper de sistema no lo
  puede usar tal cual.
- **Un cursor de verdad** en el hilo (`?since=`), en vez de `tail`.
- `loadHistory` concatena mensajes consecutivos del mismo rol sin separador: dos envíos
  seguidos salen pegados («entrega el docentrega el doc»).
- **`BloqueDeHistorial` ya no se manda**, pero el arreglo del contexto en ghosty-lite sigue
  sin medirse contra una caja recreada con dos turnos y la caja hibernada en medio.

---

## Abierto en la app (2026-09-11, madrugada)

- ~~El botón de «ir hasta abajo»~~ y ~~el push a la conversación equivocada~~: cerrados
  el 2026-09-11 por la tarde. El scroll tiene UNA regla (`pegadoAbajo`); el push es
  estado pendiente (`irA` → `aplicarAvisoPendiente`), no un evento. Y gs manda `turnId`
  en `chunk`/`done`: la burbuja se llama `turno-<id>` y el historial del servidor
  SUSTITUYE al local (ya no hay «no piso si viene con menos» ni dedupe por texto).
- **Ya no se pide `permisos: preguntar`** por turno. Detenía cada herramienta.
- **Ronda 4 (tarde del 11):** `POST /messages` lleva `turnId` del teléfono y gs lo usa
  como clave de idempotencia (`repetido: true` al reintentar); el POST reintenta solo
  ante red caída o 502/503/504 (1, 2, 4, 8 s). gs **drena** al SIGTERM del deploy: 503 +
  `Retry-After` a los turnos nuevos y espera hasta 4 min a los que corren (drop-in
  `TimeoutStopSec=300`). El push silencioso en frío monta los canales del caché y abre
  la conversación del aviso antes de pedirla. **Verificado en producción** (15:05):
  POST doble con el mismo `turnId` → `repetido: true`; restart con un turno en vuelo →
  `[drain] SIGTERM con 1 turno(s)`, el turno cerró con push y sólo entonces reinició.
- ~~**Conversaciones que quedan «trabajando» para siempre»**~~: el lease de gs las mata a
  los 10 min de silencio, y desde el 2026-09-22 la app además las caduca por su cuenta —una
  fila que dice `running` desde hace horas se pinta «Sin noticias · hace 3 h» en vez de
  repetir una mentira que desde el teléfono nadie puede desmentir.
