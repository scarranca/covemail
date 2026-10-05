import { createHash } from 'node:crypto';
import { z } from 'zod';
import { newMailPayload } from './apns.js';

// New-mail push (migration 004). Devices register with their verified Google identity. Gmail's watch
// publishes {emailAddress, historyId} to Pub/Sub, which calls /v1/gmail/push with its own OIDC token;
// the route looks up that address's devices and sends a content-free APNs push. No Gmail credential,
// subject, sender or body ever reaches this service.
export const emailHash = email => createHash('sha256').update(String(email).trim().toLowerCase()).digest('hex');

const MAX_DEVICES = 10;

/// Verifies Pub/Sub's push OIDC token: Google-signed, for this endpoint, from the subscription's
/// service account.
export function pubsubVerifier({audience, serviceAccount}, client) {
  if (!audience || !serviceAccount) throw new Error('Pub/Sub audience and service account required');
  return async token => {
    const ticket = await client.verifyIdToken({idToken: token, audience});
    const p = ticket.getPayload();
    if (!p?.email_verified || p.email !== serviceAccount) throw new Error('Unexpected Pub/Sub identity');
  };
}

export function pushTransaction(pool, hash, work) {
  return (async () => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      // No owner: the delivery policies match only this address's rows, read and delete only.
      await client.query("SELECT set_config('cove.push_email_hash', $1, true)", [hash]);
      await client.query("SET LOCAL lock_timeout = '3s'");
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally { client.release(); }
  })();
}

export function registerPush(app, {pool, withOwner, parse, fail, uuid, apns, verifyPubSub, log = () => {}}) {
  const device = z.object({
    token: z.string().regex(/^[0-9a-fA-F]{64,200}$/).transform(x => x.toLowerCase()),
    environment: z.enum(['production', 'sandbox']),
  }).strict();

  app.put('/v1/push/devices/:deviceID', async req => {
    if (!apns) fail(503, 'push_unavailable');
    const deviceID = parse(uuid, req.params.deviceID);
    const input = parse(device, req.body);
    if (!req.identity.email) fail(401, 'authentication_required');
    const hash = emailHash(req.identity.email);
    return withOwner(req, async c => {
      const count = (await c.query('SELECT count(*) FROM cove_sync.push_devices WHERE owner_sub=$1 AND device_id<>$2',
        [req.identity.sub, deviceID])).rows[0].count;
      if (Number(count) >= MAX_DEVICES) fail(409, 'push_device_limit');
      await c.query(`INSERT INTO cove_sync.push_devices(owner_sub,device_id,email_hash,apns_token,environment)
        VALUES($1,$2,$3,$4,$5) ON CONFLICT(owner_sub,device_id) DO UPDATE SET email_hash=EXCLUDED.email_hash,
        apns_token=EXCLUDED.apns_token, environment=EXCLUDED.environment, updated_at=now()`,
        [req.identity.sub, deviceID, hash, input.token, input.environment]);
      return {registered: true, account: hash.slice(0, 16)};
    });
  });

  app.delete('/v1/push/devices/:deviceID', async req => {
    const deviceID = parse(uuid, req.params.deviceID);
    await withOwner(req, c => c.query('DELETE FROM cove_sync.push_devices WHERE owner_sub=$1 AND device_id=$2',
      [req.identity.sub, deviceID]));
    return {deleted: true};
  });

  const envelope = z.object({
    message: z.object({data: z.string().max(4096), messageId: z.string().max(128).optional()}).passthrough(),
    subscription: z.string().max(512).optional(),
  }).passthrough();
  const notice = z.object({emailAddress: z.string().email().max(320), historyId: z.union([z.string(), z.number()])}).passthrough();

  // Pub/Sub retries anything but 2xx. Malformed messages are acknowledged (retrying can't fix them);
  // only a database outage asks for a retry.
  app.post('/v1/gmail/push', async (req, reply) => {
    const match = /^Bearer ([^\s]{1,16384})$/.exec(req.headers.authorization ?? '');
    if (!match || !verifyPubSub) fail(401, 'authentication_required');
    try { await verifyPubSub(match[1]); } catch { fail(401, 'authentication_required'); }
    if (!apns) return reply.code(204).send();
    const outer = envelope.safeParse(req.body);
    if (!outer.success) return reply.code(204).send();
    let inner;
    try { inner = notice.safeParse(JSON.parse(Buffer.from(outer.data.message.data, 'base64').toString('utf8'))); }
    catch { return reply.code(204).send(); }
    if (!inner.success) return reply.code(204).send();
    const historyID = String(inner.data.historyId);
    if (!/^[0-9]{1,20}$/.test(historyID)) return reply.code(204).send();
    const hash = emailHash(inner.data.emailAddress);
    const devices = await pushTransaction(pool, hash, async c =>
      (await c.query('SELECT owner_sub,device_id,apns_token,environment FROM cove_sync.push_devices WHERE email_hash=$1', [hash])).rows);
    const gone = [];
    let sent = 0;
    let transient = 0;
    await Promise.all(devices.map(async d => {
      const result = await apns.send({deviceToken: d.apns_token, environment: d.environment,
        payload: newMailPayload({historyID, account: hash.slice(0, 16)})});
      if (result.status === 200) sent++;
      // The device uninstalled Cove or the token belongs to the other environment: forget it.
      else if (result.status === 410 || (result.status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(result.reason)))
        gone.push(d);
      else {
        if (result.status === 0 || result.status >= 500 || result.status === 429) transient++;
        log({event: 'apns_failed', status: result.status, reason: result.reason});
      }
    }));
    if (gone.length) {
      await pushTransaction(pool, hash, async c => {
        for (const d of gone) await c.query('DELETE FROM cove_sync.push_devices WHERE owner_sub=$1 AND device_id=$2 AND apns_token=$3',
          [d.owner_sub, d.device_id, d.apns_token]);
      });
    }
    log({event: 'gmail_push', devices: devices.length, sent, removed: gone.length, retry: transient});
    // A timeout or dropped connection to APNs: let Pub/Sub retry. A duplicate push only becomes the
    // device's quiet "up to date" placeholder, which is cheaper than a missed alert.
    if (transient) return reply.code(503).send({error: 'temporarily_unavailable'});
    return reply.code(204).send();
  });
}
