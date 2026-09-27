-- Pending exact-SQL approval before production. Apply once, before deploying the snooze API.
BEGIN;
ALTER TABLE cove_sync.accounts ADD COLUMN snooze_revision bigint NOT NULL DEFAULT 0 CHECK (snooze_revision >= 0);
CREATE TABLE cove_sync.snoozes (
  owner_sub text NOT NULL REFERENCES cove_sync.accounts(owner_sub) ON DELETE CASCADE,
  message_id text NOT NULL,
  thread_id text NOT NULL,
  wake_at timestamptz,
  revision bigint NOT NULL CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_sub, message_id)
);
CREATE INDEX snoozes_revision ON cove_sync.snoozes(owner_sub, revision);
CREATE INDEX snoozes_due ON cove_sync.snoozes(wake_at) WHERE wake_at IS NOT NULL;
ALTER TABLE cove_sync.snoozes ENABLE ROW LEVEL SECURITY;
ALTER TABLE cove_sync.snoozes FORCE ROW LEVEL SECURITY;
CREATE POLICY snooze_owner ON cove_sync.snoozes TO cove_sync_runtime
  USING (owner_sub = current_setting('cove.owner_sub', true))
  WITH CHECK (owner_sub = current_setting('cove.owner_sub', true));
GRANT SELECT, INSERT, UPDATE, DELETE ON cove_sync.snoozes TO cove_sync_runtime;
COMMIT;
