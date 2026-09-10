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

## Verificar en el simulador sin poder tocar la pantalla

Hay ganchos de desarrollo por variable de entorno, porque el simulador no acepta toques por
script (`SIMCTL_CHILD_<VAR>` al lanzar):

| Variable | Qué hace |
|---|---|
| `GHOSTY_PROBE="texto"` | manda ese mensaje al arrancar |
| `GHOSTY_ADJUNTOS=imagen\|archivo\|ambos` | lo manda CON adjuntos sintéticos |
| `GHOSTY_TAB=chat\|fleet\|artifacts\|connectors` | abre esa pestaña |
| `GHOSTY_SHEET=1` + `GHOSTY_PANE=activity\|permissions\|history\|memory` | abre la hoja del agente en ese panel |
| `GHOSTY_CONECTORES=demo` | llena Integraciones para poder mirarla |

⚠️ Un dato de prueba sintético **se comprueba contra el consumidor real**: un PNG que `file`
y PIL daban por bueno el modelo lo rechazaba por dañado, y casi doy por rota la ruta de
imágenes por culpa de mi propio dato.
