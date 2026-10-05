-- Push notifications for new mail (Cove for iPhone and iPad). Approved by the user as exact SQL on
-- October 4, 2026 and applied to PlanetScale santiagocarranc2/cove/main statement by statement
-- (pscale sql, admin role), each result checked; RLS, force-RLS, the three policies and DML-only
-- runtime privileges (no TRUNCATE) were verified afterwards.
--
-- One row per signed-in device: its APNs token, the APNs environment, and a SHA-256 of the account's
-- lowercased Gmail address. Gmail's Pub/Sub notification names only that address and a history ID,
-- so the delivery route finds devices by the hash. No mail content, subject, sender, credential or
-- Gmail token is stored: the device's notification extension reads the new email itself with its
-- own Google sign-in.
--
-- Isolation: devices are written only by their verified owner (cove.owner_sub, as every table).
-- The Pub/Sub route, which has no user identity, can read and delete only the rows of the one
-- address named in the verified notification (cove.push_email_hash), and cannot insert or update.
BEGIN;
CREATE TABLE cove_sync.push_devices (
  owner_sub text NOT NULL CHECK (char_length(owner_sub) BETWEEN 1 AND 255),
  device_id uuid NOT NULL,
  email_hash text NOT NULL CHECK (email_hash ~ '^[0-9a-f]{64}$'),
  apns_token text NOT NULL CHECK (apns_token ~ '^[0-9a-f]{64,200}$'),
  environment text NOT NULL CHECK (environment IN ('production', 'sandbox')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_sub, device_id)
);
CREATE INDEX push_devices_email_hash ON cove_sync.push_devices (email_hash);
ALTER TABLE cove_sync.push_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE cove_sync.push_devices FORCE ROW LEVEL SECURITY;
CREATE POLICY push_device_owner ON cove_sync.push_devices TO cove_sync_runtime
  USING (owner_sub = current_setting('cove.owner_sub', true))
  WITH CHECK (owner_sub = current_setting('cove.owner_sub', true));
CREATE POLICY push_device_delivery ON cove_sync.push_devices FOR SELECT TO cove_sync_runtime
  USING (email_hash = current_setting('cove.push_email_hash', true));
CREATE POLICY push_device_unregister ON cove_sync.push_devices FOR DELETE TO cove_sync_runtime
  USING (email_hash = current_setting('cove.push_email_hash', true));
GRANT SELECT, INSERT, UPDATE, DELETE ON cove_sync.push_devices TO cove_sync_runtime;
COMMIT;
