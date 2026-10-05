import { z } from 'zod';
import { newKey, seal, open } from './crypto.js';

// About you, one per Google identity: the user's own words about themselves, never mail. It does
// not need the cloud mail mirror: each row has its own KMS-wrapped data key bound to the owner.
// Server keys can decrypt it (not end-to-end). Newest edit wins on the devices; the server only
// orders writes by revision.
const line = max => z.string().max(max);
const personal = z.object({
  name: line(80), role: line(80), company: line(80), about: line(400),
  projects: z.array(z.object({id: z.string().uuid(), name: line(80), detail: line(200)}).strict()).max(8),
  notes: z.array(line(200)).max(20), signature: line(200), enabled: z.boolean(),
}).strict();
const keyContext = owner => `cove-personal-v1:${owner}`;
const recordContext = owner => JSON.stringify(['cove-personal-v1', owner, 'about-you']);

export function registerPersonal(app, {withOwner, keys, parse, fail, revision}) {
  const mutation = z.object({baseRevision: revision, personal, updatedAt: z.string().datetime()}).strict();
  app.get('/v1/personal', async req => withOwner(req, async c => {
    const row = (await c.query('SELECT * FROM cove_sync.personal_contexts WHERE owner_sub=$1', [req.identity.sub])).rows[0];
    if (!row) return {revision: '0', personal: null, updatedAt: null};
    const key = await keys.unwrap(row.wrapped_key, keyContext(req.identity.sub));
    const value = open(key, row.ciphertext, recordContext(req.identity.sub));
    return {revision: row.revision, personal: value.personal, updatedAt: value.updatedAt};
  }));
  app.put('/v1/personal', async req => {
    const input = parse(mutation, req.body);
    const owner = req.identity.sub;
    const existing = await withOwner(req, async c =>
      (await c.query('SELECT wrapped_key FROM cove_sync.personal_contexts WHERE owner_sub=$1', [owner])).rows[0]);
    const wrapped = existing?.wrapped_key ?? await keys.wrap(newKey(), keyContext(owner));
    const key = await keys.unwrap(wrapped, keyContext(owner));
    const cipher = seal(key, {personal: input.personal, updatedAt: input.updatedAt}, recordContext(owner));
    return withOwner(req, async c => {
      const old = (await c.query('SELECT revision FROM cove_sync.personal_contexts WHERE owner_sub=$1 FOR UPDATE', [owner])).rows[0];
      if ((old?.revision ?? '0') !== input.baseRevision) fail(409, 'personal_conflict');
      const next = (BigInt(old?.revision ?? '0') + 1n).toString();
      // A concurrent first write with another key or revision wins; this one is told to retry.
      const written = await c.query(`INSERT INTO cove_sync.personal_contexts(owner_sub,wrapped_key,ciphertext,revision) VALUES($1,$2,$3,$4)
        ON CONFLICT(owner_sub) DO UPDATE SET ciphertext=EXCLUDED.ciphertext, revision=EXCLUDED.revision, updated_at=now()
        WHERE cove_sync.personal_contexts.wrapped_key = EXCLUDED.wrapped_key
          AND cove_sync.personal_contexts.revision = $5`, [owner, wrapped, cipher, next, old?.revision ?? '0']);
      if (!written.rowCount) fail(409, 'personal_conflict');
      return {revision: next};
    });
  });
  // Removes the server copy. Devices keep their own copy; it is never deleted on a device from here.
  app.delete('/v1/personal', async req => withOwner(req, async c => {
    await c.query('DELETE FROM cove_sync.personal_contexts WHERE owner_sub=$1', [req.identity.sub]);
    return {deleted: true};
  }));
}
