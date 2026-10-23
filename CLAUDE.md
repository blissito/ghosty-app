# CLAUDE.md — app iOS de Ghosty

## 🚫 NO subas a TestFlight para probar. Usa el cable.

```bash
./instalar.sh              # compila e instala en el iPhone por cable. Segundos, ilimitado.
```

⚠️ **Apple limita cuántas builds se pueden subir por app y por DÍA.** El 2026-09-09 se
agotó el cupo con 21 subidas y a partir de ahí nada entró hasta el día siguiente — con el
agravante de que el fallo es **MUDO**: `altool --upload-app` sigue diciendo
`UPLOAD SUCCEEDED` porque el paquete viaja, y el rechazo posterior no manda correo ni
aparece en *Build Uploads* de App Store Connect. Cuatro horas de diagnóstico y dos
conclusiones equivocadas por eso.

**Reglas que quedan:**

- **Una subida al día, al final del día.** No es un límite de Apple, es la regla de la
  casa: se agrupa todo lo del día en una sola build y se sube al cerrar. Cualquier otra
  subida hay que justificarla.

- **Iterar es por cable o por WiFi** (`./instalar.sh` — el iPhone está pareado por red, así
  que `devicectl` abre el túnel solo y no hace falta enchufarlo) o en el simulador. TestFlight es para
  **repartir**, no para probar.
- Subir sólo cuando hay algo que de verdad tenga que ver otra persona, y **agrupando** los
  cambios del rato en una sola build.
- El cupo se comparte entre todos: si tres agentes suben "para probar", lo agotan entre los
  tres y nadie puede repartir en el resto del día.
- `./subir-testflight.sh` ya **valida antes de subir** (`altool --validate-app`) y contesta
  en segundos si no queda cupo. No lo quites.

## Otros dos fallos mudos del mismo camino

- **Subir NO es repartir.** Una build queda `VALID` y no la ve ningún tester hasta que se
  asigna a un grupo. El script lo hace solo.
- **El `.ipa` puede salir con OTRO número de build.** `CFBundleVersion` en `project.yml`
  tiene que ser `$(CURRENT_PROJECT_VERSION)`; si es un literal, xcodegen lo hornea y el
  número que pasa el script no llega. El script lee el número de dentro del `.ipa` y aborta
  si no coincide.

**Dónde mirar de verdad**: `https://appstoreconnect.apple.com/apps/6810017404/testflight/ios`.
La API (`scripts/asc.py builds`) **no lista** lo que está procesando, así que "no aparece"
no distingue entre procesando, rechazado y nunca llegado.

## Actualizar la app en la tienda (cada vez)

