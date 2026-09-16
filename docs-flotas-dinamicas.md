# Ghosty App y las flotas dinámicas (EasyBits y Ghosty Studio)

Leído a fondo el 2026-09-16: `~/easybits`, `~/ghosty-studio` (gs) y `~/sandbox-host` (sh).
Es el punto de partida para que la app deje de depender de «un agente = una caja para
siempre» y hable con flotas que crecen, encogen y se reparten.

## 1. Las tres piezas, como están hoy

### sandbox-host (el fierro)
- Dos hosts (A: OVH KS-5 32 GB, B: SYS-3 128 GB) unidos por Tailscale; `sandbox-router`
  coloca por RAM libre > hosting > afinidad de tenant, y localiza una caja por id
  sondeando hosts (`cmd/sandbox-router/main.go:362-466`). **No hay autoscale ni migración
  en caliente**: mover una caja de fierro es backup→Tigris→`import` (~11 s, con operador).
- Primitivas útiles: **warm pool** por clave (claim ≈0 s si corre, ≈1 s si hibernada, 12 s
  fría; `internal/api/warmpool.go:270-422`); hibernación con reanudación ~210 ms + salud;
  `persistent`, `suspendOnIdle`, `/idle`, `/extend`, `/busy` como veto; `snapshot`+`fork`
  (clon CoW de rootfs + volúmenes); `/files/*`, `/exec`; `eb_boot*` (script que corre en
  cada arranque/reanudación: el gancho natural para «traer estado de fuera al despertar»).
- Lo que **no** hay: volúmenes desmontables (el `/data` nace y muere con su caja), montaje
  compartido/objeto, KV libre en metadata, listado global (`all=1` no existe), specs de
  pool que sobrevivan al reinicio (gs las redeclara).

### Ghosty Studio (gs)
- **Workers no-ACP** (claude-worker, codex, deepseek…): ya es una flota dinámica.
  Unidad = ruta `(fleetAgentId, groupId) → sandboxId + sessionUuid` (`FleetAgentRoute`);
  cajas por **cohorte** `owner:engine:model:template`, compartidas hasta `maxWorkersPerVm`;
  `ensureWarm` declara el pool, `reserveRoute` reutiliza/claim/crea, `destroyIfOrphaned`
  recoge (`app/lib/runtime/fleet.server.ts:993-1574`). El historial NO está en gs: el
  worker reanuda desde su disco y el transcript va a Tigris; Teams manda el hueco desde su
  sqld. Entregas = fence `eb-file` que Teams convierte en adjunto.
- **ACP / ghosty-lite** (lo que usa la app): **una caja persistente por agente**, buscada
  por `metadata.acpAgentId`, dominio fijo `acp-<agentId>`, un WebSocket por agente con N
  sesiones dentro, cupo `ACP_MAX_SESSIONS = clamp(parallel, 2..8)` (4 para la app, sin
  workspace). Ids de sesión `YYYYMMDD_n` los pone la **caja** (únicos sólo dentro de su
  SQLite). Historial en `/data/ghosty/…/sessions.db` con respaldo `VACUUM INTO` a gs y
  restauración al recrear. Desde hoy: entrega automática del workspace y entregas
  guardadas en archivos de la cuenta (`meta.origen=agente`).
- Plan: `parallel` (turnos vendidos) → `boxes = ceil(parallel/workersPerVm)`; **no se
  aplica como contador**: sólo da forma al pool; el tope real es `CapacityReached` del
  fierro + cola de admisión. Agentes sin workspace: sin tope ni gasto medido (2026-09-11).

### EasyBits
- `FleetAgent` (claude-worker | codex | ghosty-gc | gemini) con persona horneada al spawn,
  `maxWorkersPerVm=4`, `maxVms=10`, `warmSpares`, reaper propio (suspende a los 2 min,
  destruye a los 45). Ruta pegajosa `(fleetAgentId, groupId) → agentId + sessionUuid`,
  **sin warmpool.claim**: cajas persistentes por FleetAgent, multiplexadas; memoria del
  modelo en disco del worker respaldada a S3 al suspender.
- API HTTP, sin WebSocket: `POST /api/v2/fleet-agents/:id/message-stream` (SSE: `chunk`,
  `tool`, `usage`, `done`, `capacity`, `error`) y `GET …/messages?since=<cursor>` con
  `gap`/`gapReason` — **diseñado para un móvil que se va al fondo**. Webhooks
  `turn.completed|failed` para push. Entregas: el agente sube a Files y pone la URL en el
  texto (no hay fence); hay MCP `artifact` y `render` que devuelven `{fileId,url}`.
- Auth: tokens de flota `flt_sk_` / `flt_pk_` (15 min–12 h, para clientes); cuenta con
  `eb_sk_` u **OAuth 2.1 PKCE** (`/api/v2/me`, `/api/v2/fleet-agents`). Ojo: las rutas de
  flota **no** aceptan el JWT de OAuth; alguien tiene que acuñar el `flt_*`.
- Cupo por plan = `concurrentSandboxes` de la cuenta (1/2/5) + reservas; saturación →
  `capacity` con `retryAfter` (espera hasta 25 s) o 503; LRU de conversaciones dormidas.

## 2. Lo que la app ya sabe hacer y lo que le falta

