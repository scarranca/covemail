import { z } from 'zod';
import { digest, seal, open, context } from './crypto.js';

// One learned writing-voice profile per Google identity: a style description only, never mail.
// Encrypted with the account data key (server-accessible, not end-to-end). A null profile is an
// explicit "forgotten" state so other Macs drop their copies.
const text = max => z.string().max(max);
const profile = z.object({
  summary: text(600).min(1), greetings: z.array(text(60)).max(4), signoffs: z.array(text(60)).max(4),
  traits: z.array(text(140)).max(8), phrases: z.array(text(80)).max(8), languages: z.array(text(30)).max(4),
  learnedAt: z.string().datetime(), sampleCount: z.number().int().min(0).max(1000), model: text(120),
}).strict();

export function registerVoice(app, {withOwner, account, keys, parse, fail, uuid, revision}) {
  const mutation = z.object({accountID: uuid, requestID: uuid, baseRevision: revision,
    profile: profile.nullable(), updatedAt: z.string().datetime()}).strict();
  app.put('/v1/voice', async req => {
    const input = parse(mutation, req.body);
    const a = await account(req);
    if (a.account_id !== input.accountID) fail(409, 'connection_changed');
    const key = await keys.unwrap(a.wrapped_key, a.account_id);
    const hash = digest(key, {kind: 'voice', input});
    const cipher = seal(key, {profile: input.profile, updatedAt: input.updatedAt}, context(a.account_id, 'voice', 'profile'));
    return withOwner(req, async c => {
      const current = (await c.query('SELECT * FROM cove_sync.accounts WHERE owner_sub=$1 FOR UPDATE', [req.identity.sub])).rows[0];
      if (!current || current.account_id !== input.accountID) fail(409, 'connection_changed');
      const receipt = (await c.query('SELECT * FROM cove_sync.receipts WHERE owner_sub=$1 AND request_id=$2', [req.identity.sub, input.requestID])).rows[0];
      if (receipt) {
        if (receipt.request_hash !== hash) fail(409, 'request_id_reused');
        return {revision: receipt.revision};
      }
      const old = (await c.query('SELECT revision FROM cove_sync.voice_profiles WHERE owner_sub=$1', [req.identity.sub])).rows[0];
      if ((old?.revision ?? '0') !== input.baseRevision) fail(409, 'voice_conflict');
      const next = (BigInt(old?.revision ?? '0') + 1n).toString();
      await c.query(`INSERT INTO cove_sync.voice_profiles(owner_sub,ciphertext,revision) VALUES($1,$2,$3)
        ON CONFLICT(owner_sub) DO UPDATE SET ciphertext=EXCLUDED.ciphertext,revision=EXCLUDED.revision,updated_at=now()`,
        [req.identity.sub, cipher, next]);
      await c.query('INSERT INTO cove_sync.receipts(owner_sub,request_id,request_hash,revision) VALUES($1,$2,$3,$4)', [req.identity.sub, input.requestID, hash, next]);
      return {revision: next};
    });
  });
  app.get('/v1/voice', async req => {
    const query = parse(z.object({accountID: uuid}).strict(), req.query);
    const a = await account(req);
    if (a.account_id !== query.accountID) fail(409, 'connection_changed');
    const key = await keys.unwrap(a.wrapped_key, a.account_id);
    return withOwner(req, async c => {
      const row = (await c.query('SELECT * FROM cove_sync.voice_profiles WHERE owner_sub=$1', [req.identity.sub])).rows[0];
      if (!row) return {revision: '0', profile: null, updatedAt: null};
      const value = open(key, row.ciphertext, context(a.account_id, 'voice', 'profile'));
      return {revision: row.revision, profile: value.profile, updatedAt: value.updatedAt};
    });
  });
}