La primera actualización fue la 1.0.1 (2026-09-26). La 1.0.2 (build 58, rediseño de Brenda +
«Enviar a Ghosty» + cachés de uso y archivos) salió el 2026-09-28. La 1.0.3 (build 62: notas de
voz que ya no se pierden, baja del teléfono al cerrar sesión, narración plegada y avatar del agente
en los avisos con la extensión `NotificationService`) se mandó a revisión el 2026-09-29; salida
MANUAL — antes de publicar, confirmar en un teléfono que el aviso de «contestó» sale con la cara
del agente. La 1.0.4 (build 65: Chats estilo WhatsApp igual que Android —deslizar para archivar, leído y
fijar, favoritos—, notas de voz como WhatsApp, Archivos por pestañas, Perfil con foto, logos de
integraciones, paleta oficial, Ghosty en primera persona) se mandó a revisión el 2026-09-29 con
capturas nuevas (`scripts/capturas-tienda.sh`); salida MANUAL.
La 1.0.7 (build 75: historial con sync v2 —sin parpadeo, base local GRDB, /me/sync + /me/events—,
subagentes nativos con barra/hoja/remate para PowerGhosty y MiniGhosty, push que abre la conversación en
frío, LaunchScreen con flamita) se mandó a revisión el 2026-10-08; salida MANUAL.
La 1.0.8 (build 77) se publicó el 2026-10-12; falta subir `suggestBuild` a 77 en `/admin/settings`.
La 1.0.9 (build 78: pasos guardados al reabrir el hilo, audio de menos de 1 s que ya no marca 0:00,
suite de UI al día) se mandó a revisión el 2026-10-12; salida MANUAL.
La 1.0.10 (build 82, 2026-10-18: el chat habla **sólo AG-UI** contra `POST …/agui` de gs —ver `NOTAS-DEL-RELE.md`—,
con `ghosty.replace`, más las entregas que vuelven al hilo con la app cerrada) se mandó a revisión el 2026-10-18; salida
MANUAL. Sale de `main` 499e216a (la build 81, sin `ghosty.replace`, se retiró antes de revisión). gs sirve el contrato viejo
y `/agui` a la vez hasta que la adopción permita `minBuild` + corte (410 «actualiza»).
La 1.0.10 se publicó el 2026-10-19. La 1.0.11 (build 83: campanita de Actividad, «Continuar» en un run cortado,
PDF/audio que ya no salen crudos, pestaña Fábrica con «¿Qué hago?» en el pedido escalado) se mandó a revisión el
2026-10-19; salida MANUAL. `suggestBuild` quedó en 82 el 19-oct (la 1.0.10 ya está en la tienda).
Esa misma noche se retiró y se reenvió con la **build 84** (misma 1.0.11): además, la Fábrica completa —conversación con @plan
(plan, sprint, ideas, pregunta), sprints nativos, conectar repo, el rol en vivo y la Live Activity—. Salida MANUAL.
**Antes (decidido por bliss el 8-oct):** la 1.0.8 (build 77 en TestFlight —la 76 más «Juntando…» que no se cuelga y push de Teams que abre su liga—: íconos por clase de
paso, hoja del ghostyllo legible, «Juntando…» por `delivered` de gs; textos en `whats_new.txt`) va a
revisión EN CUANTO se apruebe y publique la 1.0.7: `asc.py publicar` → `asc.py ficha 1.0.8 <id build 77>`
→ `asc.py enviar-tienda` → `suggestBuild` a 75/77. Los `steps` de `GET …/messages` ya se pintan (1.0.9).
⚠️ Una versión aprobada y sin publicar (`PENDING_DEVELOPER_RELEASE`) BLOQUEA crear la siguiente
(`asc.py ficha` da 409): publícala o descártala antes. La receta:

1. **Probar**: `./scripts/capturas.sh` en verde e instalar en el teléfono (`./instalar.sh`).
2. **Versión**: subir `MARKETING_VERSION` en `project.yml` (1.0.1 → 1.0.2…). El build lo
   numera solo `subir-testflight.sh`.
3. **TestFlight**: `./subir-testflight.sh` (valida, sube y asigna al grupo). Esperar a que la
   build salga `VALID` en `python3 scripts/asc.py builds` (puede tardar una hora).
4. **Textos**: escribir `metadata/es-MX/whats_new.txt` («Qué hay de nuevo», lo que ve la gente
   en la tienda; sin mencionar pagos fuera de Apple).
5. **Ficha**: `python3 scripts/asc.py ficha <versión> <buildId>` crea la versión, pone los
   textos (incluido «Qué hay de nuevo») y ata la build.
6. **Enviar**: `python3 scripts/asc.py enviar-tienda` (sale sola al aprobarse, desde el 20-oct). Revisión: 24–72 h.
   `python3 scripts/asc.py estado-tienda` dice en qué va.
7. **Mientras Apple revisa**: la caja de la cuenta del revisor despierta, y en
   `/admin/settings` → App iOS **nunca** `minBuild` por encima de la build en revisión, ni
   apagar flags que la revisión va a probar.
8. **Aprobada**: sale sola. Sólo una versión vieja en MANUAL se queda en `PENDING_DEVELOPER_RELEASE` y
   sale con `python3 scripts/asc.py publicar`.
9. **Después**: en `/admin/settings` subir `suggestBuild` a la build nueva (aviso que se
   cierra). `minBuild` sólo si la vieja rompe algo que no se puede parchar en gs.

## El núcleo: `Core/` vs `GhostyApp/`

