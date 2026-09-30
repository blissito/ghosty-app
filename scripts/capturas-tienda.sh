#!/bin/bash
# Capturas de la App Store (iPhone 6.9", 1320×2868) desde la demo, sin tocar la pantalla.
#
#   ./scripts/capturas-tienda.sh            # deja los PNG en metadata/capturas/
#   python3 scripts/asc.py capturas         # y los sube a la versión en preparación
#
# Usa un simulador «Ghosty Max» (iPhone 17 Pro Max; lo crea si no existe), la barra de estado
# fija en 9:41 con batería llena, y los ganchos de desarrollo (`GHOSTY_DEMO`, `GHOSTY_DEMO_CHAT`,
# `GHOSTY_TAB`) para abrir cada pantalla. Revisa los PNG antes de subirlos: la demo cambia
# con la app.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

NOMBRE="Ghosty Max"
SIM=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
for v in json.load(sys.stdin)['devices'].values():
    for x in v:
        if x['name']=='$NOMBRE': print(x['udid']); raise SystemExit")
if [ -z "$SIM" ]; then
  TIPO=$(xcrun simctl list devicetypes | grep -E "iPhone 17 Pro Max \(" | head -1 | sed -E 's/.*\((com[^)]*)\).*/\1/')
  RUNTIME=$(xcrun simctl list runtimes | grep -oE "com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+" | tail -1)
  SIM=$(xcrun simctl create "$NOMBRE" "$TIPO" "$RUNTIME")
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3

xcodegen generate -q
xcodebuild -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build-sim \
  -clonedSourcePackagesDirPath .spm build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl install "$SIM" "$(find build-sim/Build/Products -maxdepth 2 -name GhostyApp.app | head -1)"

OUT=metadata/capturas
rm -f "$OUT"/*.png
foto() {
  local nombre=$1; shift
  env "$@" xcrun simctl launch --terminate-running-process "$SIM" com.fixtergeek.ghostyapp \
    -ai.consentGiven YES >/dev/null
  sleep 6
  xcrun simctl io "$SIM" screenshot "$OUT/$nombre.png" >/dev/null 2>&1
  echo "$OUT/$nombre.png"
}
D=SIMCTL_CHILD_GHOSTY_DEMO=1
foto 1-chats    $D
foto 2-vacio    $D SIMCTL_CHILD_GHOSTY_DEMO_CHAT=vacio
foto 3-tarea    $D SIMCTL_CHILD_GHOSTY_DEMO_CHAT=1
foto 4-tabla    $D SIMCTL_CHILD_GHOSTY_DEMO_CHAT=tabla
foto 5-perfil    $D SIMCTL_CHILD_GHOSTY_TAB=perfil
xcrun simctl status_bar "$SIM" clear
