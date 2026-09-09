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
ACTUAL=$(xcrun altool --list-builds --apiKey "$KEY" --apiIssuer "$ISS" 2>/dev/null \
  | grep -oE '"buildNumber" : "[0-9]+"' | grep -oE '[0-9]+' | sort -n | tail -1)
SIGUIENTE=$(( ${ACTUAL:-0} + 1 ))
echo "build $SIGUIENTE (allá arriba había ${ACTUAL:-ninguno})"

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
