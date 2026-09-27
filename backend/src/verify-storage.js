// One-shot deployment smoke check. Only generated synthetic content is used.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createPool, assertRuntimeRole } from './database.js';
import { cloudProviders } from './cloud.js';
import { newKey, seal, open, context } from './crypto.js';
const pool = createPool(process.env.DATABASE_URL);
try {
  await assertRuntimeRole(pool);
  const {keys,bodies} = cloudProviders({kmsKey:process.env.CONTENT_KMS_KEY,bucketName:process.env.BODY_BUCKET});
  const account = randomUUID(); const owner = 'deployment-check-' + account;
  const key = newKey(); const wrapped = await keys.wrap(key,account);
  assert.deepEqual(await keys.unwrap(wrapped,account),key);
  await assert.rejects(keys.unwrap(wrapped,randomUUID()));
  const name = `${account}/${randomUUID()}`;
  const fixture = {text:'Synthetic Cove deployment check'};
  await bodies.put(name,seal(key,fixture,context(account,'fixture','body')));
  assert.deepEqual(open(key,await bodies.get(name),context(account,'fixture','body')),fixture);
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query("SELECT set_config('cove.owner_sub',$1,true)",[owner]);
    await c.query('INSERT INTO cove_sync.accounts(owner_sub,account_id,wrapped_key) VALUES($1,$2,$3)',[owner,account,wrapped]);
    assert.equal((await c.query('SELECT account_id FROM cove_sync.accounts')).rowCount,1);
    await c.query(`INSERT INTO cove_sync.snoozes(owner_sub,message_id,thread_id,wake_at,revision)
      VALUES($1,'fixture','fixture-thread',now() - interval '1 minute',1)`,[owner]);
    assert.equal((await c.query('SELECT message_id FROM cove_sync.snoozes WHERE wake_at <= now()')).rowCount,1);
    await c.query('UPDATE cove_sync.accounts SET snooze_revision=1 WHERE owner_sub=$1',[owner]);
    assert.equal((await c.query('SELECT snooze_revision FROM cove_sync.accounts')).rows[0].snooze_revision,'1');
    const security = (await c.query(`SELECT relrowsecurity,relforcerowsecurity FROM pg_class
      WHERE oid='cove_sync.snoozes'::regclass`)).rows[0];
    assert.equal(security.relrowsecurity,true);assert.equal(security.relforcerowsecurity,true);
    await c.query("SELECT set_config('cove.owner_sub',$1,true)",[owner+'-other']);
    assert.equal((await c.query('SELECT account_id FROM cove_sync.accounts')).rowCount,0);
    assert.equal((await c.query('SELECT message_id FROM cove_sync.snoozes')).rowCount,0);
    await c.query("SELECT set_config('cove.owner_sub',$1,true)",[owner]);
    await c.query('UPDATE cove_sync.snoozes SET wake_at=NULL,revision=2 WHERE owner_sub=$1 AND message_id=$2',[owner,'fixture']);
    assert.equal((await c.query('SELECT message_id FROM cove_sync.snoozes WHERE wake_at <= now()')).rowCount,0);
  } finally { await c.query('ROLLBACK');c.release(); }
  console.log('PASS: verified TLS, restricted role, tenant isolation, snooze storage/cancellation and forced RLS, KMS authenticated wrapping and encrypted object round trip. Synthetic DB transaction rolled back; small ciphertext object expires by lifecycle.');
} catch(e) { console.error('Deployment storage check failed:',e.code ?? e.name);process.exitCode=1; }
finally { await pool.end(); }
