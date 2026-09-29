#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
cove_app="$PWD/dist/distribution/Cove.app"
codesign --verify --deep --strict "$cove_app"
xcrun stapler validate "$cove_app"
cove_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$cove_app/Contents/Info.plist")
cove_identity="${COVE_SIGNING_IDENTITY:-}"
if [[ -z "${COVE_SIGNING_KEYCHAIN:-}" ]] && security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" | grep -qF "Developer ID Application:"; then
  COVE_SIGNING_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fi
cove_keychain_args=()
[[ -n "${COVE_SIGNING_KEYCHAIN:-}" ]] && cove_keychain_args=(--keychain "$COVE_SIGNING_KEYCHAIN")
if [[ -z "$cove_identity" ]]; then
  cove_identities=("${(@f)$(security find-identity -v -p codesigning ${COVE_SIGNING_KEYCHAIN:+"$COVE_SIGNING_KEYCHAIN"} | awk '/Developer ID Application:/ {print $2}' | sort -u)}")
  (( ${#cove_identities} == 1 )) && [[ -n "${cove_identities[1]}" ]] || {
    print -u2 'Set COVE_SIGNING_IDENTITY to the intended Developer ID Application identity.'
    exit 1
  }
  cove_identity="${cove_identities[1]}"
fi
cove_stage=$(mktemp -d "$PWD/dist/distribution/.dmg-build.XXXXXX")
trap 'rm -rf "$cove_stage"' EXIT
mkdir "$cove_stage/payload"
ditto "$cove_app" "$cove_stage/payload/Cove.app"
ln -s /Applications "$cove_stage/payload/Applications"
hdiutil create -volname Cove -srcfolder "$cove_stage/payload" -fs HFS+ \
  -format UDZO "$cove_stage/Cove.dmg"
codesign --sign "$cove_identity" --timestamp "${cove_keychain_args[@]}" "$cove_stage/Cove.dmg"
codesign --verify --strict "$cove_stage/Cove.dmg"
codesign -dvv "$cove_stage/Cove.dmg" 2>&1 | rg '^Authority=Developer ID Application:'
cove_dmg="$PWD/dist/distribution/Cove-$cove_version.dmg"
mv "$cove_stage/Cove.dmg" "$cove_dmg"
print "Signed disk image, ready for notarization: $cove_dmg"
print 'Submit this DMG once with notarytool, then run scripts/finish-dmg.sh DMG_PATH SUBMISSION_ID KEYCHAIN_PROFILE.'
