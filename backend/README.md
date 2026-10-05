# Cove recent-mail cloud pilot

Status: first device-upload API, not server-side Gmail processing. The Mac is the only uploader; future mobile clients can consume the read API. Off by default, with explicit Google sign-in and cloud consent. Public API origin is in `../assets/cloud-sync-config.json`. Deployment is confined to Google project `cove-mail-20260922`, region `us-east1`, and PlanetScale `santiagocarranc2/cove/main`.

## Data and limits

The Mac mirrors at most 1,000 downloaded non-draft/non-Spam/non-Trash messages received in the last 30 days. It uploads labels, headers, bodies and existing Jev decisions. Local drafts, attachments, contact notes, calendar events and credentials are excluded. Snoozes use the separate deployed API described below; they are not part of a mail record. Plain text and HTML are truncated to 48/96 KB, with further truncation to keep encoded JSON below 200 KB per message. The API accepts four-message Mac batches (server maximum five), at most 25 deletions and 1 MiB requests. It has a 5,000-row lifetime pilot limit including tombstones; remove/reconnect the cloud copy to reset that limit. This is not an unlimited archive.

Postgres stores IDs, dates, labels, ordered revisions, tombstones and encrypted headers/decisions. Bodies live as immutable random-named encrypted Google Cloud Storage objects. Each account generation has a random AES-256-GCM data key wrapped by Cloud KMS using the account UUID as associated data. Message ciphertext binds account, message and content kind. Content/body fingerprints in the server DB use keyed HMAC; the Mac's SHA-256 checkpoint is in its encrypted local database. Keys are server-accessible: this is **not end-to-end encryption**.

Bodies become unavailable 30 days after receipt. The private bucket deletes objects after 30 days from creation, including objects orphaned by retries/conflicts. Deleted account/message objects can remain as ciphertext until lifecycle cleanup. Cloud removal deletes live account/key records and cascading message/receipt rows; DB backups follow provider retention and are not purged by that endpoint. Pausing or disconnecting Gmail keeps the cloud copy. Local erasure is separate from cloud erasure.

## Snoozes — backend deployed September 26, 2026; Mac client 0.1.45

Snooze state is independent of the 30-day/1,000-message mirror. `cove_sync.snoozes` stores the Google tenant identity, Gmail message/thread IDs, a UTC `wake_at`, a per-account ordered revision and update time. A null wake time is an explicit cancellation retained in the change feed. Dates and IDs are queryable metadata, not application-level encrypted content. No subject, body, device token or credential enters this table. Old emails need not be mirrored to have a snooze. The future mobile app will need to fetch mail separately when its body is outside the mirror.

- `PUT /v1/snoozes/<id>` accepts `{accountID,requestID,baseRevision,threadID,wakeAt}`. `wakeAt` is an ISO-8601 UTC date or explicit null; omission is rejected. `baseRevision` is the last revision of **that snooze**, or `"0"` for a new one. The response is `{revision}`. Past dates are accepted for offline changes arriving after their due time.
- `GET /v1/snoozes/changes?accountID=<uuid>&after=0` returns `{accountID,cursor,hasMore,snoozes}` in pages of 100. Each record has `{id,threadID,wakeAt,revision}`. This cursor is independent of the mail cursor. Persist page state/cursor atomically and keep cancellation records.
- Authenticated tenant identity, forced RLS, account-generation fencing, account-row commit locks, hashed request receipts and optimistic per-record revisions protect both routes. Conflicting edits return `snooze_conflict`; they never silently overwrite one another. Receipt IDs are shared with mail but hashes bind their route and message. Replays after receipt expiry may conflict and require explicit resolution; they never restore an older schedule.
- The Mac durably stores an encrypted outbox before uploading. Lost responses reuse the identical request UUID/payload, including after restart. Rescheduling or cancelling while an upload is in flight queues the newer intent behind that immutable request. Conflicts remain visible until the user chooses a snooze time again or Return to inbox. Server changes apply to cached mail and are retained for mail downloaded later.
- Cloud sync remains opt-in. Off/paused accounts keep local changes; they are uploaded after enabling/resuming. Existing future local snoozes seed once when absent from server state. While open, the Mac retries cloud sync about every two minutes independently of Gmail's background-sync setting. Reminder changes are prioritized ahead of bulk mail batches. Reminder errors do not block mail-mirror uploads or claim successful reminder sync.
- Mirror expiry/removal does not cancel snoozes. Confirmed Gmail deletions and downloaded Trash/Spam states queue cancellations; the Mac must observe these changes. Older Mac versions do not sync snoozes. Pausing/disconnecting keeps server records; Remove cloud copy deletes them through the account foreign key. Due/cancelled records currently remain until cloud removal, with a 5,000-record pilot cap including cancellations; existing records can still be changed at that cap.