Una sola base para dos apps: **Personal** (esta, en tienda) y **Work** (Teams + Sales, aún no
existe). `Core/` es lo compartido: datos, cliente de gs, hilo, markdown, sistema de diseño,
colores y la pantalla de chat (`Core/Chat/`). `GhostyApp/` es sólo el esqueleto de Personal:
navegación, login, ajustes, listas e icono.

- **Nada de `Core/` puede tocar algo de `GhostyApp/`.** El target `GhostyCore` compila
  `Core/` solo y se pone rojo si pasa:
  `xcodebuild -scheme GhostyCore -destination 'generic/platform=iOS Simulator' build`.
- Si algo nuevo sirve a las dos apps, va en `Core/`; si es de Personal, en `GhostyApp/`.
- **Decidido el 2026-09-30:** GTeams móvil (Work) **sale de aquí**, no de un open source
  (Mattermost, Zulip, Rocket.Chat y Element X quedaron descartados porque su capa de datos está
  atada a su servidor, y Element X además es AGPL). Será **otro target sobre `Core/`, nunca un
  fork** que copie el código. Lo que se programe hoy (cliente de gs, SSE, hilo, adjuntos,
  diseño) se escribe pensando en que lo va a reusar Work: sin textos, rutas ni supuestos
  propios de Personal metidos en `Core/`.

## El turno es del SERVIDOR, no del teléfono

La app habla HTTP+SSE con gs (`ClienteGS`), no WebSocket con la caja. Desde el 18-oct el turno es
**AG-UI** (un `POST …/agui` por todo; ver `NOTAS-DEL-RELE.md` y `Core/Data/AGUI/`); probar contra
otro servidor AG-UI con `GHOSTY_AGUI_URL` y las pruebas en vivo con `TEST_RUNNER_AGUI_LIVE=<url>`. Eso no es un detalle
de tuberías: **el teléfono se duerme**, y con el socket directo el turno moría con él
(medido: cero caracteres al volver). En gs el turno sobrevive, el SSE es re-suscribible, y
al volver sólo hay que preguntar qué pasó.

De ahí salen las reglas que quedan:

- **No hay nada que «recuperar».** Si el trabajo nunca fue nuestro, irse no requiere cerrar
  nada ni apuntar deudas. Se quitaron ~900 líneas que existían para eso.
- **El estado lo dice el servidor** (evento `status`), no se infiere de si queda un turno
  local. Inferirlo ponía «Sigue trabajando…» encima de conversaciones en reposo.
  ⚠️ Y eso incluye **lo que pasa en otras superficies**: el mismo agente se usa desde la
  Mac y desde la web. El estado del agente salía de `canal.enCurso` —los turnos que abrió
  ESTE teléfono—, así que un turno encargado desde la Mac llegaba como push y la lista
  seguía diciendo «En reposo». Ahora sale de la lista (`ultimoTurno`, `permisoPendiente`);
  ver `NOTAS-DEL-RELE.md`. Reglas que quedan: **nunca se nombra el dispositivo** (gs manda
  `canal: "chat"` para los tres), todo «trabajando» **caduca** a los 15 min sin confirmar,
  y **no hay temporizadores**: se repregunta al volver del fondo y al entrar a la lista.
- **Nadie cambia de conversación por debajo.** Eso se veía como «se borró el historial al
  enviar»: no se borraba, cambiaba el hilo y el mensaje se quedaba en el anterior.
- Ver `NOTAS-DEL-RELE.md` para el contrato y los filos del SSE.

## Verificar en el simulador sin poder tocar la pantalla

Hay ganchos de desarrollo por variable de entorno, porque el simulador no acepta toques por
script (`SIMCTL_CHILD_<VAR>` al lanzar):

