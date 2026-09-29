-- Approved by the user as exact SQL on September 29, 2026 and applied to PlanetScale
-- santiagocarranc2/cove/main statement by statement (pscale sql, admin role), each result checked.
-- Stores one learned writing-voice profile per Google identity so it follows the account to
-- another Mac that opts into cloud sync. The profile is a style description only (no mail
-- bodies) and is encrypted with the account's existing KMS-wrapped data key, like messages.
-- Server keys can decrypt it: this is not end-to-end encryption.
BEGIN;
CREATE TABLE cove_sync.voice_profiles (
  owner_sub text PRIMARY KEY REFERENCES cove_sync.accounts(owner_sub) ON DELETE CASCADE,
  ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 16384),
  revision bigint NOT NULL CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cove_sync.voice_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE cove_sync.voice_profiles FORCE ROW LEVEL SECURITY;
CREATE POLICY voice_profile_owner ON cove_sync.voice_profiles TO cove_sync_runtime
  USING (owner_sub = current_setting('cove.owner_sub', true))
  WITH CHECK (owner_sub = current_setting('cove.owner_sub', true));
GRANT SELECT, INSERT, UPDATE, DELETE ON cove_sync.voice_profiles TO cove_sync_runtime;
COMMIT;
