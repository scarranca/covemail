import Fastify from 'fastify';
import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { transaction } from './database.js';
import { newKey, seal, open, context, digest } from './crypto.js';
import { registerSnoozes } from './snoozes.js';
import { registerVoice } from './voice.js';

const uuid = z.string().uuid().transform(value => value.toLowerCase());
const id = z.string().regex(/^[a-zA-Z0-9_-]{1,128}$/);
const revision = z.string().regex(/^(0|[1-9][0-9]{0,18})$/).refine(x => BigInt(x) <= 9223372036854775807n);
const text = z.string().max(16384);
const metadata = z.object({sender: text, senderEmail: text, to: text, subject: text,
  replyTo: text.optional(), messageID: text, decision: z.object({category: z.string().max(64),
    confidence: z.number().min(0).max(1), needsReply: z.number().min(0).max(1), urgent: z.number().min(0).max(1),
    excerpt: z.string().max(24000).optional(), model: z.string().max(128)}).strict().optional()}).strict();
const message = z.object({id, threadID: z.string().max(128), receivedAt: z.string().datetime(),
  labels: z.array(z.string().max(128)).max(100), metadata,
  body: z.object({text: z.string().max(64000), html: z.string().max(128000).optional(),
    truncated: z.boolean()}).strict()}).strict();
const batch = z.object({accountID: uuid, requestID: uuid, baseRevision: revision,
  messages: z.array(message).max(5), deletedIDs: z.array(id).max(25)}).strict()
  .refine(x => new Set([...x.messages.map(m => m.id), ...x.deletedIDs]).size === x.messages.length + x.deletedIDs.length);
class Failure extends Error { constructor(status, code) { super(code); this.status = status; this.code = code; } }
const fail = (status, code) => { throw new Failure(status, code); };
const parse = (schema, value) => { const r = schema.safeParse(value); if (!r.success) fail(400, 'invalid_request'); return r.data; };
const publicAccount = a => ({accountID: a.account_id, revision: a.revision});

