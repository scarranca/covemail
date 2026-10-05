#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
# The Command Line Tools' macOS 27 SDK lacks SwiftUI's macro plugin (@State), so builds use Xcode when installed.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build
cove_bin=$(swift build --show-bin-path)
cove_stage=$(mktemp -d "$PWD/dist/.qa-build.XXXXXX")
trap 'rm -rf "$cove_stage"' EXIT
cove_app="$cove_stage/Cove QA.app"
mkdir -p "$cove_app/Contents/MacOS" "$cove_app/Contents/Resources"
python3 scripts/write-app-info.py "$cove_app/Contents/Info.plist"
python3 - "$cove_app/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]); info=plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier='ai.cove.qa', CFBundleName='Cove QA', CFBundleDisplayName='Cove QA')
p.write_bytes(plistlib.dumps(info))
PY
cp "$cove_bin/Cove" "$cove_app/Contents/MacOS/Cove"
ditto "$cove_bin/Cove_Cove.bundle" "$cove_app/Contents/Resources/Cove_Cove.bundle"
cp assets/AppIcon/Cove.icns "$cove_app/Contents/Resources/Cove.icns"
zsh scripts/embed-sparkle.sh "$cove_app" - 0
codesign --force --entitlements assets/Cove.entitlements --sign - "$cove_app"
if [[ -e 'dist/Cove QA.app' ]]; then mv 'dist/Cove QA.app' "$cove_stage/Previous.app"; fi
mv "$cove_app" 'dist/Cove QA.app'
print 'Built isolated dist/Cove QA.app. Launch and select Explore a sample inbox.'
