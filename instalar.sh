#!/bin/bash
# Compila e instala en el iPhone de Héctor por cable. Con la membresía de pago el
# perfil dura un año, así que esto no caduca a los 7 días como el plan gratis.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")"
DEV=1B485C25-0A85-5E8F-8950-7C415C3B5CA2
UDID=00008030-001241D211C3802E

xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination "platform=iOS,id=$UDID" -derivedDataPath build \
  -clonedSourcePackagesDirPath .spm -allowProvisioningUpdates build

APP=$(find build/Build/Products/Debug-iphoneos -maxdepth 1 -name "GhostyApp.app" | head -1)
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" --terminate-existing com.fixtergeek.ghostyapp
