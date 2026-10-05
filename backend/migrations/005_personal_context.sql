-- About you, synced between a user's iPhone, iPad and Mac. Approved by the user as exact SQL on
-- October 5, 2026 and applied to PlanetScale santiagocarranc2/cove/main statement by statement
-- (pscale sql, admin role), each result checked; RLS, force-RLS, the owner policy and DML-only
-- runtime privileges (no TRUNCATE) were verified afterwards.
--
-- One row per Google identity: the user's own description of themselves (name, role, projects,
-- notes, sign-off), never mail. Unlike voice_profiles it does not depend on the cloud mail mirror
-- (cove_sync.accounts): each row carries its own data key, wrapped by Cloud KMS and bound to the
-- owner. Server keys can decrypt it: this is not end-to-end encryption. Sync is opt-in per device.
BEGIN;
CREATE TABLE cove_sync.personal_contexts (
  owner_sub text PRIMARY KEY CHECK (char_length(owner_sub) BETWEEN 1 AND 255),
  wrapped_key bytea NOT NULL CHECK (octet_length(wrapped_key) BETWEEN 1 AND 4096),
  ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 32768),
  revision bigint NOT NULL CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cove_sync.personal_contexts ENABLE ROW LEVEL SECURITY;
ALTER TABLE cove_sync.personal_contexts FORCE ROW LEVEL SECURITY;
CREATE POLICY personal_context_owner ON cove_sync.personal_contexts TO cove_sync_runtime
  USING (owner_sub = current_setting('cove.owner_sub', true))
  WITH CHECK (owner_sub = current_setting('cove.owner_sub', true));
GRANT SELECT, INSERT, UPDATE, DELETE ON cove_sync.personal_contexts TO cove_sync_runtime;
COMMIT;
