#!/bin/zsh
# Called before signing the outer bundle. Cove is not App Sandbox-enabled.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 3 ]] || { print -u2 'Usage: embed-sparkle.sh APP IDENTITY DISTRIBUTION'; exit 1; }
cove_target="$1/Contents/Frameworks/Sparkle.framework"
cove_source="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$cove_source" ]] || { print -u2 'Resolve Swift packages first.'; exit 1; }
mkdir -p "$1/Contents/Frameworks"
ditto "$cove_source" "$cove_target"
cp "$PWD/.build/artifacts/sparkle/Sparkle/LICENSE" "$1/Contents/Resources/Sparkle-LICENSE.txt"
# Optional XPC services are only used by sandboxed apps; keep the installer helpers.
rm -rf "$cove_target/Versions/B/XPCServices" "$cove_target/XPCServices"
cove_flags=(--force --sign "$2" --options runtime)
[[ -n "${COVE_SIGNING_KEYCHAIN:-}" ]] && cove_flags+=(--keychain "$COVE_SIGNING_KEYCHAIN")
if [[ "$3" == 1 ]]; then cove_flags+=(--timestamp); fi
for cove_nested in "$cove_target/Versions/B/Autoupdate" "$cove_target/Versions/B/Updater.app" "$cove_target"; do
  codesign "${cove_flags[@]}" "$cove_nested"
done
codesign --verify --deep --strict "$cove_target"
