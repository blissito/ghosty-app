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
| Conversaciones | `GET`/`POST …/conversations`, `DELETE …/:sid` |

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

- **Lease con vencimiento por turno** (`PROMPT_TIMEOUT_MS` existe y no se usa). Un turno
  vivo pero mudo no tiene tope; es lo que llenó las ranuras de zombis.
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
- **Conversaciones que quedan «trabajando» para siempre**. Ya hay un botón «Detener» en el
  cartel, pero la causa está en el servidor: sin lease por turno, un turno mudo no se muere.