La app habla **sólo con gs** por HTTP+SSE (`ClienteGS`), re-suscribible, con el turno en
el servidor. Eso ya es el modelo correcto para una flota: el teléfono no sabe de cajas.
Lo que asume y hay que soltar:

1. `ACPClient.Session.id` = id de la caja (`YYYYMMDD_n`) → choca entre cajas. Hoy la app
   ya guarda todo por `agente/sesión`; falta que el id lo dé gs (uuid).
2. Historial = `session/load` a UNA caja. Con N cajas, gs tiene que servir el historial
   desde su copia (ya la tiene por respaldo; convertirla en fuente de verdad o guardar
   mensajes en DB como EasyBits).
3. Entregas: ya persistentes en la cuenta (hoy). Falta lo mismo para EasyBits (URL en
   texto → tarjeta).
4. Transporte a EasyBits: SSE ya existe allá; la app necesitaría un segundo cliente o,
   mejor, que **gs haga de puente** y la app siga viendo una sola API.

## 3. Propuesta (por etapas, cada una útil sola)

**E1 — gs, ACP en N cajas (sin tocar la app).**
- Tabla de rutas ACP `(agentId, sessionId) → sandboxId` (gemela de `FleetAgentRoute`),
  enlace WS por `(agentId, boxId)` en vez de por agente; dominio por caja
  `acp-<agentId>-<n>`; warm pool de `ghosty-lite` por agente (quitar el early-return de
  `ensureWarm:1033` y el descuento `contarCajasAcp`).
- Ids de sesión de gs: uuid que la caja acepte en `session/new` (cambio en ghosty-lite:
  `session_manager.rs:1595-1620` genera `YYYYMMDD_n`; aceptar id externo).
- Historial por conversación en gs (no `VACUUM INTO` de toda la base): al abrir una
  sesión en una caja nueva, `eb_boot` o `/files/write` siembran ese transcript; al cerrar
  turno se sube. `/data/work` por conversación (`/data/work/<sessionId>`), efímero.
- Cupo real: contador de turnos por agente = `parallel` del plan (hoy nadie lo aplica).

**E2 — gs como puente a EasyBits (la app sigue con una sola API).**
- Un `FleetAgent` de gs con engine `easybits` cuyo runtime traduce: `session/new` →
  `groupId` nuevo, `prompt` → `message-stream` (SSE→eventos `chunk/tool/done`), historial →
  `messages?since`, entregas → detectar URLs de Files y guardarlas como `saveUserFile`
  `origen=agente`, push → webhook `turn.completed`. Acuñar `flt_pk_` de corta vida por
  usuario desde gs (OAuth de EasyBits para ligar la cuenta).
- La app recibe el mismo contrato (`conversations`, `events`, `files`) y no distingue.

**E3 — app.**
- Aceptar ids uuid (ya no asume formato), mostrar estado `capacity/en cola` como turno
  esperando (ya existe «en cola» para ACP), quitar `BloqueDeHistorial` (el parche que
  manda la conversación previa en cada turno) cuando el historial sea del servidor.

## 4. Riesgos y decisiones que quedan

- **Estado fuera de la caja** es la decisión grande: DB de mensajes en gs (como EasyBits)
  o transcript por sesión en Tigris (como los workers). Recomiendo DB en gs + transcript
  del motor en Tigris por sesión: la app y la web leen de gs; el motor reanuda de Tigris.
- **Claude Code dentro de ghosty-lite** guarda su propio estado por sesión; hay que
  comprobar que reanuda desde un transcript sembrado (los workers ya lo hacen con
  `FLEET_PERSISTENT_SESSION`).
- **Costo**: cada caja son 2 GB; N cajas por agente sólo con plan que lo pague. Para la
  app sin tier: 1 caja + cola, como hoy.
- **EasyBits sin OAuth en rutas de flota**: el puente en gs es la salida limpia; un cliente
  móvil directo tendría que manejar `flt_*` y CORS.

## 5. Dónde mirar

- gs: `app/lib/runtime/{fleet,acp-box,sandbox-host}.server.ts`, `app/lib/agents/
  {turns,acp-client}.server.ts`, `app/lib/planes/entitlements.ts`, `docs/agentes-v2-arquitectura.md`.
- sh: `internal/api/{router,warmpool,inflight,handlers,bootstrap}.go`, `cmd/sandbox-router/
  main.go`, `docs/multi-host-scaling.md`, `templates/goose/src/{relay,salidas,historial}.ts`.
- EasyBits: `app/.server/fleetAgentOperations.ts` (`runTurn` 2492, `pickOrSpawn` 2262,
  `reserveVm` 1856), `app/routes/api/v2/fleet-agents.$fleetAgentId.{message-stream,
  messages}.ts`, `app/.server/apiAuth.ts`, `app/lib/plans.ts`, `app/.server/webhooks.ts`.
- ghosty-lite: `crates/goose/src/session/session_manager.rs:1595-1620` (ids), `crates/
  goose/src/acp/provider.rs` (claude-acp; no manda `rawInput`).
- app: `GhostyApp/Data/LiveAgentStore.swift`, `Data/GS/ClienteGS.swift`, `NOTAS-DEL-RELE.md`.

> TODO: este documento debe vivir en `~/ghosty-studio/docs/` (junto a
> `agentes-v2-arquitectura.md`); aquí es sólo el borrador.