There is **no scheduler, background Gmail ingestion, notification delivery, APNs registration or mobile client** in this change. A due timestamp remains available while the Mac is closed, but nothing sends an alert yet. Mobile launch needs separately reviewed device registration, notification consent, a worker with narrowly scoped cross-tenant access, revision-aware cancellation checks and an idempotent delivery/outbox model. Do not mark timestamps as delivered or promise notifications based on storage alone.

Rollout: the user approved the exact `migrations/002_snoozes.sql`, applied once in a transaction to PlanetScale `santiagocarranc2/cove/main` on September 26, 2026. Cloud Run revision `cove-sync-api-00004-qjf` serves the snooze API. The production synthetic storage check passed for snooze persistence, cancellation and forced tenant RLS. Cove 0.1.45/build 47 is published with this integration; 0.1.44 and older remain local-only for snoozes. See `../docs/qa/0.1.45/AUDIT.md` for rollout evidence. The migration is additive; existing mail-only clients remain compatible. Roll back the API/client first and leave the additive schema/data intact. Never run migration 001 again or remove reminder data as a rollback.

## Learned writing voice — deployed September 29, 2026

`cove_sync.voice_profiles` (migration 003, user-approved exact SQL) stores one learned writing-voice profile per Google identity so it follows the account to another Mac with cloud sync on. It holds a style description only (summary, greetings, sign-offs, traits, generic phrases, languages, learnedAt, sampleCount, model), never mail bodies. It is encrypted with the account data key (AAD binds account and kind) and is server-accessible, not end-to-end.

- `GET /v1/voice?accountID=<uuid>` returns `{revision, profile|null, updatedAt|null}`; revision `"0"` means none yet.
- `PUT /v1/voice` takes `{accountID, requestID, baseRevision, profile|null, updatedAt}`. The profile is strict and bounded (unknown fields such as `body` are rejected). A null profile explicitly records "forgotten". The response is `{revision}`. Stale bases return `voice_conflict`; identical retries are idempotent through the shared receipts table.
- The Mac compares its shared record's `updatedAt` with the cloud's; the newest wins, including "forgotten". Failures never block mail or snooze sync.
- Rollout: statements applied individually on September 29 with verified RLS/force-RLS, the owner policy and DML-only runtime privileges (no TRUNCATE). Cloud Run revision `cove-sync-api-00005-xtt` (image `api:20260929175709`), same pinned secret version 1 and configuration as 00004. `/v1/status` 200; unauthenticated and forged voice requests 401. Backend tests: 17/17 on a disposable loopback Postgres 17 (npm `embedded-postgres`, since Docker is unavailable here; never PlanetScale).

## New-mail push — deployed October 4, 2026

Cove for iPhone/iPad gets new-mail notifications without the server holding any Gmail credential or mail content.

1. The device calls Gmail `users.watch` itself (its own token) for the Inbox, publishing to Pub/Sub topic `projects/cove-mail-20260922/topics/gmail-push` (`gmail-api-push@system.gserviceaccount.com` is its only publisher). The week-long watch renews itself on the device: the notification extension renews it on any push once fewer than three days remain, Background App Refresh does so about twice a day, and opening the app does too. The server cannot renew it (no Gmail credential).
2. The device registers `PUT /v1/push/devices/<uuid>` `{token, environment: production|sandbox}` with its Google ID token (the iOS client is in `GOOGLE_CLIENT_IDS`). The row stores the APNs token and a SHA-256 of the verified, lowercased address (`cove_sync.push_devices`, migration 004, at most 10 per owner). `DELETE` forgets it.
3. Push subscription `gmail-push-to-api` delivers `{emailAddress, historyId}` to `POST /v1/gmail/push` with an OIDC token for audience `…/v1/gmail/push` from `cove-gmail-push@cove-mail-20260922.iam.gserviceaccount.com`; the route verifies it (no user token). Under `cove.push_email_hash` RLS it can only read and delete that address's devices.
4. It sends each device a content-free APNs alert (`New email`, `mutable-content`, the history ID) with the token-based key **Cove Push** (Key ID `Z7S2G2N9NT`, team-scoped, Sandbox & Production) from Secret Manager `cove-apns-key` (version 1, readable only by the runtime service account). 410/BadDeviceToken rows are removed. Malformed or unknown notifications are acknowledged; nothing is logged beyond counts.
5. The app's notification extension reads the new email with the device's own Google session and shows sender and subject (`NewMailAlert`), or a passive "up to date" placeholder that the next run removes.

