#!/bin/bash
# Compila e instala en el iPhone de Héctor por cable. Con la membresía de pago el
# perfil dura un año, así que esto no caduca a los 7 días como el plan gratis.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
DEV=1B485C25-0A85-5E8F-8950-7C415C3B5CA2
UDID=00008030-001241D211C3802E

# El build por cable estampa el commit: sin esto todos reportan "1" y no hay forma
# de saber qué código tiene el teléfono. Ya me llevó a un diagnóstico equivocado.
SHA=$(git rev-parse --short HEAD)
N=$(git rev-list --count HEAD)
echo "instalando $SHA (build $N)"

xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination "platform=iOS,id=$UDID" -derivedDataPath build \
  -clonedSourcePackagesDirPath .spm -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$N" GHOSTY_COMMIT="$SHA" build

APP=$(find build/Build/Products/Debug-iphoneos -maxdepth 1 -name "GhostyApp.app" | head -1)
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" --terminate-existing com.fixtergeek.ghostyapp
