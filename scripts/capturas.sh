#!/bin/bash
# Corre el recorrido de UI tests y deja las capturas con nombre legible.
#
# ⚠️ Es la única forma que tiene un agente de VER esta app: sin esto sólo se verifica
# que compile, y los fallos de esta app han sido de interacción, no de lógica.
set -e
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
SIM=${1:-$(xcrun simctl list devices available -j | python3 -c "
import json,sys
for k,v in json.load(sys.stdin)['devices'].items():
    for x in v:
        if x['name'].startswith('iPhone'): print(x['udid']); raise SystemExit")}
xcodebuild test -project GhostyApp.xcodeproj -scheme GhostyApp \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build-sim -clonedSourcePackagesDirPath .spm 2>&1 | tail -5
R=$(ls -td build-sim/Logs/Test/*.xcresult | head -1)
rm -rf build-sim/capturas
xcrun xcresulttool export attachments --path "$R" --output-path build-sim/capturas >/dev/null
cd build-sim/capturas && python3 - <<'PY'
import json,os,shutil
m=json.load(open('manifest.json'))
def walk(o):
    if isinstance(o,dict):
        if 'exportedFileName' in o and 'suggestedHumanReadableName' in o:
            yield o['exportedFileName'], o['suggestedHumanReadableName']
        for v in o.values(): yield from walk(v)
    elif isinstance(o,list):
        for v in o: yield from walk(v)
for f,n in walk(m):
    limpio=n.split('_')[0]+'.png'
    if os.path.exists(f) and limpio[0].isdigit(): shutil.copy(f,limpio); print(limpio)
PY