Deployment: revision `cove-sync-api-00007-hm7` (image built Oct 5 03:3x UTC), DB secret version 1, `COVE_APNS_SECRET_VERSION=1`; env adds `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC=ai.cove.ios`, `PUSH_AUDIENCE`, `PUSH_SERVICE_ACCOUNT`. Without `APNS_KEY`/`PUSH_AUDIENCE` the push routes answer `push_unavailable` and the rest of the API is unchanged. Checks: backend tests 20/20 on a disposable loopback Postgres (npm `embedded-postgres`); `/v1/status` 200, unauthenticated and forged push requests 401; a synthetic Pub/Sub publish reached the route (204); APNs accepted the provider token in both environments (fake-token `BadDeviceToken`); a real sandbox push to a signed simulator build ran the notification extension.

## Authentication and isolation

Google ID tokens are verified for signature, issuer, expiry, configured OAuth audiences, verified authoritative Google email, authorized party and the explicit private-pilot email allowlist. Google `sub` selects the tenant; no request may choose a tenant. Tokens are not persisted or logged. Google refresh tokens never leave the Mac.

The runtime LOGIN role is separately provisioned, inherits only `cove_sync_runtime`, and must not own tables or have superuser/BYPASSRLS. Startup checks enforce this. Every request transaction uses parameterized `SET LOCAL` identity, and all tables have forced row-level security with both USING and WITH CHECK. All SQL values are bound parameters. Runtime permissions are DML only, without schema modification. The pool is limited to two verified-TLS connections per instance with connection/query/lock/idle transaction timeouts. URL SSL flags that override TLS verification are rejected.

A per-account row lock allocates revisions in commit order. Optimistic base revisions reject stale concurrent writes. Request UUIDs and keyed payload receipts make network retries idempotent, including identical retries after the cursor advanced. Receipts are cleaned after seven days on writes; content hashes also avoid duplicate upserts and unnecessary body objects. Account UUID generations fence deletion/reconnection against in-flight old uploads. The Mac persists a checkpoint after each batch; a lost response is reconciled against the server cursor and unchanged-content deduplication on retry.

The pilot supports one authoritative uploading Mac. It does not implement multiwriter conflict merging, mobile mail mutations, server Gmail refresh tokens, server-side Gmail reading, server-side Jev, or draft synchronization. Gmail push notifications only wake devices (see New-mail push). Do not turn on another uploading Mac as if multi-device mutation were supported.

## API contract

Every route except `GET /v1/status` requires `Authorization: Bearer <Google ID token>`. HTTPS only, no redirects, no public storage objects, no CORS/browser credential flow. API responses use `Cache-Control: no-store`. Errors are short codes without provider payloads. Request and SQL contents are not logged by application code; managed request logs still contain request metadata.

- `POST /v1/connection` with `{"consentVersion":"cloud-mail-v1"}` returns `{accountID, revision}` and explicitly creates/reuses the cloud account.
- `GET /v1/connection` returns that account and current revision; it never creates an account.
- `POST /v1/messages/batch` with `{accountID, requestID, baseRevision, messages, deletedIDs}` returns `{revision}`. Wire types are in `src/api.js` and `Sources/CoveCore/CloudMailSync.swift`. Revision strings avoid JavaScript integer precision loss.
- `GET /v1/messages/changes?accountID=<uuid>&after=0` returns `{accountID,cursor,hasMore,messages}` (100 at a time). Active rows include metadata, labels, date and bodyAvailable; tombstones include id/revision/deleted. Persist data and cursor atomically; continue while hasMore. Never paginate by date.
- `GET /v1/messages/<id>/body?accountID=<uuid>` returns `{text,html?,truncated}` while available.
- `DELETE /v1/connection` with `{accountID}` removes only the verified caller's matching account generation. Requires the user's cloud-removal action; it does not touch Gmail.