export function createAPI({pool, verifyIdentity, keys, bodies, now = () => new Date()}) {
  const app = Fastify({logger: false, bodyLimit: 1024 * 1024, requestTimeout: 30000,
    ajv: {customOptions: {removeAdditional: false}}});
  const limits = new Map();
  function limit(key, maximum) {
    const minute = Math.floor(now().getTime() / 60000);
    if (limits.size > 1000) for (const [k, v] of limits) if (v.minute !== minute) limits.delete(k);
    if (limits.size > 2000) fail(429, 'rate_limited');
    const v = limits.get(key)?.minute === minute ? limits.get(key) : {minute, count: 0};
    v.count++; limits.set(key, v);
    if (v.count > maximum) fail(429, 'rate_limited');
  }
  app.addHook('onRequest', async (req, reply) => {
    reply.header('Cache-Control', 'no-store').header('X-Content-Type-Options', 'nosniff');
    if (req.url === '/v1/status') return;
    limit('ip:' + req.ip, 120);
    const match = /^Bearer ([^\s]{1,16384})$/.exec(req.headers.authorization ?? '');
    if (!match) fail(401, 'authentication_required');
    try { req.identity = await verifyIdentity(match[1]); } catch { fail(401, 'authentication_required'); }
    if (!req.identity?.sub) fail(401, 'authentication_required');
    limit('user:' + req.identity.sub, 60);
  });
  app.setErrorHandler((error, req, reply) => {
    const status = error instanceof Failure ? error.status : error.statusCode === 413 ? 413 : 503;
    const code = error instanceof Failure ? error.code : status === 413 ? 'request_too_large' : 'temporarily_unavailable';
    // Never log SQL, request bodies, tokens, decrypted content, or provider error payloads.
    if (status >= 500) console.error(JSON.stringify({event: 'sync_request_failed', requestID: req.id}));
    reply.code(status).send({error: code});
  });
  app.get('/v1/status', async () => ({ok: true}));
  const withOwner = (req, work) => transaction(pool, req.identity.sub, work);
  async function account(req) {
    return withOwner(req, async c => {
      const a = (await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1', [req.identity.sub])).rows[0];
      if (!a) fail(404, 'cloud_not_connected'); return a;
    });
  }
  app.post('/v1/connection', async req => {
    parse(z.object({consentVersion: z.literal('cloud-mail-v1')}).strict(), req.body);
    const accountID = randomUUID();
    const wrapped = await keys.wrap(newKey(), accountID);
    return withOwner(req, async c => {
      await c.query(`INSERT INTO cove_sync.accounts(owner_sub,account_id,wrapped_key) VALUES($1,$2,$3)
        ON CONFLICT(owner_sub) DO NOTHING`, [req.identity.sub, accountID, wrapped]);
      return publicAccount((await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1', [req.identity.sub])).rows[0]);
    });
  });
  app.get('/v1/connection', async req => publicAccount(await account(req)));
  app.delete('/v1/connection', async req => {
    const {accountID} = parse(z.object({accountID: uuid}).strict(), req.body);
    await withOwner(req, async c => {
      const result = await c.query('DELETE FROM cove_sync.accounts WHERE owner_sub=$1 AND account_id=$2', [req.identity.sub, accountID]);
      if (!result.rowCount) fail(404, 'cloud_not_connected');
    });
    // Ciphertext objects are inaccessible after their account key is removed and expire via bucket lifecycle.
    return {deleted: true};
  });
  app.post('/v1/messages/batch', async req => {
    const input = parse(batch, req.body);
    const a = await account(req);
    if (a.account_id !== input.accountID) fail(409, 'connection_changed');
    const key = await keys.unwrap(a.wrapped_key, a.account_id);
    const requestHash = digest(key, input);
    const previous = await withOwner(req, async c => (await c.query(
      'SELECT * FROM cove_sync.receipts WHERE owner_sub=$1 AND request_id=$2', [req.identity.sub, input.requestID])).rows[0]);
    if (previous) {
      if (previous.request_hash !== requestHash) fail(409, 'request_id_reused');
      return {revision: previous.revision};
    }
    if (a.revision !== input.baseRevision) fail(409, 'revision_conflict');
    // Reject quota violations before allocating objects; recheck under the commit lock below.
    const additional = await withOwner(req, async c => {
      const r = await c.query(`SELECT count(*) AS total,
        count(*) FILTER (WHERE message_id = ANY($2::text[])) AS existing
        FROM cove_sync.messages WHERE owner_sub=$1`, [req.identity.sub, input.messages.map(m => m.id)]);
      return Number(r.rows[0].total) + input.messages.length - Number(r.rows[0].existing);
    });
    if (additional > 5000) fail(409, 'pilot_storage_limit');
    const prepared = [];
    for (const m of input.messages) {
      const received = new Date(m.receivedAt);
      if (received < new Date(now().getTime() - 30 * 86400000) || received > new Date(now().getTime() + 86400000))
        fail(400, 'outside_recent_mail_window');
      if (Buffer.byteLength(JSON.stringify(m)) > 240000) fail(413, 'message_too_large');
      const hash = digest(key, m);
      const bodyHash = digest(key, m.body);
      const old = await withOwner(req, async c => (await c.query(
        'SELECT body_hash,body_object FROM cove_sync.messages WHERE owner_sub=$1 AND message_id=$2 AND NOT deleted', [req.identity.sub, m.id])).rows[0]);
      let object = old?.body_hash === bodyHash ? old.body_object : null;
      if (!object) {
        object = `${a.account_id}/${randomUUID()}`;
        await bodies.put(object, seal(key, m.body, context(a.account_id, m.id, 'body')));
      }
      prepared.push({m, hash, bodyHash, object, cipher: seal(key, m.metadata, context(a.account_id, m.id, 'metadata')),
        expires: new Date(received.getTime() + 30 * 86400000)});
    }
    return withOwner(req, async c => {
      // This row lock serializes revision allocation with COMMIT, including across API instances.
      const current = (await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1 FOR UPDATE', [req.identity.sub])).rows[0];
      if (!current || current.account_id !== input.accountID) fail(409, 'connection_changed');
      const receipt = (await c.query('SELECT * FROM cove_sync.receipts WHERE owner_sub=$1 AND request_id=$2', [req.identity.sub, input.requestID])).rows[0];
      if (receipt) {
        if (receipt.request_hash !== requestHash) fail(409, 'request_id_reused');
        return {revision: receipt.revision};
      }
      if (current.revision !== input.baseRevision) fail(409, 'revision_conflict');
      let rev = BigInt(current.revision);
      for (const p of prepared) {
        const old = (await c.query('SELECT content_hash FROM cove_sync.messages WHERE owner_sub=$1 AND message_id=$2 AND NOT deleted', [req.identity.sub, p.m.id])).rows[0];
        if (old?.content_hash === p.hash) continue;
        rev++;
        await c.query(`INSERT INTO cove_sync.messages(owner_sub,message_id,thread_id,received_at,labels,revision,content_cipher,content_hash,body_object,body_hash,body_expires_at)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT(owner_sub,message_id) DO UPDATE SET
          thread_id=EXCLUDED.thread_id, received_at=EXCLUDED.received_at, labels=EXCLUDED.labels,
          revision=EXCLUDED.revision, deleted=false, content_cipher=EXCLUDED.content_cipher,
          content_hash=EXCLUDED.content_hash, body_object=EXCLUDED.body_object, body_hash=EXCLUDED.body_hash, body_expires_at=EXCLUDED.body_expires_at`,
          [req.identity.sub,p.m.id,p.m.threadID,p.m.receivedAt,p.m.labels,rev.toString(),p.cipher,p.hash,p.object,p.bodyHash,p.expires]);
      }
      for (const deletedID of input.deletedIDs) {
        const result = await c.query(`UPDATE cove_sync.messages SET deleted=true, content_cipher=NULL,content_hash=NULL,
          body_object=NULL,body_hash=NULL,body_expires_at=NULL,revision=$3 WHERE owner_sub=$1 AND message_id=$2 AND NOT deleted`,
          [req.identity.sub, deletedID, (rev + 1n).toString()]);
        if (result.rowCount) rev++;
      }
      const count = (await c.query('SELECT count(*) FROM cove_sync.messages WHERE owner_sub=$1', [req.identity.sub])).rows[0].count;
      if (Number(count) > 5000) fail(409, 'pilot_storage_limit');
      await c.query('UPDATE cove_sync.accounts SET revision=$2 WHERE owner_sub=$1', [req.identity.sub, rev.toString()]);
      await c.query('INSERT INTO cove_sync.receipts(owner_sub,request_id,request_hash,revision) VALUES($1,$2,$3,$4)', [req.identity.sub,input.requestID,requestHash,rev.toString()]);
      await c.query("DELETE FROM cove_sync.receipts WHERE owner_sub=$1 AND created_at < now() - interval '7 days'", [req.identity.sub]);
      return {revision: rev.toString()};
    });
  });
  app.get('/v1/messages/changes', async req => {
    const query = parse(z.object({accountID: uuid, after: revision.default('0')}).strict(), req.query);
    const a = await account(req);
    if (query.accountID !== a.account_id) fail(409, 'connection_changed');
    if (BigInt(query.after) > BigInt(a.revision)) fail(400, 'invalid_cursor');
    const key = await keys.unwrap(a.wrapped_key, a.account_id);
    const rows = await withOwner(req, async c => (await c.query(`SELECT * FROM cove_sync.messages
      WHERE owner_sub=$1 AND revision>$2 AND EXISTS (SELECT 1 FROM cove_sync.accounts WHERE owner_sub=$1 AND account_id=$3) ORDER BY revision LIMIT 101`, [req.identity.sub,query.after,a.account_id])).rows);
    const page = rows.slice(0,100);
    return {accountID: a.account_id, cursor: page.at(-1)?.revision ?? query.after, hasMore: rows.length > 100,
      messages: page.map(r => r.deleted ? {id:r.message_id, revision:r.revision, deleted:true} : {
        id:r.message_id, threadID:r.thread_id, receivedAt:r.received_at.toISOString(), labels:r.labels,
        revision:r.revision, deleted:false, metadata:open(key,r.content_cipher,context(a.account_id,r.message_id,'metadata')),
        bodyAvailable:r.body_object !== null && r.body_expires_at > now()})};
  });
  app.get('/v1/messages/:id/body', async req => {
    const messageID = parse(id, req.params.id);
    const {accountID} = parse(z.object({accountID:uuid}).strict(),req.query);
    const a = await account(req);
    if (a.account_id !== accountID) fail(409,'connection_changed');
    const r = await withOwner(req, async c => (await c.query(`SELECT body_object,body_expires_at FROM cove_sync.messages
      WHERE owner_sub=$1 AND message_id=$2 AND NOT deleted AND EXISTS (SELECT 1 FROM cove_sync.accounts WHERE owner_sub=$1 AND account_id=$3)`, [req.identity.sub,messageID,a.account_id])).rows[0]);
    if (!r?.body_object || r.body_expires_at <= now()) fail(404,'body_unavailable');
    const key = await keys.unwrap(a.wrapped_key,a.account_id);
    return open(key,await bodies.get(r.body_object),context(a.account_id,messageID,'body'));
  });
  registerSnoozes(app, {withOwner, account, keys, parse, fail, uuid, id, revision});
  registerVoice(app, {withOwner, account, keys, parse, fail, uuid, revision});
  return app;
}
