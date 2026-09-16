# Ghosty App y las flotas dinámicas (EasyBits y Ghosty Studio)

Notas de arranque, 2026-09-16. Es el punto de partida para conectar la app a flotas que
crecen y encogen, en vez de «un agente = una caja para siempre».

## Cómo está hoy (medido, no supuesto)

- **Un agente de la app = un `FleetAgent` (engine `ghosty-lite`) = una caja Firecracker
  persistente**, buscada por `metadata.acpAgentId` (`ghosty-studio/app/lib/runtime/
  acp-box.server.ts:328-338`). Dominio fijo `acp-<agentId>.sandboxes.easybits.cloud`.
- El estado vive en el disco de ESA caja: conversaciones (SQLite de goose en
  `/data/ghosty/…`) y workspace (`/data/work`). 2 GB de `/data`. Respaldo del historial a gs
  cada 15 min y al cerrar turno (`templates/goose/src/historial.ts`); se restaura al
  recrear la caja. `/data/work` NO se respalda: lo que vale sale como entrega (automática
  desde hoy) y va a los archivos de la cuenta (`saveUserFile`, `meta.origen=agente`).
- **Concurrencia**: `cupoDeSesiones(fa)` = 4 turnos a la vez para agentes sin workspace;
  con workspace, el `parallel` del plan (piso 2, techo `ACP_SESSIONS_CEILING`). Al llegar
  al cupo gs encola (`turns.server.ts`); lease de 10 min de silencio suelta la ranura.
  **«Más cajas» en el plan no le da más máquinas a un agente ACP**: sólo más turnos en la
  misma VM.
- Sin tope de gasto para agentes de la app (decidido 2026-09-11). Sin tier todavía.
- Siesta: `suspendOnIdle` + `ACP_IDLE_SECONDS`; despierta con el primer mensaje (20–60 s).
  Janitor destruye tras 72 h sin uso; `reponerCajaDelAgenteDeLaApp` la recrea.

## Lo que hay que resolver para una flota dinámica

1. **Separar estado de cómputo.** Hoy no se puede repartir un agente en N cajas porque
   sesiones y workspace están en un disco. Candidatos: historial ya vive en gs (respaldo →
   fuente de verdad); workspace por conversación en storage (Tigris) o volumen compartido.
2. **Ruteo por conversación, no por agente.** Que un `session/prompt` pueda ir a cualquier
   caja del pool del agente (warm pool de sandbox-host ya existe para workers no-ACP:
   `ensureWarm`, `warmpool.claim`). Requiere que la caja cargue la sesión desde fuera
   (`session/load` con historial de gs) y no desde su SQLite.
3. **Cupo por plan de verdad**: conectar `parallel`/`boxes` del plan al agente de la app
   cuando la app tenga tier (hoy `workspaceId == null` → 4 fijo).
4. **EasyBits**: su flota habla HTTP/SSE con la caja (`compat.ts`), no WS; la entrega
   automática y `ghosty/artifact` sólo van por WS. Unificar el transporte o portar.
5. **Disco**: nadie vigila `/data/work`; hace falta aviso y limpieza (o workspace efímero
   por turno una vez que lo valioso se entregue solo).
6. **Ids de sesión**: los pone la caja (`YYYYMMDD_n`) y chocan entre cajas/recreaciones. Con
   flota dinámica tienen que ser de gs (uuid) y la caja aceptarlos.

## Dónde mirar

- gs: `app/lib/runtime/acp-box.server.ts` (caja por agente), `app/lib/runtime/fleet.server.ts`
  (warm pool, teardown), `app/lib/agents/turns.server.ts` (cola, lease), `app/lib/agents/
  acp-client.server.ts` (enlace WS, cupo), `app/lib/planes/entitlements.ts`.
- caja: `sandbox-host/templates/goose/src/{relay,salidas,historial}.ts`.
- host: `sandbox-host/internal/api/{handlers,inflight,warmpool}.go` (siesta, reaper, pools).
- app: `GhostyApp/Data/LiveAgentStore.swift`, `Data/GS/ClienteGS.swift`, `NOTAS-DEL-RELE.md`.
