import { z } from 'zod';
import { digest } from './crypto.js';

// Independent of the bounded mail mirror: an old email may still have a future reminder.
// wake_at is queryable scheduling metadata. No email content or device tokens are stored here.
export function registerSnoozes(app, {withOwner, account, keys, parse, fail, uuid, id, revision}) {
  const mutation = z.object({accountID: uuid, requestID: uuid, baseRevision: revision,
    threadID: z.string().max(128), wakeAt: z.string().datetime().nullable()}).strict();
  app.put('/v1/snoozes/:id', async req => {
    const messageID = parse(id, req.params.id);
    const input = parse(mutation, req.body);
    const a = await account(req);
    if (a.account_id !== input.accountID) fail(409, 'connection_changed');
    const key = await keys.unwrap(a.wrapped_key, a.account_id);
    // Namespace shared receipt IDs so an ID cannot be reused across routes or messages.
    const hash = digest(key, {kind:'snooze', messageID, input});
    return withOwner(req, async c => {
      const current = (await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1 FOR UPDATE', [req.identity.sub])).rows[0];
      if (!current || current.account_id !== input.accountID) fail(409, 'connection_changed');
      const receipt = (await c.query('SELECT * FROM cove_sync.receipts WHERE owner_sub=$1 AND request_id=$2', [req.identity.sub,input.requestID])).rows[0];
      if (receipt) {
        if (receipt.request_hash !== hash) fail(409, 'request_id_reused');
        return {revision:receipt.revision};
      }
      const old = (await c.query('SELECT revision FROM cove_sync.snoozes WHERE owner_sub=$1 AND message_id=$2', [req.identity.sub,messageID])).rows[0];
      if ((old?.revision ?? '0') !== input.baseRevision) fail(409, 'snooze_conflict');
      if (!old) {
        const count = (await c.query('SELECT count(*) FROM cove_sync.snoozes WHERE owner_sub=$1', [req.identity.sub])).rows[0].count;
        if (Number(count) >= 5000) fail(409, 'snooze_storage_limit');
      }
      const next = (BigInt(current.snooze_revision) + 1n).toString();
      await c.query(`INSERT INTO cove_sync.snoozes(owner_sub,message_id,thread_id,wake_at,revision)
        VALUES($1,$2,$3,$4,$5) ON CONFLICT(owner_sub,message_id) DO UPDATE SET
        thread_id=EXCLUDED.thread_id,wake_at=EXCLUDED.wake_at,revision=EXCLUDED.revision,updated_at=now()`,
        [req.identity.sub,messageID,input.threadID,input.wakeAt,next]);
      await c.query('UPDATE cove_sync.accounts SET snooze_revision=$2 WHERE owner_sub=$1', [req.identity.sub,next]);
      await c.query('INSERT INTO cove_sync.receipts(owner_sub,request_id,request_hash,revision) VALUES($1,$2,$3,$4)', [req.identity.sub,input.requestID,hash,next]);
      await c.query("DELETE FROM cove_sync.receipts WHERE owner_sub=$1 AND created_at < now() - interval '7 days'", [req.identity.sub]);
      return {revision:next};
    });
  });
  app.get('/v1/snoozes/changes', async req => {
    const query = parse(z.object({accountID:uuid, after:revision.default('0')}).strict(), req.query);
    // Account and page use one lock to fence removal/reconnection and bound the cursor.
    return withOwner(req, async c => {
      const a = (await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1 FOR SHARE', [req.identity.sub])).rows[0];
      if (!a || a.account_id !== query.accountID) fail(409, 'connection_changed');
      if (BigInt(query.after) > BigInt(a.snooze_revision)) fail(400, 'invalid_cursor');
      const rows = (await c.query(`SELECT * FROM cove_sync.snoozes WHERE owner_sub=$1 AND revision>$2
        ORDER BY revision LIMIT 101`, [req.identity.sub,query.after])).rows;
      const page = rows.slice(0,100);
      return {accountID:a.account_id, cursor:page.at(-1)?.revision ?? query.after, hasMore:rows.length > 100,
        snoozes:page.map(r => ({id:r.message_id,threadID:r.thread_id,wakeAt:r.wake_at?.toISOString() ?? null,revision:r.revision}))};
    });
  });
}