| Variable | Qué hace |
|---|---|
| `GHOSTY_PROBE="texto"` | manda ese mensaje al arrancar |
| `GHOSTY_ADJUNTOS=imagen\|archivo\|ambos\|voz:<ruta.m4a>` | lo manda CON adjuntos sintéticos (`voz:` = nota de voz real del disco de la Mac) |
| `GHOSTY_TAB=chat\|artifacts\|connectors\|perfil` | abre esa pestaña; `conversations` abre la hoja del historial (ya no es pestaña) |
| `GHOSTY_AGENTES=1` | abre la hoja «Cambiar de agente» |
| `GHOSTY_SHEET=1` | abre la hoja del agente (su plan y uso) |
| `GHOSTY_CONECTORES=demo` | llena Integraciones para poder mirarla |
| `GHOSTY_CORTAR=8` | mata el socket a los 8 s, como hace iOS al suspender la app |
| `GHOSTY_DEMO_INTERRUMPIDO=1` | pinta un hilo cortado por la suspensión (con el cartel) |
| `GHOSTY_DEMO_REMOTO=1` | el agente trabajando **desde otra superficie**: una conversación corriendo, una muda de hace 3 h (para ver la caducidad), una que contestó sin abrirse y una detenida por un permiso |
| `GHOSTY_PUSH=1` | se registra en APNs sin esperar al diálogo del permiso |
| `GHOSTY_AL_DIA=6` | corre `ponerseAlDia` a los 6 s del envío, con el turno escribiendo: la carrera de «abrir la app y mandar el primer mensaje» hecha determinista (el «vibrado» de la build 47) |
| `GHOSTY_CONFIG='{"minBuild":99}'` | finge la config remota de gs (`AppConfig`): `minBuild`, `suggestBuild`, `flags` (`voice`, `agenda`). En Debug la compuerta de versión SÓLO se aplica con este gancho |
| `GHOSTY_SILENCIO=20` | da el turno por cortado tras 20 s sin eventos (por defecto, 8 min) |
| `GHOSTY_NUEVA=1` | arranca en una conversación nueva (crear sesión + primer turno) |
| `GHOSTY_TOKEN=<bearer>` | presta una sesión sin pasar por el login (sólo Debug) |
| `GHOSTY_SOLO_AGENTE=<id>` | la app sólo ve ESE agente |
| `GHOSTY_AUTO_PERMISO=1` | contesta los permisos solo, para poder probar el camino entero |
| `GHOSTY_AVISO=<agente>/<sesion>` | simula tocar un push con la app CERRADA (el push del simulador arranca sin variables) |
| `GHOSTY_DEMO_CHAT=1\|tabla\|vacio` | (con `GHOSTY_DEMO=1`) el hilo del prototipo con pasos, tabla y PDF; `tabla` corta en la tabla; `vacio` abre el chat vacío |
| `GHOSTY_AGREGAR=1` | abre la hoja «Agregar» del compositor |
| `GHOSTY_VOZ=1` | pinta el overlay «Te escucho…» (sin grabar) |
| `GHOSTY_INTRO=1\|0` | fuerza o quita la intro de arranque (en modo demo no sale salvo con `=1`) |
| `GHOSTY_CARGA_LENTA=5` | se queda «cargando» 5 s: el camino lento de la intro, que el modo demo nunca toma |
| `GHOSTY_COMPARTIDO=<id>` | abre el paquete `compartido/<id>/` del App Group (lo que deja «Abrir en Ghosty» de la hoja de compartir) en el compositor |

⚠️ **Los cuatro últimos juntos son lo que permite verificar la app contra el servidor de
verdad sin la sesión de nadie.** Un token de la cuenta real alcanza a TODOS sus agentes,
incluida la caja que alguien esté usando en su teléfono: `GHOSTY_SOLO_AGENTE` es más fiable
que acordarse de no tocarla.

```bash
SIMCTL_CHILD_GHOSTY_TOKEN=… SIMCTL_CHILD_GHOSTY_SOLO_AGENTE=… \
SIMCTL_CHILD_GHOSTY_PROBE="hola" \
  xcrun simctl launch <sim> com.fixtergeek.ghostyapp
```

⚠️ **El simulador NO entrega push silenciosos.** El visible sí (`xcrun simctl push` con
`alert` saca el banner), así que la ausencia de reacción a un `content-available` ahí no
prueba nada: eso se comprueba en el teléfono, mirando el renglón `[push] silencioso` por
cable. Y el simulador tampoco suspende la app como el teléfono — la recuperación del fondo
sólo se verifica de verdad bloqueando el iPhone unos minutos.

