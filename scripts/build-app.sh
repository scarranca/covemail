#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

cove_distribution="${COVE_DISTRIBUTION:-0}"
cove_signing_identity="${COVE_SIGNING_IDENTITY:-}"
cove_identity_label='Apple Development:'
cove_output_dir="$PWD/dist"
if [[ "$cove_distribution" == 1 ]]; then
  cove_identity_label='Developer ID Application:'
  cove_output_dir="$PWD/dist/distribution"
fi
if [[ -z "$cove_signing_identity" ]]; then
  cove_identities=("${(@f)$(security find-identity -v -p codesigning | awk -v label="$cove_identity_label" 'index($0,label) {print $2}')}")
  if (( ${#cove_identities} == 1 )) && [[ -n "${cove_identities[1]}" ]]; then
    cove_signing_identity="${cove_identities[1]}"
  else
    print -u2 "Set COVE_SIGNING_IDENTITY to the intended $cove_identity_label certificate name or SHA-1."
    exit 1
  fi
fi
if [[ "$cove_distribution" == 1 && "$cove_signing_identity" == '-' ]]; then
  print -u2 'Distribution builds require Developer ID signing.'
  exit 1
fi
mkdir -p "$cove_output_dir"
cove_stage=$(mktemp -d "$cove_output_dir/.cove-build.XXXXXX")
trap 'rm -rf "$cove_stage"' EXIT
cove_app="$cove_stage/Cove.app"
mkdir -p "$cove_app/Contents/MacOS" "$cove_app/Contents/Resources"
python3 scripts/write-app-info.py "$cove_app/Contents/Info.plist"
cp assets/AppIcon/Cove.icns "$cove_app/Contents/Resources/Cove.icns"

if [[ "$cove_distribution" == 1 ]]; then
  for cove_arch in arm64 x86_64; do
    swift build -c release --triple "$cove_arch-apple-macosx14.0" --scratch-path ".build/distribution-$cove_arch"
  done
  cove_arm_bin=$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/distribution-arm64 --show-bin-path)
  cove_intel_bin=$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/distribution-x86_64 --show-bin-path)
  lipo -create "$cove_arm_bin/Cove" "$cove_intel_bin/Cove" -output "$cove_app/Contents/MacOS/Cove"
  cove_resource_bin="$cove_arm_bin"
else
  swift build -c release
  cove_resource_bin=$(swift build -c release --show-bin-path)
  cp "$cove_resource_bin/Cove" "$cove_app/Contents/MacOS/Cove"
fi
ditto "$cove_resource_bin/Cove_Cove.bundle" "$cove_app/Contents/Resources/Cove_Cove.bundle"
zsh scripts/embed-sparkle.sh "$cove_app" "$cove_signing_identity" "$cove_distribution"
# Hardened AI-key storage (data-protection keychain) needs a Developer ID provisioning profile for
# ai.cove.mac. Without .local/Cove.provisionprofile the build is exactly as before.
cove_entitlements=assets/Cove.entitlements
cove_profile="$PWD/.local/Cove.provisionprofile"
if [[ -f "$cove_profile" ]]; then
  cove_profile_plist=$(security cms -D -i "$cove_profile")
  print -r -- "$cove_profile_plist" | python3 -c '
import plistlib, sys
profile = plistlib.loads(sys.stdin.buffer.read())
entitlements = profile.get("Entitlements", {})
assert entitlements.get("com.apple.application-identifier") == "27H459Y2P9.ai.cove.mac", "Provisioning profile is not for 27H459Y2P9.ai.cove.mac"
assert "27H459Y2P9" in profile.get("TeamIdentifier", []), "Provisioning profile is for another team"
'
  cp "$cove_profile" "$cove_app/Contents/embedded.provisionprofile"
  cove_entitlements=assets/Cove.hardened.entitlements
  print "Embedding provisioning profile; AI keys will use the data-protection keychain."
fi
cove_sign_args=(--force --options runtime --entitlements "$cove_entitlements" --sign "$cove_signing_identity")
if [[ "$cove_distribution" == 1 ]]; then cove_sign_args+=(--timestamp); fi
codesign "${cove_sign_args[@]}" "$cove_app"
codesign --verify --deep --strict "$cove_app"
codesign -d --entitlements :- "$cove_app" 2>/dev/null | python3 -c 'import plistlib,sys; assert plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.personal-information.location") is True, "Location entitlement missing from signed app"'
if [[ "$cove_distribution" == 1 ]]; then
  codesign -dvv "$cove_app" 2>&1 | rg '^Authority=Developer ID Application:'
  cove_archs=$(lipo -archs "$cove_app/Contents/MacOS/Cove")
  [[ "$cove_archs" == 'x86_64 arm64' || "$cove_archs" == 'arm64 x86_64' ]] || {
    print -u2 "Expected both Mac architectures; found: $cove_archs"
    exit 1
  }
fi
# Replace whole bundles only after a successful build; never overwrite a running executable inode.
if [[ -e "$cove_output_dir/Cove.app" ]]; then
  mv "$cove_output_dir/Cove.app" "$cove_stage/Previous-Cove.app"
fi
if ! mv "$cove_app" "$cove_output_dir/Cove.app"; then
  if [[ -e "$cove_stage/Previous-Cove.app" ]]; then
    mv "$cove_stage/Previous-Cove.app" "$cove_output_dir/Cove.app"
  fi
  exit 1
fi
if [[ "$cove_distribution" == 1 ]]; then
  ditto -c -k --keepParent "$cove_output_dir/Cove.app" "$cove_stage/Cove-notarization.zip"
  mv "$cove_stage/Cove-notarization.zip" "$cove_output_dir/Cove-notarization.zip"
fi
print "Built $cove_output_dir/Cove.app"
