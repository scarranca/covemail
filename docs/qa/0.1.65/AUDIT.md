# Cove 0.1.65, build 67: About you syncs between devices

## User request

"[About you is not] synced between iPhone and Mac yet, and syncing go ahead". The user then approved migration 005 as exact SQL and the rollout ("approve sql, go ahead").

## Changes

- **Backend:** `GET/PUT/DELETE /v1/personal` (`backend/src/personal.js`).
  - One About you per Google identity, independent of the cloud mail mirror: no `accounts` row and no mail consent.
  - Each row has its own data key, wrapped by Cloud KMS and bound to the owner.
  - Writes are compare-and-swap on the revision, with `personal_conflict` (409), including two first saves at once.
  - Server-readable, not end-to-end.
- **Shared code:** `CloudPersonalSync` (CoveCore). The newest edit wins at second precision, a device that never edited takes the server copy, and a raced write is re-decided once.
- **Mac:**
  - Agent → About you has "Sync with your iPhone and iPad", off by default per account.
  - Turning it on adds Google's `openid email` scope if missing; `needsGoogleIdentity` keeps that scope on every reconnect.
  - Edits sync after 3 s of quiet, then about every two minutes while Cove is open.
  - "Remove the copy on Cove's server" is available.
- **iPhone/iPad:** Settings → About you → "Your other devices". It syncs on open, after Save and when the app becomes active.
- **Privacy page:** a new "About you sync between your devices" section.

## Database

Migration `005_personal_context.sql` was approved as exact SQL and applied on Oct 5, one statement at a time, with the admin role. The GRANT needed `--force` only because it contains the word DELETE. Afterwards:
- RLS and force-RLS are on.
- The policy `personal_context_owner` applies to all commands for `cove_sync_runtime`.
- The runtime role has DELETE, INSERT, SELECT and UPDATE (no TRUNCATE).

## Verification

- **Backend tests:** 24/24 on the disposable loopback Postgres, covering:
  - round trip;
  - no mail-mirror consent needed;
  - encrypted at rest;
  - isolation between owners and forced RLS;
  - strict, bounded payloads;
  - stale write rejected;
  - delete;
  - concurrent first writes.
- **Mac suite:** TEST SUCCEEDED (CoveCoreTests 309, 1 skipped). New tests:
  - `CloudPersonalSyncTests`: decide, wire bounds, race;
  - `PersonalSyncTests`: adopt the server copy without echoing it back, send a later edit, survive a restart, other account off, remove.
- **iPhone simulator:** a render of the sync card (`-CoveSettings -CoveAboutYou -CoveAboutSync`).
- **Not verified:** sync between the user's real Mac and iPhone. The Mac sync card wasn't rendered, because it needs the bundled cloud URL.

## Release

- **Cloud Run:** `cove-sync-api-00009-lzv`. `/v1/status` returns 200; `/v1/personal` without or with a forged token returns 401.
- **TestFlight:** build 12.
- **App notarization:** `4cdc0ab4-cd9c-4999-acf7-af1150560231`, Accepted and stapled.
- **DMG notarization:** `05f37fe7-7f38-4aed-83f7-46cfa120e44c`, Accepted and stapled.
- **DMG:** 24,317,192 bytes, SHA-256 `90355c7b90f4cfded950571078313398d29e800f35677c9e835b4f80697b7242`.
- **Feed and site:** 44 verified releases; Cloudflare Pages deployment `d2b2bece`.
- **Public checks:**
  - `/release.json` reports 0.1.65 (build 67); the beta page, `/download/latest` and the privacy section are updated.
  - The downloaded DMG's SHA-256 matches.
  - The Ed25519 signature verifies, and a one-byte change is rejected.
- **Not run:** the headless update probe.