⚠️ Un dato de prueba sintético **se comprueba contra el consumidor real**: un PNG que `file`
y PIL daban por bueno el modelo lo rechazaba por dañado, y casi doy por rota la ruta de
imágenes por culpa de mi propio dato.

## Ver la app: `./scripts/capturas.sh`

⚠️ **Un agente NO puede verificar esta app sólo compilando.** Se enviaron cinco builds
seguidas con fallos de interacción —una fila que no respondía al toque, un botón que no
hacía nada, una conversación duplicada, un hilo que se vaciaba— porque lo único que se
comprobaba era que el compilador estuviera contento. Ninguno lo habría cazado un test
unitario: eran de tocar.

```bash
./scripts/capturas.sh          # recorrido de UI tests + capturas en build-sim/capturas/
```

Corre `GhostyAppUITests/RecorridoUITests.swift` contra el **modo demo** y deja una captura
por paso. El modo demo (`GHOSTY_DEMO=1`, ver `Data/DemoData.swift`) llena el store REAL con
datos falsos y sin red: es lo que deja abrir la app en el simulador sin tener sesión, y
prueba `Canal`/`Hilo`/el caché, que es donde han estado los fallos.

**Antes de instalar en el teléfono, mira las capturas.** Si tocas UI, añade el paso al
recorrido: un toque que no hace nada tiene que salir como test rojo, no como mensaje de
Héctor.

Para lo que sólo pasa con la caja de verdad (contexto entre turnos, entregas), los logs del
teléfono:

```bash
xcrun devicectl device process launch --device $DEV --console com.fixtergeek.ghostyapp
```

## Rediseño estilo WhatsApp (1.0.4, 2026-09-29) — trampas y reglas

Igual que Android (`~/ghosty-android`, sesión `ghosty-android-79`, que avisa cada cambio visible
por mensaje entre sesiones). Diferencias pedidas por bliss sólo en iOS: avatares de 62 en Chats,
Perfil en tarjetas redondeadas y sin pager entre pestañas.

- **Chats es el inicio** (`ConversacionesView.swift` → `ChatsView`). Dentro del hilo se oculta la
  barra (`RootView.enHilo`) y la flecha regresa. Filtro por agente en `RootView.filtroChats`:
  el avatar de la barra lo pone.
- ⚠️ **iOS 18: un `DragGesture` dentro de un `ScrollView` bloquea el scroll**, aunque vaya como
  `simultaneousGesture`. Pasó tres veces: el deslizar de las filas, la onda de la nota de voz y
  el «seguir el final» del hilo. Arrastres horizontales: `.panHorizontal` (`PanHorizontal.swift`,
  UIKit, sólo arranca de lado). Saber si el dedo arrastró una lista: `onScrollPhaseChange`.
  `onLongPressGesture` en filas también estorba: va como `simultaneousGesture`.
- **Sin pager** (`TabView .page`): se comía el deslizar a la derecha de las filas aunque se
  apagara con `scrollDisabled`. Las pestañas se cambian tocando la barra, como WhatsApp.
- **Aviso en frío**: `onChange(of: store.pestanaPedida, initial: true)`. Sin `initial`, un push
  con la app cerrada dejaba la lista en vez de abrir su conversación.
- **Notas de voz**: medidas aprobadas punto por punto en la memoria `nota-de-voz-ios-config` (no
  moverlas sin pedirlo). La transcripción es sólo para el agente: no se muestra. Una nota sin
  `meta` (llegó por los adjuntos del turno) se reconoce por el nombre `nota-de-voz…` y mide su
  duración al aparecer; la hora se guarda en el caché del hilo (`AdjuntoGuardado.creado`).
