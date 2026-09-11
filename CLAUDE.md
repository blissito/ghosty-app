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

## El turno es del SERVIDOR, no del teléfono

La app habla HTTP+SSE con gs (`ClienteGS`), no WebSocket con la caja. Eso no es un detalle
de tuberías: **el teléfono se duerme**, y con el socket directo el turno moría con él
(medido: cero caracteres al volver). En gs el turno sobrevive, el SSE es re-suscribible, y
al volver sólo hay que preguntar qué pasó.

De ahí salen las reglas que quedan:

- **No hay nada que «recuperar».** Si el trabajo nunca fue nuestro, irse no requiere cerrar
  nada ni apuntar deudas. Se quitaron ~900 líneas que existían para eso.
- **El estado lo dice el servidor** (evento `status`), no se infiere de si queda un turno
  local. Inferirlo ponía «Sigue trabajando…» encima de conversaciones en reposo.
- **Nadie cambia de conversación por debajo.** Eso se veía como «se borró el historial al
  enviar»: no se borraba, cambiaba el hilo y el mensaje se quedaba en el anterior.
- Ver `NOTAS-DEL-RELE.md` para el contrato y los filos del SSE.

## Verificar en el simulador sin poder tocar la pantalla

Hay ganchos de desarrollo por variable de entorno, porque el simulador no acepta toques por
script (`SIMCTL_CHILD_<VAR>` al lanzar):

| Variable | Qué hace |
|---|---|
| `GHOSTY_PROBE="texto"` | manda ese mensaje al arrancar |
| `GHOSTY_ADJUNTOS=imagen\|archivo\|ambos` | lo manda CON adjuntos sintéticos |
| `GHOSTY_TAB=chat\|conversations\|artifacts\|connectors` | abre esa pestaña (`fleet` ya no existe) |
| `GHOSTY_SHEET=1` + `GHOSTY_PANE=activity\|permissions` | abre la hoja del agente en ese panel |
| `GHOSTY_CONECTORES=demo` | llena Integraciones para poder mirarla |
| `GHOSTY_CORTAR=8` | mata el socket a los 8 s, como hace iOS al suspender la app |
| `GHOSTY_DEMO_INTERRUMPIDO=1` | pinta un hilo cortado por la suspensión (con el cartel) |
| `GHOSTY_PUSH=1` | se registra en APNs sin esperar al diálogo del permiso |
| `GHOSTY_SILENCIO=20` | da el turno por cortado tras 20 s sin eventos (por defecto, 8 min) |
| `GHOSTY_NUEVA=1` | arranca en una conversación nueva (crear sesión + primer turno) |
| `GHOSTY_TOKEN=<bearer>` | presta una sesión sin pasar por el login (sólo Debug) |
| `GHOSTY_SOLO_AGENTE=<id>` | la app sólo ve ESE agente |
| `GHOSTY_AUTO_PERMISO=1` | contesta los permisos solo, para poder probar el camino entero |
| `GHOSTY_AVISO=<agente>/<sesion>` | simula tocar un push con la app CERRADA (el push del simulador arranca sin variables) |

⚠️ **Los cuatro últimos juntos son lo que permite verificar la app contra el servidor de
verdad sin la sesión de nadie.** Un token de la cuenta real alcanza a TODOS sus agentes,
incluida la caja que alguien esté usando en su teléfono: `GHOSTY_SOLO_AGENTE` es más fiable
que acordarse de no tocarla.

```bash
SIMCTL_CHILD_GHOSTY_TOKEN=… SIMCTL_CHILD_GHOSTY_SOLO_AGENTE=… \
SIMCTL_CHILD_GHOSTY_TRANSPORTE=gs SIMCTL_CHILD_GHOSTY_PROBE="hola" \
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
