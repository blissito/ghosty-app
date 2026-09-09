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
SIGUIENTE=$(( ACTUAL + 1 ))
echo "build $SIGUIENTE (allá arriba había $ACTUAL)"

xcodegen generate
xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination 'generic/platform=iOS' -archivePath build/GhostyApp.xcarchive \
  -clonedSourcePackagesDirPath .spm -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$SIGUIENTE" archive

xcodebuild -exportArchive -archivePath build/GhostyApp.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/ipa \
  -allowProvisioningUpdates

xcrun altool --upload-app -f build/ipa/GhostyApp.ipa -t ios \
  --apiKey "$KEY" --apiIssuer "$ISS"

echo "listo. Apple tarda 5-15 min en procesarlo."