Relevant errors: `authentication_required` (401), `cloud_not_connected` (404), `connection_changed`, `revision_conflict`, `request_id_reused`, `pilot_storage_limit` (409), `rate_limited` (429), `temporarily_unavailable` (503). An account generation change requires reconnection/full bootstrap; a read cursor is only valid within that generation. Server caps are intentionally separate from the smaller client mirror cap.

## Local tests

Use a dedicated disposable loopback Postgres fixture on port 55439, never PlanetScale. The tests recreate only that synthetic schema/roles:

```sh
docker run --name cove-sync-test -e POSTGRES_PASSWORD=cove-synthetic-test -p 127.0.0.1:55439:5432 -d postgres:17
cd backend
npm ci --ignore-scripts
npm test
```

`npm test` covers verified identity policy, encryption/AAD tampering, pooled RLS tenant isolation, concurrent revisions, idempotent retries, paginated change feeds, deletion tombstones, account removal during upload and body expiry. Swift tests cover bounded/allowlisted serialization, forbidden payload fields, Unicode/JSON expansion, HTTPS-only transport, safe error display, saved pause state, and an offscreen settings render. No real mail is used.

The pinned `gaxios@6.7.1` UUID override addresses the transitive uuid advisory while retaining CommonJS compatibility. `npm audit --omit=dev` has zero findings at preparation time; audit again when dependencies change.

## Deployment and operations

1. Review/apply `migrations/001_sync.sql` with a migration credential. PlanetScale MCP requires human approval of exact DDL. Applied September 25, 2026 after approval. Its prepared-query tool allows one statement per call, so the approved statements were applied sequentially and each result checked, not as one transaction. All three policies/tables were then verified. Never run migrations from the API service.
2. `infra/provision.sh` creates the dedicated runtime service account, private US-east1 bucket (uniform access, public-access prevention, lifecycle, no soft delete), KMS key, Secret Manager secret and Artifact Registry repository. Runtime receives key-specific encrypt/decrypt, bucket-specific create/read, and secret-specific access. It has no project Editor role. Provisioning is intended only for these dedicated resources.
3. Use PlanetScale CLI to create a new LOGIN role with no inherited roles, then grant `cove_sync_runtime` to its actual Postgres role name. Validate it with `assertRuntimeRole` and verified TLS before adding a Secret Manager version. Do not put admin credentials, a database URL or cloud service-account keys in the desktop app/repository. Keep credentials local and suppress CLI output that contains newly generated passwords.
4. Prepare local YAML with `GOOGLE_CLIENT_IDS`, `PILOT_EMAILS`, `CONTENT_KMS_KEY` and `BODY_BUCKET`. Keep the allowlist narrow. Run `infra/deploy.sh` with `COVE_SYNC_ENV_FILE` and pinned `COVE_DB_SECRET_VERSION`. API uses Google workload identity; no static Google key file. All gcloud commands explicitly select the Cove project, leaving the user's global project unchanged.
5. Run `infra/verify.sh` using the same config. The one-shot Cloud Run job tests actual KMS associated data, encrypted object round-trip and live runtime RLS inside a rolled-back synthetic transaction. It leaves only one tiny synthetic ciphertext object for automatic lifecycle cleanup. No scheduled executions are configured.
6. Verify `/v1/status` returns 200 and both missing/forged credentials return 401. `/healthz` is reserved upstream on Cloud Run and is not the public health route. Complete the real Google consent/upload check through the signed Mac app; do not extract its refresh token for testing.

Cloud Run uses request-based CPU, 512 MiB, min 0, service/revision max 2 and concurrency 8. Nominal API DB capacity is four pool connections across two instances; deployments and the one-shot test can temporarily add more. Per-instance rate maps are bounded (60 requests/min/account, 120/min/IP); they are not a distributed quota. Max instances is a scaling control, not a hard spending cap. Cloud Build, artifacts, KMS, Secret Manager, bucket storage/operations, cross-cloud transfer and PlanetScale can incur charges. No Redis, always-on worker, Scheduler or Pub/Sub is provisioned in this phase.

Rollback: disable cloud sync in the Mac, or restrict/disable the API's Cloud Run ingress while keeping the DB/key/bucket for recovery. Do not destroy KMS keys as a rollback. Re-deploy a known image with the same pinned secret/config; the Mac remains usable with local/Gmail data. Future background ingestion needs a separately reviewed server OAuth flow, Gmail watch/history processing, durable jobs, deletion retention policy and mobile authentication audiences.
