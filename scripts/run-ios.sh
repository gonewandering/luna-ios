#!/bin/zsh
set -eu
if [[ "${1:-}" != "" && "${1:-}" != "--connect" ]]; then
  print -u2 'Usage: ./scripts/run-ios.sh [--connect]'
  exit 2
fi
LUNA_ROOT="${0:A:h:h}"
cd "$LUNA_ROOT"
LUNA_DEVICE="${LUNA_SIMULATOR_UDID:-$(python3 - <<'PY'
import json,subprocess
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
choices=[]
for runtime, rows in devices.items():
    if 'iOS-' not in runtime: continue
    major=int(runtime.split('iOS-')[-1].split('-')[0])
    if major < 18: continue
    choices.extend((d['state']=='Booted',major,d['udid']) for d in rows if d['name'].startswith('iPhone'))
if not choices: raise SystemExit('Install an iOS 18 or newer simulator in Xcode.')
print(sorted(choices,reverse=True)[0][2])
PY
)}"
if [[ "$(xcrun simctl list devices booted)" != *"$LUNA_DEVICE"* ]]; then
  xcrun simctl boot "$LUNA_DEVICE"
fi
xcrun simctl bootstatus "$LUNA_DEVICE" -b
(cd ios && xcodegen generate)
xcodebuild -project ios/Luna.xcodeproj -scheme Luna \
  -destination "platform=iOS Simulator,id=$LUNA_DEVICE" \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
xcrun simctl install "$LUNA_DEVICE" build/Build/Products/Debug-iphonesimulator/Luna.app
if [[ "${1:-}" == "--connect" ]]; then
  LUNA_SIMULATOR_DEVICE="$LUNA_DEVICE" .venv/bin/python - <<'PY'
import os, subprocess
from dotenv import dotenv_values
values = dotenv_values('service/.env')
key = values.get('HERMES_API_KEY')
if not key:
    raise SystemExit('Configure service/.env with HERMES_BASE_URL and HERMES_API_KEY, or enter them in the app.')
environment = os.environ.copy()
environment['SIMCTL_CHILD_LUNA_HERMES_URL'] = values.get('HERMES_BASE_URL', '')
environment['SIMCTL_CHILD_LUNA_HERMES_KEY'] = key
environment['SIMCTL_CHILD_LUNA_OPENAI_KEY'] = os.environ.get('OPENAI_API_KEY') or values.get('OPENAI_API_KEY') or ''
subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process',
                os.environ['LUNA_SIMULATOR_DEVICE'], 'dev.luna.ios'], env=environment, check=True)
PY
else
  xcrun simctl launch --terminate-running-process "$LUNA_DEVICE" dev.luna.ios --demo
fi
open -a Simulator --args -CurrentDeviceUDID "$LUNA_DEVICE"
