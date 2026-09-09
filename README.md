# Ghosty App

Prototipo estático de la app iOS de Ghosty: las cinco pantallas para juzgarlas en un
teléfono de verdad. **Cero red, cero ACP, cero push** — los datos están cableados en
`GhostyApp/Data/MockData.swift`.

## Correrlo

```bash
brew install xcodegen      # una vez
xcodegen generate          # crea GhostyApp.xcodeproj (no se versiona)
open GhostyApp.xcodeproj
```

En Xcode: target `GhostyApp` → Signing & Capabilities → **Automatically manage signing**
→ Team = tu *Personal Team*. Luego ⌘R.

## En un iPhone físico, sin cuenta de pago

1. Xcode → Settings → Accounts → `+` → tu Apple ID normal.
2. Conecta el teléfono por cable y confía en la Mac.
3. ⚠️ **iOS 16+**: Ajustes → Privacidad y seguridad → **Modo de desarrollador** → activar
   → reiniciar. La opción **sólo aparece** después de que Xcode intente instalar una app
   de desarrollo al menos una vez.
4. La primera instalación falla con *Untrusted Developer*: Ajustes → General → VPN y
   gestión de dispositivos → Apple Development → **Confiar**. Vuelve a correr.

El perfil de Personal Team **caduca a los 7 días**: después hay que reinstalar desde
Xcode. Máximo 3 apps así por dispositivo, y no se puede repartir a nadie más.

## La frontera que importa

`Data/AgentStore.swift` define el protocolo `AgentStoring`. Las vistas sólo hablan con
él, y todos sus métodos son `async` **desde ya** aunque el mock responda inmediato — el
día del cliente ACP real se añade `Data/ACP/ACPAgentStore.swift` y se cambia una línea en
`GhostyApp.swift`. Ninguna vista conoce `MockData`.

---

## Estado: funcionando contra la caja real

Verificado el 2026-09-08 en el simulador de iPhone 17 (iOS 26.1), hablando con el
agente `lite-prueba-skills` de EasyBits: turno completo, respuesta en trozos y
markdown renderizado (encabezado, negrita, código en línea, viñetas, tabla, bloque
`swift` con su etiqueta y cita).

### Correrlo

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' \
  -derivedDataPath build -clonedSourcePackagesDirPath .spm build

SIM=$(xcrun simctl list devices available | grep -m1 "iPhone 17 (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/GhostyApp.app

# La llave NUNCA va en el binario: viaja como variable del proceso hijo.
SIMCTL_CHILD_EASYBITS_API_KEY=eb_sk_live_… \
SIMCTL_CHILD_GHOSTY_AGENT_ID=<agentId> \
xcrun simctl launch --terminate-running-process "$SIM" com.fixtergeek.ghostyapp
```

Variables opcionales: `GHOSTY_PROBE="texto"` manda ese mensaje al arrancar (así se
verifica un turno sin teclear) y `GHOSTY_DIAG=1` enciende el registro del transporte,
que se lee con:

```bash
xcrun simctl spawn "$SIM" log show --last 1m \
  --predicate 'eventMessage CONTAINS "[ghosty-acp]"' --style compact
```

## Lo que NO se reinventó

| Pieza | Librería | Por qué |
|---|---|---|
| Markdown | [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) 2.4 (MIT) | GFM completo: tablas, bloques de código, listas. Aquí sólo vive el TEMA con los tokens de Ghosty |
| Parser CommonMark | swift-cmark (vía la anterior) | El de Apple, el mismo que usa Xcode |
| Imágenes remotas | NetworkImage (vía la anterior) | — |

**El lector de SSE sí es propio, y son 30 líneas**: `URLSession.bytes(for:).lines` ya
es el camino idiomático. `LDSwiftEventSource` añade reconexión y reintento, que un
turno único no necesita.

## Dos trampas que costaron la noche

⚠️ **HTTP/3 se come el streaming.** Por QUIC, `URLSession.bytes` no entregaba el
cuerpo por trozos: el turno se quedaba colgado **sin error y sin timeout**, mientras
el mismo `curl` contestaba. Se arregla con `req.assumesHTTP3Capable = false`
(va en la *request*, no en la configuración de sesión) más una sesión `.ephemeral`
sin caché. Firma para reconocerlo: la petición abre, llegan las cabeceras 200, y el
iterador de líneas no produce nada nunca.

⚠️ **El primer trozo de un stream de markdown es `"##"`, sin el espacio.** El parser
propio que había antes lo rechazaba como encabezado, caía al párrafo, el párrafo
rompía al ver `#` y **no avanzaba el índice**: bucle infinito en el hilo principal, y
la app congelada en el primer chunk de cualquier respuesta con markdown. Fue una de
las razones para pasar a la librería.

## Subir a TestFlight

```bash
./subir-testflight.sh     # compila, sube, espera el VALID y la reparte al grupo Taller
```

⚠️ **Dos fallos MUDOS que ya costaron una tarde (2026-09-09). Los dos están cerrados en el
script; esto es para reconocerlos si vuelven:**

1. **Subir NO es repartir.** Una build queda `VALID` y no la ve ningún tester hasta que se
   asigna a un grupo. El script lo hace solo; si Apple tarda más de 20 min en procesar,
   imprime los comandos para hacerlo a mano.

2. **El `.ipa` puede salir con OTRO número de build.** `CFBundleVersion` en `project.yml`
   tiene que ser `$(CURRENT_PROJECT_VERSION)`; si es un literal, xcodegen lo hornea y el
   número que pasa el script no llega. App Store Connect entonces **descarta el paquete por
   duplicado SIN mandar correo**: `UPLOAD SUCCEEDED` y la build no aparece jamás. El script
   ahora lee el número de dentro del `.ipa` y aborta si no coincide.

**Dónde mirar de verdad**: `https://appstoreconnect.apple.com/apps/6810017404/testflight/ios`.
La API (`scripts/asc.py builds`) **no lista** lo que está procesando, así que "no aparece"
no distingue entre procesando y perdido.

**Por cable**, sin depender de Apple: `./instalar.sh`.

