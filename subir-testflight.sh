#!/bin/bash
# Sube un build a TestFlight. La llave vive en ~/.appstoreconnect/private_keys
# (0600, fuera del repo) y aquí sólo van sus identificadores públicos.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"

KEY=BYJDNZWD5L
ISS=69a6de85-8e77-47e3-e053-5b8c7c11a4d1

# El número de build tiene que subir en cada envío o App Store Connect lo rechaza
# por duplicado. Se toma el que ya está allá arriba y se le suma uno.
#
# ⚠️ Sale de `asc.py builds` y NO de `altool --list-builds`, que es lo que había: altool
# devolvió vacío sin dar error, el `${ACTUAL:-0}` cayó a 0 y el script se puso a archivar
# como **build 1** — veinte minutos de compilación para que App Store Connect lo rechace
# por duplicado al final. Un listado vacío no es "no hay ninguna".
ACTUAL=$(python3 scripts/asc.py builds 2>/dev/null | grep -oE '^build +[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
[ -n "$ACTUAL" ] || { echo "✗ no pude leer las builds de App Store Connect; abortando para no subir un número repetido" >&2; exit 1; }

# ⚠️ App Store Connect NO lista una build mientras la procesa, y procesar puede tardar más
# de una hora. Dos subidas seguidas dentro de esa ventana calculaban el MISMO número y la
# segunda se rechazaba por duplicada — pasó el 2026-09-09 con la 22, dos veces. Por eso el
# número no sale sólo de allá arriba: se recuerda el último usado AQUÍ y se toma el mayor
# de los dos. El fichero no se versiona; si se pierde, lo peor es volver al caso viejo.
ULTIMA=$(cat .ultima-build 2>/dev/null || echo 0)
BASE=$(( ACTUAL > ULTIMA ? ACTUAL : ULTIMA ))
SIGUIENTE=$(( BASE + 1 ))
echo "$SIGUIENTE" > .ultima-build
echo "build $SIGUIENTE (procesadas: $ACTUAL · última que subí: $ULTIMA)"

# ⚠️ El commit se estampa TAMBIÉN aquí, no sólo en `instalar.sh`. Sin esto, Ajustes
# enseña "Ghosty x (build N)" a secas y no hay forma de saber qué código trae un teléfono
# que no está enchufado — que es exactamente lo que impidió confirmar un diagnóstico el
# 2026-09-09.
SHA=$(git rev-parse --short HEAD)

xcodegen generate
xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination 'generic/platform=iOS' -archivePath build/GhostyApp.xcarchive \
  -clonedSourcePackagesDirPath .spm -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$SIGUIENTE" GHOSTY_COMMIT="$SHA" archive

xcodebuild -exportArchive -archivePath build/GhostyApp.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/ipa \
  -allowProvisioningUpdates

# ⚠️ Se COMPRUEBA el número dentro del .ipa antes de subir. Sin esto el fallo es MUDO:
# altool dice UPLOAD SUCCEEDED, App Store Connect ignora el paquete por traer un número
# que ya existe, y no llega ningún correo — la build simplemente no aparece nunca. Así se
# perdieron tres el 2026-09-09 antes de encontrarlo.
DENTRO=$(unzip -p build/ipa/GhostyApp.ipa 'Payload/GhostyApp.app/Info.plist' | plutil -extract CFBundleVersion raw -o - -- - 2>/dev/null)
if [ "$DENTRO" != "$SIGUIENTE" ]; then
  echo "✗ el .ipa lleva build $DENTRO y esperaba $SIGUIENTE — no lo subo" >&2
  echo "  (mira CFBundleVersion en project.yml: tiene que ser \$(CURRENT_PROJECT_VERSION))" >&2
  exit 1
fi
echo "el .ipa lleva build $DENTRO ✓"

# ⚠️ VALIDAR ANTES DE SUBIR. `--upload-app` dice `UPLOAD SUCCEEDED` en cuanto el paquete
# viaja, y lo que lo rechaza después es MUDO: no hay correo y la build no aparece ni en
# "Build Uploads" de App Store Connect. `--validate-app` da el mismo veredicto de forma
# SÍNCRONA, en segundos.
#
# El caso real (2026-09-09): «Upload limit reached. The upload limit for your application
# has been reached. Please wait 1 day and try again.» Apple tiene un TOPE DIARIO de subidas
# por app y ese día se agotó con 21 builds. Cuatro horas creyendo que Apple iba lento, y
# dos diagnósticos equivocados, por no preguntar antes de mandar.
echo "validando el paquete…"
if ! xcrun altool --validate-app -f build/ipa/GhostyApp.ipa -t ios \
     --apiKey "$KEY" --apiIssuer "$ISS" 2>&1 | tee /tmp/gs-validate.log | grep -q "No errors validating"; then
  echo "✗ Apple rechazó el paquete al validarlo. Motivo:" >&2
  grep -iE "ERROR: \[altool|detail :" /tmp/gs-validate.log | head -3 >&2
  exit 1
fi
echo "paquete válido ✓"

xcrun altool --upload-app -f build/ipa/GhostyApp.ipa -t ios \
  --apiKey "$KEY" --apiIssuer "$ISS"

# ⚠️ SUBIR NO ES REPARTIR. Una build recién procesada queda VALID en App Store Connect y
# NO la ve ni un tester: sin grupo asignado, TestFlight sigue enseñando la anterior. Y no
# hay señal de nada — `asc.py builds` la lista igual que a las repartidas.
#
# Por eso se espera a que Apple la procese (VALID; 5-15 min) y se asigna al grupo aquí
# mismo. Dejarlo "para después" es exactamente cómo se pierde media hora buscando un fallo
# de la app que no existe.
GRUPO=$(python3 scripts/asc.py groups | awk '$1=="Taller"{print $NF}' | cut -d= -f2)
[ -n "$GRUPO" ] || { echo "✗ no encuentro el grupo Taller; asigna a mano con: asc.py asignar <buildId> <grupoId>" >&2; exit 1; }

echo "esperando a que Apple procese la build $SIGUIENTE…"
for _ in $(seq 1 60); do   # hasta 20 min
  ID=$(python3 scripts/asc.py builds 2>/dev/null | awk -v v="$SIGUIENTE" '$2==v && $3=="VALID"{print $NF}' | cut -d= -f2)
  [ -n "$ID" ] && break
  sleep 20
done

if [ -n "$ID" ]; then
  python3 scripts/asc.py asignar "$ID" "$GRUPO"
  echo "listo: build $SIGUIENTE repartida al grupo Taller."
else
  echo "⚠ la build $SIGUIENTE sigue procesando. Cuando esté VALID, repártela:" >&2
  echo "   python3 scripts/asc.py builds   # copia su id" >&2
  echo "   python3 scripts/asc.py asignar <buildId> $GRUPO" >&2
fi