- **Paleta oficial** de ghosty.studio en `Theme.swift` (brand #8483E0, cuerpo blanco). Logos de
  integraciones: SVG convertidos de los vectores de Android (`logo-*.imageset`).
- **Pruebas de UI que cazan lo de arriba** (`GhostyAppUITests/NotaDeVozUITests.swift`,
  `BurbujaDeVozUITests.swift`): play de nota, deslizar izquierda/derecha, scroll de Chats, aviso
  en frío y foto de la burbuja. Correrlas antes de subir una build.
- **Capturas de la tienda**: `./scripts/capturas-tienda.sh` (simulador «Ghosty Max» 6.9", 9:41)
  y luego `python3 scripts/asc.py capturas`. «Qué hay de nuevo» no acepta emojis como ⭐.

## 🧪 Subagentes en el chat oficial (POC, 2026-10-07) — retomar el 8-oct

Ya no hay «Laboratorio» en Perfil (quitado el 8-oct): la barra sale en el **chat oficial** de
cualquier agente que gs marque con `subagentesNativos` en `/me/agents` (respaldo: PowerGhosty si
gs no lo manda; un 403 de la lista viva = no tiene). No hay chat propio: lo único nuevo es `Core/Chat/CapaDeSubagentes.swift`, una
barra encima del compositor («N agentes trabajando · reloj») con la hoja de la lista, el detalle de
cada uno, deslizar = Detener y «escríbele» (va por `store.send`, steer incluido). Mira la lista viva
por gs (`…/conversations/:id/subagents`, staff) y se reengancha al volver del fondo. Sólo aparece con
los agentes de `CapaDeSubagentes.agentesConSubagentes` (cajas con el POC).

- ⚠️ Lo que el agente dice solo al terminar un subagente todavía NO entra al hilo (gs no lo guarda):
  se ve en la hoja, sección «Lo que te dijo al terminar».
- Hojas **nunca transparentes** (regla de Brenda): `.presentationBackground(Color.gBg)`.
- ⚠️ Antes de repartirlo en TestFlight: parchar las cajas de todos (hoy sólo PowerGhosty trae el POC) y
  revisar que la lista viva (`…/subagents`) no sea sólo staff, o un tester no staff no verá la barra.
- Arreglado de paso: mandar tras subir a releer no re-prendía `siguiendoElFinal` (prueba
  `testMandarTrasSubirAReleer`). El «clavar arriba» que bliss reporta NO se reprodujo en simulador.
- Contexto y qué sigue: `~/ghosty-studio/docs/claude/subagentes-tipo-claude-code.md` §9-10.

## ⏰ Al publicarse la extensión de Chrome
Leer `NAVEGADOR-CHROME.md`: tarjeta «Conecta tu Chrome», estado de conexión y sugerencias. Hoy la app no necesita nada para que funcione.

## Sync v2 del historial (8-oct)
Contrato: `~/ghosty-studio/docs/claude/sync-v2.md` (lee sus desviaciones). Bandera remota `syncV2`
(apagada por defecto; en Debug `GHOSTY_SYNC_V2=1`). Con ella: el hilo se FUNDE por `seq`/`turnId`
(`Core/Data/Sync/ThreadMerge.swift`, nunca reemplazar), páginas `messages?after|before`, SSE con
`Last-Event-ID` + `?resume=1`, y «cargar anteriores» arriba. Siempre (con o sin bandera): base local
SQLite (`Core/Data/Store/LocalDB.swift`, GRDB, en el App Group), el `turnId` nace en el teléfono, las
listas de todos los agentes en una llamada (`/me/conversations?agentes=`) y sólo el agente visible
baja su hilo y abre SSE. Pruebas de `Core/`: `xcodebuild test -scheme GhostyCore`.
La suite de UI quedó al día con el rediseño de Chats el 12-oct (26/26): las pruebas entran al hilo
desde la lista (`abrirChat`), no suponen que la app arranca en el chat.

## 1.0.15 en revisión (22-oct)

Build 95 (resumen de la mañana + agente principal; contrato en `RESUMEN-DE-LA-MANANA.md`, gs e45c6deb) enviada a
revisión el 22-oct, salida AUTOMÁTICA, y repartida en TestFlight (Alpha). La 1.0.14 (build 94) ya salió:
`suggestBuild` quedó en 94 el 22-oct. Al salir la 1.0.15: `suggestBuild` a 95. Falta Android (pasarle el contrato).

## 1.0.13 en revisión (21-oct)

**Al día (21-oct):** se retiró la 1.0.12 y la **1.0.13 con la build 93** (todo `main` al d6f2e561: lo de la 89, la 91 y
la «Siguiente build» de abajo) está en revisión, salida AUTOMÁTICA; la 93 también está en TestFlight (Alpha). Al salir:
`suggestBuild` a 93.

## 1.0.13 en TestFlight (20-oct)

**Estado:** build 91 repartida en TestFlight (grupo Alpha) el 20-oct (bliss: «dale a todos los pendientes ya»), con «Te toca» con motivo.
La ficha de la tienda espera a que salga la 1.0.12 (en revisión): entonces `asc.py ficha 1.0.13 <id build>` →
`asc.py enviar-tienda`, y `suggestBuild` a 89.

**Qué lleva (pedido «sin avanzar», el #121):** `FactoryRunView` dice «Sin avanzar: nadie está trabajando» en
ámbar, en vez de «@build está construyendo…», cuando hay etapa de trabajo, `running` vacío y el último evento
es `stale`. Lleva «¿Qué pasó?» (gs `…/why`) y los botones «Retomar» y «Detener pedido» (`act resume|cancel`).
«Abrir el hilo» abre `FactoryThreadView` DENTRO de la app (en Safari pedía sesión): ahí el compositor le
escribe al rol del pedido (`@build`/`@check`). Prueba: `testPedidoSinAvanzarDemo` (demo #35).
Ya desplegado: Teams c14d3a5 (`factory-act` `resume|stop|cancel`, `runPersonAction`) y gs f0082097.
**También lleva (615a29e1) «Te toca» con motivo:** cada escalado trae `escalation {kind, reason, actions}` de gs
(`env|fix|skip|decision|platform`) y `needsYou` lo decide gs. Una falla de plataforma (preview atorada) sale gris
como «Esperando preview» y no cuenta. `skip` de Dependabot ofrece «Cerrar e ignorar» (`act close {ignore}`), `platform`
«Reintentar preview» (`act retry_preview`). Prueba `testTeTocaConMotivoDemo`. Ya desplegado: Teams 1be7da0, gs 81dcc712.
Origen: «Te toca 8» de easybits (20-oct), 5 eran un despliegue viejo `preview-157` que engañaba a `repoHasPreviews`.
El 🔁 de «Llevaba 30 min sin avanzar» que salía como cuadro con «?» es del SIMULADOR, no de la app: ahí ningún emoji se pinta, ni en un `Text` plano (probado el 20-oct). En el teléfono no aplica.

## Siguiente build (va en la próxima subida, NO la 91)

**👍/👎 por respuesta** (plan `sip-solido-y-completo-partitioned-avalanche`, §3): junto a copiar, en la última
respuesta (`RateButtons` en `ChatBubble.swift`, ids `rate-up`/`rate-down`, el elegido relleno; tocarlo otra vez lo
quita). El 👎 abre «¿Qué faltó?» opcional. Voto optimista en la tabla `feedback` de `LocalDB` (migración
`v2-feedback`, `FeedbackLedger`), se manda con `ClienteGS.rate` a `POST …/conversations/:id/feedback` y lo no enviado
se reintenta al volver del fondo y al entrar al hilo. Un 404 JSON (turno ajeno) se descarta; un 404 HTML (ruta aún
sin desplegar) se guarda. `myRating` de `…/messages` se pinta (sólo cuando viene: que falte no borra). Demo: sólo en
memoria. Prueba: paso 4-ter de `testRecorrido`.

**Tarjeta «Lugar» (cortesía de lugar, 21-oct)**: gs manda `slotNote {kind courtesy|queued, title, message, occupants,
position, ahead, chip, suggestUpgrade, plansUrl}` (spec `~/ghosty-studio/docs/claude/cortesia-de-lugar.md`). `FactoryRunView`
pinta quién ocupa cada lugar, «Va N en la fila», la ficha «Cortesía usada · se renueva…» y «Agregar 1 lugar»/«Ver planes»
(los dos abren `plansUrl`: el lugar extra aún no tiene precio). Pendiente «Avisar al admin». De paso: la etapa ya no dice
«Sin avanzar» en todo pedido planeando/construyendo (el `where` sólo aplicaba a `.checking`). Demos #45/#46, pruebas
`testLugarCortesiaDemo` y `testLugarEnFilaDemo`.

**Preview atorada en cualquier etapa** (#131 de easybits, 20-oct): tarjeta «Preview» en `FactoryRunView` con el motivo de gs
(`previewStatus {state, since, reason, stuck}`, gs 8274d671) y «Reintentar preview» (`retry-preview-card`, `act retry_preview`,
Teams 2e6ff9f: la pide YA y contesta `waiting` «esperando lugar de caja (N ocupados)» sin cambiar la etapa). No sale en un
escalado `platform` (ahí ya está su barra). Prueba `testPreviewAtoradaDemo` (demo #39).

## 1.0.12 en revisión (20-oct)

**Estado:** build 89 (todo `main` al 45ff036a) enviada a revisión el 20-oct; salida AUTOMÁTICA (`AFTER_APPROVAL`, cambiada
con la versión ya en `WAITING_FOR_REVIEW`: Apple lo acepta). Al salir: subir `suggestBuild` a 89. La 1.0.11 (build 84) está publicada; `suggestBuild` quedó en 84 el 21-oct.
«Qué hay de nuevo» no acepta ✓ (409 `INVALID_CHARACTERS`), igual que ⭐.

**Qué lleva:**
- **Intro de arranque** (`GhostyApp/Intro/LaunchIntro.swift`, interruptor `LaunchIntroGate.enabled`). Copia el
  arranque del pájaro de Twitter: la flamita se encoge y se abre como ventana por la que aparece la app.
  - ⚠️ El brinco que vio bliss en su iPhone era que, si la cuenta tardaba más de 3.2 s, la intro se fundía con
    `LaunchMark`, otra capa fuera de lugar. Ahora se queda en la pose del LaunchScreen hasta que la app está
    lista. Se mide con `GHOSTY_CARGA_LENTA` en un simulador NUEVO: el LaunchScreen se queda en caché y sólo
    se renueva reiniciando el simulador o el teléfono.
  - Todo sale de una sola geometría (`LaunchLockup` en `FlameLoading.swift`). `launch-mark.svg` se recortó para
    que flama y letras queden centradas.
- **Pedido bloqueado** (`FactoryRunView`): cuando @check escala con `check_blocked`, la app ya no ofrece
  «Que @build lo arregle». Ofrece:
  - «Copiar para mi agente de terminal»: los comandos `ghosty factory env …` por el portapapeles universal.
  - «O pégalas aquí»: `FactoryEnvSheet`.
  - «Que @check revise»: `recheck`.
  - Los hallazgos con JSON crudo se leen como texto. Prueba: `testEscaladoBloqueadoDemo`.

- Whoosh de la intro sólo la primera vez tras instalar o actualizar (respeta el silencio) y háptico en cada arranque.
- El pedido en PR enseña su CI (#119) y el merge en cola espera al CI (#120).

**Lado servidor de lo mismo, ya desplegado:**
- Teams: `factory-act` `recheck|env` y `api/internal/factory-env`.
- gs: `…/factory/env`; `env-set` con `merge`; la preview corre `prisma migrate deploy` contra una base LOCAL.
- CLI 0.77.0: `factory env ls|push`, `runs recheck`.
- La preview de `blissito/ghosty-studio` ya tiene variables desechables (SQLite en la caja, llaves generadas,
  `SANDBOX_HOST_TOKEN` falso) y arranca. El 20-oct se pidió `recheck` del #125, #120 y #119.

**Idea aprobada en plática, sin construir:** que la preparación del repo termine cuando la preview arranca en
verde. Las variables se dividen en tres clases: llaves al azar (se generan), infraestructura (base dentro de
la caja, ya hay `services:`/`db:` en `.ghosty/factory.md`) y terceros (las da una persona desde la compu). El
agente lo deja en el manifiesto del repo en un PR.

