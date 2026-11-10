#!/bin/bash
# Source this file from repository scripts. These synthetic identities belong
# only to simulator tests; device builds use their normal signing configuration.

prepare_simulator_signing() {
  local entitlements="$root/build/simulator.entitlements"
  mkdir -p "$root/build"
  python3 - "$entitlements" <<'PY'
import pathlib, plistlib, sys
identity = 'SNOWLITCI1.$(PRODUCT_BUNDLE_IDENTIFIER)'
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'application-identifier': identity,
    'keychain-access-groups': [identity],
    'get-task-allow': True,
}))
PY
  simulator_signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    "CODE_SIGN_ENTITLEMENTS=$entitlements")
}

record_simulator_signing() {
  local app="$root/build/app-$kind/Build/Products/Debug-iphonesimulator/Snowlit.app"
  local output="$evidence/simulator-signing"
  mkdir -p "$output"
  codesign --verify --verbose=2 "$app" > "$output/verification.log" 2>&1
  codesign -d --verbose=4 "$app" > "$output/signature.log" 2>&1
  # The simulator also uses entitlements embedded by Xcode in the executable.
  # Preserve and check Xcode's expanded host inputs, not just the source plist.
  python3 - "$root/build/app-$kind" "$output" <<'PY'
import json, pathlib, plistlib, sys
derived, output = map(pathlib.Path, sys.argv[1:])
expected = 'SNOWLITCI1.io.github.bemarkt.snowlit'
records = []
for path in sorted(derived.glob('Build/Intermediates.noindex/Snowlit.build/Debug-iphonesimulator/Snowlit.build/*.xcent')):
    data = path.read_bytes()
    values = plistlib.loads(data)
    (output / path.name).write_bytes(data)
    records.append({'path': str(path.relative_to(derived)), 'entitlements': values})
assert any(record['entitlements'].get('application-identifier') == expected
           and expected in record['entitlements'].get('keychain-access-groups', [])
           for record in records), 'Simulator host is missing its expanded Keychain identity'
(output / 'inputs.json').write_text(json.dumps(records, indent=2) + '\n')
PY
}
