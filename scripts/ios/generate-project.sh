#!/bin/sh
# Generates iOS/CoveMobile.xcodeproj from iOS/project.yml. Requires XcodeGen (brew install xcodegen).
set -eu
cd "$(dirname "$0")/../../iOS"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
[ -f Config/Local.xcconfig ] || echo "Note: iOS/Config/Local.xcconfig is missing; Google sign-in stays disabled (see docs/IOS.md)." >&2
xcodegen generate --spec project.yml
echo "Open iOS/CoveMobile.xcodeproj and run the CoveMobileApp scheme."
