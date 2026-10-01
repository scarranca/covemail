# Cove 0.1.53, build 55 — published

- **Scope:** the app is 0.1.52's (the only source change since is a code comment). The release ships the designed installer window: `scripts/build-dmg.sh` now builds the DMG with `dmgbuild` (`.local/dmg-venv`, pinned 1.6.7) using `scripts/dmg/render-background.py` and `scripts/dmg/settings.py`. The user approved the window from a preview DMG built from the 0.1.52 app.
- **Tests:** full `swift test` before building: CoveCoreTests 258 (1 skipped), CoveRenderingTests 343 (7 skipped), 0 failures.
- **App notarization:** `68e099bc-c93b-4624-b7b4-ab82ea2fee9c`, Accepted, stapled.
- **Release DMG**, checked by mounting it hidden before submitting:
  - It contains `.background.tiff`, `.VolumeIcon.icns` and the Applications link.
  - The layout places Cove.app at (170, 210) and Applications at (490, 210).
  - The app inside passes `codesign --verify --deep --strict`, and its staple validates.
  - The DMG itself is Developer ID signed.
- **DMG notarization:** `97dec908-8133-4fcd-9bf5-7a8cc2eff011`, Accepted, stapled (Notarized Developer ID). Stapled DMG: 21,572,358 bytes, SHA-256 `64475b786ea540d8054d14ca8061ca5375ca84cea69e24749ce0e0f53e0924ed`.
- **Feed and site:** `prepare-update.py 0.1.53` signed the feed (32 verified releases). Cloudflare Pages deployment `ace91a3e`.
- **Public checks:**
  - `/release.json` and the appcast list 0.1.53, and `/download/latest` redirects to `/downloads/Cove-0.1.53.dmg`.
  - The beta page says "Download Cove 0.1.53".
  - The downloaded DMG matches the bytes and SHA-256 above.
  - `verify-update-signature.swift` verifies the Ed25519 signature and rejects a tampered copy.
- **Not run:** the headless previous→current update probe.
- **Before install:** at the user's request (apps only), `/Applications/Cove.app`, every QA build, the Cove DMGs in Downloads and the preview DMG were moved to the Trash, and the mounted Cove volumes were ejected. Application Support data, preferences and Keychain items were kept.
