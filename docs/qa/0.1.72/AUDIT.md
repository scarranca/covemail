# Cove 0.1.72 — paste images into drafts

Requested and authorized for publication October 12, 2026. Mac version 0.1.72 (74),
iPhone/iPad version 0.1.0 (23).

## Behavior and checks

Paste/⌘V in a new-message or reply body adds copied images to the existing attachment list while
preserving draft text and selection. Mac uses the encrypted draft/reply attachment store. Mobile
uses the existing compose attachment list. PNG/JPEG/GIF bytes stay intact, including GIF animation;
clipboard TIFF and other supported raster formats become PNG. Ordinary text paste stays native.
The existing total 25 MB limit and visible attachment errors apply. Images are file attachments,
not inline HTML images. Sending remains explicit.

Implementation, focused test cases and inspected Mac render:
`../0.1.71/AUDIT-image-paste.md`. Mobile physical-device paste remains unverified.

## Release verification

Release receipts and public verification are recorded below as each completes. No running Cove
session is replaced or quit, and no real email is sent as a test.

- Full `swift test`: **459 rendering tests (7 skipped)** and **351 core tests (1 skipped)**,
  **0 failures**, exit 0. The first run exposed a pre-existing power-dependent polling test: it
  expected a probe at 30 seconds while the host was on battery. The fixture now advances 60 seconds,
  satisfying both AC and battery timing while staying below the two-minute full-sync interval.
  No production polling behavior changed; the full suite was rerun after the fixture correction.
- Universal Developer ID build passed for arm64 and x86_64. Hardened entitlement profile included.
- Mac app notarization: `27c1a7ee-18c4-4e57-a0d6-c3bf2c919802`, **Accepted**, stapled and Gatekeeper accepted.
- DMG submission: `bd507969-d56e-42e9-a324-908d67ec1b08`. Plain installer fallback (no local dmgbuild
  environment in this checkout). Size before stapling: 25,540,922 bytes, within Pages' 25 MiB limit.
- iPhone/iPad **0.1.0 (23)**: archive and upload passed. Apple reported **Upload succeeded** and
  **Uploaded package is processing** at October 12 17:58 UTC. Google sign-in is configured;
  notification filtering remains disabled. Tester availability/export-compliance status unverified
  because the App Store Connect browser session is signed out.

- DMG notarization **Accepted**, stapling and Gatekeeper checks passed. Final download:
  `Cove-0.1.72.dmg`, **25,542,801 bytes**, SHA-256 `c0b49e0dea8cb83e88c4dca9e3947968be40793e7fee9198cdc6e6e37c9a1a1d`.
- Sparkle feed and artifact signatures verified by `prepare-update.py`. Website staging verified
  checksums for **51 historical/current releases** and preserves their download URLs.

- **Published:** Cloudflare Pages production deployment `fc9daef5`, https://fc9daef5.covemail.pages.dev,
  project `covemail`, account `f1bf637a915898a7dfe461bd5883357d`. Existing Wrangler OAuth verified.
- Public `/release.json`, `/beta/`, `/updates/appcast.xml` and `/download/latest` verified. The domain
  briefly served 0.1.71 just after deployment; a subsequent normal fetch served 0.1.72. Downloaded
  installer byte count and SHA-256 match local final metadata. Independent Ed25519 verification using
  the bundled public key passed; flipping one byte was correctly rejected.
- Headless Sparkle probes passed using isolated host copies with separate bundle identifiers:
  previous 0.1.71 (73) sees **0.1.72 (74)**; current 0.1.72 (74) sees **no newer update**. No windows,
  installation, or running Cove session were touched. These verify discovery, not in-place installation.
- Install the Mac update through **Cove → Check for Updates…**. Mobile build 23 was uploaded to
  TestFlight; processing/tester availability must be distinguished from the confirmed upload receipt.
