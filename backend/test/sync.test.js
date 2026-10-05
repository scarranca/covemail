import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { createAPI } from '../src/api.js';
import { createPool, transaction, assertRuntimeRole } from '../src/database.js';
import { newKey, seal, open } from '../src/crypto.js';
import { googleVerifier } from '../src/auth.js';
import { emailHash } from '../src/push.js';
import { apnsJWT, newMailPayload } from '../src/apns.js';
import { generateKeyPairSync, verify as verifySignature } from 'node:crypto';

// Dedicated loopback-only synthetic database. Never point these tests at PlanetScale.
const admin = new pg.Pool({connectionString:'postgres://postgres:cove-synthetic-test@127.0.0.1:55439/postgres'});
let pool;
let app;
let clock = new Date('2026-09-25T12:00:00Z');
const objects = new Map();
const master = newKey();
let uploadHook;
// APNs stand-in: records pushes; tokens starting with "dead" answer 410 like an uninstalled app.
const pushes = [];
const fakeAPNs = { async send(p) { pushes.push(p);
  if (p.deviceToken.startsWith('dead')) return {status:410, reason:'Unregistered'};
  if (p.deviceToken.startsWith('5105')) return {status:0, reason:'timeout'};
  return {status:200}; } };
const keys = {
  async wrap(k, a) { return seal(master, k.toString('base64'), a); },
  async unwrap(k, a) { return Buffer.from(open(master, k, a), 'base64'); }
};
before(async () => {
  await admin.query('DROP SCHEMA IF EXISTS cove_sync CASCADE');
  await admin.query('DROP ROLE IF EXISTS cove_test_api');
  await admin.query('DROP ROLE IF EXISTS cove_sync_runtime');
  await admin.query(await readFile(new URL('../migrations/001_sync.sql', import.meta.url),'utf8'));
  await admin.query(await readFile(new URL('../migrations/002_snoozes.sql', import.meta.url),'utf8'));
  await admin.query(await readFile(new URL('../migrations/003_voice_profile.sql', import.meta.url),'utf8'));
  await admin.query(await readFile(new URL('../migrations/004_push_devices.sql', import.meta.url),'utf8'));
  await admin.query("CREATE ROLE cove_test_api LOGIN PASSWORD 'synthetic-api-only' NOSUPERUSER NOBYPASSRLS; GRANT cove_sync_runtime TO cove_test_api");
  pool = createPool('postgres://cove_test_api:synthetic-api-only@127.0.0.1:55439/postgres',{local:true});
  await assertRuntimeRole(pool);
  app = createAPI({pool, keys, now:() => clock, apns: fakeAPNs,
    verifyPubSub: async token => { if (token !== 'pubsub-fixture') throw new Error('no'); },
    verifyIdentity:async token => { if(!token.startsWith('fixture-')) throw new Error('no'); return {sub:token, email:`${token}@example.com`}; },
    bodies:{ async put(k,v) { if(uploadHook) await uploadHook(); objects.set(k,v); },
      async get(k) { if(!objects.has(k)) throw new Error('missing'); return objects.get(k); } }});
});
after(async () => { await app?.close(); await pool?.end(); await admin.end(); });
const request = (owner, method, url, payload) => app.inject({method,url,payload,headers:{authorization:`Bearer ${owner}`}});
const connect = async owner => {
  const r=await request(owner,'POST','/v1/connection',{consentVersion:'cloud-mail-v1'});
  assert.equal(r.statusCode,200,r.body); return r.json();
};
const mail = (id='abc') => ({id,threadID:'thread',receivedAt:clock.toISOString(),labels:['INBOX','UNREAD'],
  metadata:{sender:'Private Sender',senderEmail:'sender@example.com',to:'receiver@example.com',subject:'Private subject',messageID:'<private@example.com>'},
  body:{text:'Private body text',html:'<p>Private body text</p>',truncated:false}});
const input = (a, messages=[mail()], deletedIDs=[]) => ({...{accountID:a.accountID,baseRevision:a.revision},requestID:randomUUID(),messages,deletedIDs});

test('authentication, explicit consent, strict payloads and body limit',async () => {
  assert.equal((await app.inject('/v1/connection')).statusCode,401);
  assert.equal((await request('bad','GET','/v1/connection')).statusCode,401);
  assert.equal((await request('fixture-auth','POST','/v1/connection',{})).statusCode,400);
  const a=await connect('fixture-auth');
  assert.equal((await request('fixture-auth','POST','/v1/messages/batch',{...input(a),owner_sub:'fixture-victim'})).statusCode,400);
  const oversized=input(a);oversized.messages[0].body.text='x'.repeat(1100000);
  assert.equal((await request('fixture-auth','POST','/v1/messages/batch',oversized)).statusCode,413);
});
test('encrypted round trip, tenant isolation and RLS on pooled connections',async () => {
  const a=await connect('fixture-alice'); const b=await connect('fixture-bob');
  const r=await request('fixture-alice','POST','/v1/messages/batch',input(a));assert.equal(r.statusCode,200,r.body);
  const raw=(await admin.query("SELECT * FROM cove_sync.messages WHERE owner_sub='fixture-alice'")).rows[0];
  assert.equal(raw.content_cipher.includes(Buffer.from('Private')),false);
  assert.equal(objects.get(raw.body_object).includes(Buffer.from('Private')),false);
  const feed=await request('fixture-alice','GET',`/v1/messages/changes?accountID=${a.accountID}&after=0`);
  assert.equal(feed.json().messages[0].metadata.subject,'Private subject');
  const body=await request('fixture-alice','GET',`/v1/messages/abc/body?accountID=${a.accountID}`);
  assert.equal(body.json().text,'Private body text');
  assert.equal((await request('fixture-bob','GET',`/v1/messages/abc/body?accountID=${b.accountID}`)).statusCode,404);
  assert.equal((await request('fixture-bob','GET',`/v1/messages/changes?accountID=${a.accountID}`)).statusCode,409);
  await transaction(pool,'fixture-bob',async c => assert.equal((await c.query('SELECT * FROM cove_sync.messages')).rowCount,0));
  assert.equal((await pool.query('SELECT * FROM cove_sync.messages')).rowCount,0,'transaction-local identity must not leak through pool');
  await assert.rejects(transaction(pool,'fixture-bob',c => c.query("INSERT INTO cove_sync.accounts(owner_sub,account_id,wrapped_key) VALUES('fixture-impostor',$1,$2)",[randomUUID(),Buffer.from('x')])));
  await assert.rejects(assertRuntimeRole(admin));
});
test('idempotent retries, body reuse, stale writes and conflicting request IDs',async () => {
  const a=await connect('fixture-retry');const batch=input(a);const before=objects.size;
  const first=await request('fixture-retry','POST','/v1/messages/batch',batch); assert.equal(first.statusCode,200,first.body);
  const retry=await request('fixture-retry','POST','/v1/messages/batch',batch); assert.deepEqual(retry.json(),first.json());assert.equal(objects.size,before+1);
  assert.equal((await request('fixture-retry','POST','/v1/messages/batch',{...batch,messages:[{...mail(),labels:[]}]})).statusCode,409);
  assert.equal((await request('fixture-retry','POST','/v1/messages/batch',input(a,[mail('other')]))).statusCode,409);
  const changed=input({...a,...first.json()},[{...mail(),labels:['INBOX']}]);
  const result=await request('fixture-retry','POST','/v1/messages/batch',changed);assert.equal(result.statusCode,200,result.body);
  assert.equal(objects.size,before+1,'changing labels does not duplicate the body object');
});
test('concurrent batches serialize: one wins, stale one cannot overwrite',async () => {
  const a=await connect('fixture-concurrent');
  const r=await Promise.all([request('fixture-concurrent','POST','/v1/messages/batch',input(a,[mail('one')])),request('fixture-concurrent','POST','/v1/messages/batch',input(a,[mail('two')]))]);
  assert.deepEqual(r.map(x=>x.statusCode).sort(),[200,409]);
  const rows=await transaction(pool,'fixture-concurrent',c=>c.query('SELECT revision FROM cove_sync.messages'));
  assert.equal(rows.rowCount,1);assert.equal(rows.rows[0].revision,'1');
});
test('unique revisions paginate without losing changes and deletions yield tombstones',async () => {
  let a=await connect('fixture-pagination');
  for(let n=0;n<101;n+=5){
    const r=await request('fixture-pagination','POST','/v1/messages/batch',input(a,Array.from({length:Math.min(5,101-n)},(_,i)=>mail(`id${n+i}`))));
    assert.equal(r.statusCode,200,r.body);a={...a,...r.json()};
  }
  const first=(await request('fixture-pagination','GET',`/v1/messages/changes?accountID=${a.accountID}&after=0`)).json();
  assert.equal(first.messages.length,100);assert.equal(first.hasMore,true);assert.equal(first.cursor,'100');
  const next=(await request('fixture-pagination','GET',`/v1/messages/changes?accountID=${a.accountID}&after=${first.cursor}`)).json();
  assert.equal(next.messages.length,1);assert.equal(next.messages[0].id,'id100');
  const removed=await request('fixture-pagination','POST','/v1/messages/batch',input(a,[],['id100']));assert.equal(removed.statusCode,200,removed.body);
  const tombstones=(await request('fixture-pagination','GET',`/v1/messages/changes?accountID=${a.accountID}&after=101`)).json();
  assert.deepEqual(tombstones.messages,[{id:'id100',revision:'102',deleted:true}]);
  assert.equal((await request('fixture-pagination','GET',`/v1/messages/id100/body?accountID=${a.accountID}`)).statusCode,404);
});
test('deleted account cannot be recreated by an in-flight upload',async () => {
  const a=await connect('fixture-delete');let resume;let arrived;
  const gate=new Promise(r=>{arrived=r});
  uploadHook=async()=>{arrived();await new Promise(r=>{resume=r})};
  const pending=request('fixture-delete','POST','/v1/messages/batch',input(a));await gate;
  assert.equal((await request('fixture-delete','DELETE','/v1/connection',{accountID:a.accountID})).statusCode,200);
  resume();uploadHook=undefined;assert.equal((await pending).statusCode,409);
  assert.equal((await request('fixture-delete','GET','/v1/connection')).statusCode,404);
  const replacement=await connect('fixture-delete');assert.notEqual(replacement.accountID,a.accountID);
  assert.equal((await request('fixture-delete','POST','/v1/messages/batch',input(a))).statusCode,409);
});
test('body expires independently of object cleanup; rejects old initial uploads',async () => {
  const a=await connect('fixture-expiry');const batch=input(a);
  assert.equal((await request('fixture-expiry','POST','/v1/messages/batch',batch)).statusCode,200);
  clock=new Date(clock.getTime()+31*86400000);
  assert.equal((await request('fixture-expiry','GET',`/v1/messages/abc/body?accountID=${a.accountID}`)).statusCode,404);
  const feed=(await request('fixture-expiry','GET',`/v1/messages/changes?accountID=${a.accountID}`)).json();assert.equal(feed.messages[0].bodyAvailable,false);
  const b=await connect('fixture-old');assert.equal((await request('fixture-old','POST','/v1/messages/batch',input(b,batch.messages))).statusCode,400);
});
test('AEAD rejects moved and modified ciphertext',()=>{
  const key=newKey(), cipher=seal(key,{private:'message'},'account/message');
  assert.throws(()=>open(key,cipher,'another/message'));
  const tampered=Buffer.from(cipher);tampered[14]^=1;assert.throws(()=>open(key,tampered,'account/message'));
});
test('identity verifier requires approved audiences, verified email and pilot membership',async()=>{
  let payload={sub:'123',email:'pilot@example.com',email_verified:true,hd:'example.com',azp:'desktop'};
  const verify=googleVerifier({audiences:['desktop'],pilotEmails:['pilot@example.com']},{async verifyIdToken(options){assert.deepEqual(options.audience,['desktop']);return {getPayload:()=>payload}}});
  assert.deepEqual(await verify('token'),{sub:'123',email:'pilot@example.com'});
  for(const patch of [{email_verified:false},{email:'someone@example.com'},{azp:'attacker'},{hd:undefined}]){
    const original=payload;payload={...payload,...patch};await assert.rejects(verify('token'));payload=original;
  }
});


test('Swift uppercase UUID encoding is normalized for uploads, reads and removal',async () => {
  const owner='fixture-swift-uuid'; const a=await connect(owner);
  const payload=input(a); payload.accountID=payload.accountID.toUpperCase(); payload.requestID=payload.requestID.toUpperCase();
  const r=await request(owner,'POST','/v1/messages/batch',payload); assert.equal(r.statusCode,200,r.body);
  const lower={...payload,accountID:payload.accountID.toLowerCase(),requestID:payload.requestID.toLowerCase()};
  assert.equal((await request(owner,'POST','/v1/messages/batch',lower)).json().revision,r.json().revision);
  assert.equal((await request(owner,'GET',`/v1/messages/changes?accountID=${payload.accountID}`)).json().messages.length,1);
  assert.equal((await request(owner,'GET',`/v1/messages/abc/body?accountID=${payload.accountID}`)).statusCode,200);
  assert.equal((await request(owner,'DELETE','/v1/connection',{accountID:payload.accountID})).statusCode,200);
});

const snoozeInput = (a, overrides={}) => ({accountID:a.accountID,requestID:randomUUID(),baseRevision:'0',
  threadID:'old-thread',wakeAt:'2026-11-01T17:00:00Z',...overrides});
test('snoozes outlive the mail mirror, cancellation is explicit, due dates remain server-readable', async () => {
  const owner='fixture-snooze'; const a=await connect(owner);
  const input=snoozeInput(a);
  const first=await request(owner,'PUT','/v1/snoozes/oldmail',input);
  assert.equal(first.statusCode,200,first.body);
  assert.equal((await admin.query('SELECT count(*) FROM cove_sync.messages WHERE owner_sub=$1',[owner])).rows[0].count,'0');
  let feed=(await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}`)).json();
  assert.equal(feed.snoozes[0].wakeAt,'2026-11-01T17:00:00.000Z');
  assert.deepEqual(Object.keys(feed.snoozes[0]).sort(),['id','revision','threadID','wakeAt']);
  // Mail-mirror removals cannot remove a reminder, including for an unmirrored old message.
  assert.equal((await request(owner,'POST','/v1/messages/batch',inputForRemoval(a))).statusCode,200);
  function inputForRemoval(a) { return {accountID:a.accountID,requestID:randomUUID(),baseRevision:a.revision,messages:[],deletedIDs:['oldmail']}; }
  const cancel=await request(owner,'PUT','/v1/snoozes/oldmail',snoozeInput(a,{baseRevision:first.json().revision,wakeAt:null}));
  assert.equal(cancel.statusCode,200,cancel.body);
  feed=(await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}&after=${first.json().revision}`)).json();
  assert.equal(feed.snoozes[0].wakeAt,null);assert.equal(feed.cursor,cancel.json().revision);
  // Offline changes can arrive after their due date; don't drop these timestamps.
  const past=await request(owner,'PUT','/v1/snoozes/pastmail',snoozeInput(a,{wakeAt:'2020-01-01T09:00:00Z'}));
  assert.equal(past.statusCode,200,past.body);
  const due=await transaction(pool,owner,c=>c.query('SELECT message_id FROM cove_sync.snoozes WHERE wake_at <= now()'));
  assert.deepEqual(due.rows.map(r=>r.message_id),['pastmail']);
});
test('snooze retries are idempotent and stale writes cannot restore a cancelled reminder', async () => {
  const owner='fixture-snooze-retry'; const a=await connect(owner); const input=snoozeInput(a);
  const first=await request(owner,'PUT','/v1/snoozes/abc',input);assert.equal(first.statusCode,200,first.body);
  const cancel=await request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a,{baseRevision:first.json().revision,wakeAt:null}));
  assert.equal(cancel.statusCode,200,cancel.body);
  const retry=await request(owner,'PUT','/v1/snoozes/abc',input);assert.deepEqual(retry.json(),first.json());
  assert.equal((await request(owner,'PUT','/v1/snoozes/abc',{...input,wakeAt:null})).json().error,'request_id_reused');
  assert.equal((await request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a))).json().error,'snooze_conflict');
  const feed=(await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}`)).json();
  assert.equal(feed.snoozes[0].wakeAt,null);
  // Old clients' mail uploads do not affect snooze revisions or state.
  assert.equal((await request(owner,'POST','/v1/messages/batch',inputMail(a))).statusCode,200);
  function inputMail(a) { return {accountID:a.accountID,requestID:randomUUID(),baseRevision:a.revision,messages:[mail()],deletedIDs:[]}; }
});
test('snooze authentication, strict validation, forced RLS and connection fencing', async () => {
  const owner='fixture-snooze-owner';const a=await connect(owner);const b=await connect('fixture-snooze-other');
  assert.equal((await app.inject({method:'PUT',url:'/v1/snoozes/abc',payload:snoozeInput(a)})).statusCode,401);
  for(const change of [{wakeAt:undefined},{wakeAt:'tomorrow'},{owner_sub:'victim'},{body:'private email'}]) {
    assert.equal((await request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a,change))).statusCode,400);
  }
  assert.equal((await request('fixture-snooze-other','PUT','/v1/snoozes/abc',snoozeInput(a))).statusCode,409);
  assert.equal((await request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a))).statusCode,200);
  await transaction(pool,'fixture-snooze-other',async c => {
    assert.equal((await c.query('SELECT * FROM cove_sync.snoozes')).rowCount,0);
    await assert.rejects(c.query('INSERT INTO cove_sync.snoozes(owner_sub,message_id,thread_id,revision) VALUES($1,$2,$3,1)',[owner,'intruder','thread']));
  });
  assert.equal((await pool.query('SELECT * FROM cove_sync.snoozes')).rowCount,0);
  assert.equal((await request('fixture-snooze-other','GET',`/v1/snoozes/changes?accountID=${b.accountID}`)).json().snoozes.length,0);
  assert.equal((await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}&after=100`)).statusCode,400);
  assert.equal((await request(owner,'DELETE','/v1/connection',{accountID:a.accountID})).statusCode,200);
  const fresh=await connect(owner);assert.notEqual(fresh.accountID,a.accountID);
  assert.equal((await request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a))).statusCode,409);
  assert.equal((await request(owner,'GET',`/v1/snoozes/changes?accountID=${fresh.accountID}`)).json().snoozes.length,0);
});
test('concurrent snooze edits serialize per record while different messages can both succeed', async () => {
  const owner='fixture-snooze-concurrent';const a=await connect(owner);
  const responses=await Promise.all([request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a)),request(owner,'PUT','/v1/snoozes/abc',snoozeInput(a,{wakeAt:null}))]);
  assert.deepEqual(responses.map(r=>r.statusCode).sort(),[200,409]);
  const independent=await Promise.all([request(owner,'PUT','/v1/snoozes/def',snoozeInput(a)),request(owner,'PUT','/v1/snoozes/fed',snoozeInput(a))]);
  assert.deepEqual(independent.map(r=>r.statusCode),[200,200]);
  assert.notEqual(independent[0].json().revision,independent[1].json().revision);
});
test('snooze change feed paginates cancelled and active records; storage quota preserves existing edits', async () => {
  const owner='fixture-snooze-pages';const a=await connect(owner);
  await admin.query(`INSERT INTO cove_sync.snoozes(owner_sub,message_id,thread_id,wake_at,revision)
    SELECT $1,'msg'||n,'thread',CASE WHEN n%2=0 THEN NULL ELSE now()+interval '1 day' END,n FROM generate_series(1,5000) n`,[owner]);
  await admin.query('UPDATE cove_sync.accounts SET snooze_revision=5000 WHERE owner_sub=$1',[owner]);
  const first=(await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}`)).json();
  assert.equal(first.snoozes.length,100);assert.equal(first.hasMore,true);assert.equal(first.cursor,'100');
  const last=(await request(owner,'GET',`/v1/snoozes/changes?accountID=${a.accountID}&after=4900`)).json();
  assert.equal(last.snoozes.length,100);assert.equal(last.hasMore,false);assert.equal(last.cursor,'5000');
  assert.equal(last.snoozes.at(-1).wakeAt,null);
  assert.equal((await request(owner,'PUT','/v1/snoozes/new',snoozeInput(a))).json().error,'snooze_storage_limit');
  assert.equal((await request(owner,'PUT','/v1/snoozes/msg1',snoozeInput(a,{baseRevision:'1',wakeAt:null}))).statusCode,200);
});

const voice = (overrides={}) => ({summary:'Warm and brief.',greetings:['Hi {name},'],signoffs:['Best,'],traits:['Short'],
  phrases:[],languages:['English'],learnedAt:'2026-09-29T10:00:00Z',sampleCount:20,model:'fixture',...overrides});
test('voice profile is encrypted per account, follows the Google identity and is isolated by RLS', async () => {
  const owner='fixture-voice'; const a=await connect(owner);
  let got=(await request(owner,'GET',`/v1/voice?accountID=${a.accountID}`)).json();
  assert.deepEqual(got,{revision:'0',profile:null,updatedAt:null});
  const put={accountID:a.accountID,requestID:randomUUID(),baseRevision:'0',profile:voice(),updatedAt:'2026-09-29T10:00:00Z'};
  const first=await request(owner,'PUT','/v1/voice',put);
  assert.equal(first.statusCode,200,first.body); assert.equal(first.json().revision,'1');
  // Stored bytes are ciphertext, not the style text.
  const row=(await admin.query('SELECT ciphertext FROM cove_sync.voice_profiles WHERE owner_sub=$1',[owner])).rows[0];
  assert.equal(row.ciphertext.toString().includes('Warm and brief'),false);
  got=(await request(owner,'GET',`/v1/voice?accountID=${a.accountID}`)).json();
  assert.equal(got.profile.summary,'Warm and brief.'); assert.equal(got.revision,'1');
  // Identical retry is idempotent; a stale base cannot overwrite; a reused request ID with other content is rejected.
  assert.equal((await request(owner,'PUT','/v1/voice',put)).json().revision,'1');
  assert.equal((await request(owner,'PUT','/v1/voice',{...put,requestID:randomUUID()})).json().error,'voice_conflict');
  assert.equal((await request(owner,'PUT','/v1/voice',{...put,profile:voice({summary:'Other'})})).json().error,'request_id_reused');
  // Forgetting is an explicit null record.
  const forget=await request(owner,'PUT','/v1/voice',{...put,requestID:randomUUID(),baseRevision:'1',profile:null,updatedAt:'2026-09-30T10:00:00Z'});
  assert.equal(forget.json().revision,'2');
  got=(await request(owner,'GET',`/v1/voice?accountID=${a.accountID}`)).json();
  assert.equal(got.profile,null); assert.equal(got.updatedAt,'2026-09-30T10:00:00Z');
  // Another tenant sees nothing, even through the pooled runtime role.
  const other='fixture-voice-other'; const b=await connect(other);
  assert.equal((await request(other,'GET',`/v1/voice?accountID=${b.accountID}`)).json().revision,'0');
  assert.equal((await request(other,'GET',`/v1/voice?accountID=${a.accountID}`)).json().error,'connection_changed');
  const leaked=await transaction(pool,other,c=>c.query('SELECT count(*) FROM cove_sync.voice_profiles'));
  assert.equal(leaked.rows[0].count,'0');
});
test('voice payloads are strict and bounded; mail content fields are rejected', async () => {
  const owner='fixture-voice-strict'; const a=await connect(owner);
  const base={accountID:a.accountID,requestID:randomUUID(),baseRevision:'0',updatedAt:'2026-09-29T10:00:00Z'};
  assert.equal((await request(owner,'PUT','/v1/voice',{...base,profile:{...voice(),body:'raw email'}})).statusCode,400);
  assert.equal((await request(owner,'PUT','/v1/voice',{...base,profile:voice({summary:'x'.repeat(601)})})).statusCode,400);
  assert.equal((await request(owner,'PUT','/v1/voice',{...base,profile:voice({phrases:Array(9).fill('a')})})).statusCode,400);
  assert.equal((await app.inject({method:'GET',url:`/v1/voice?accountID=${a.accountID}`})).statusCode,401);
});

const token = (fill = 'a') => fill.repeat(64);
const pubsub = (email, historyId, auth = 'pubsub-fixture') => app.inject({method:'POST', url:'/v1/gmail/push',
  headers: auth ? {authorization:`Bearer ${auth}`} : {},
  payload:{message:{data:Buffer.from(JSON.stringify({emailAddress:email, historyId})).toString('base64'), messageId:'1'}, subscription:'s'}});

test('push devices: owner registration, strict payloads and per-owner isolation', async () => {
  const id = randomUUID();
  assert.equal((await request('fixture-push','PUT',`/v1/push/devices/${id}`,{token:token(),environment:'production'})).statusCode,200);
  assert.equal((await request('fixture-push','PUT',`/v1/push/devices/${id}`,{token:'zz',environment:'production'})).statusCode,400);
  assert.equal((await request('fixture-push','PUT',`/v1/push/devices/${id}`,{token:token(),environment:'production',email:'x@y.z'})).statusCode,400);
  assert.equal((await app.inject({method:'PUT',url:`/v1/push/devices/${id}`,payload:{token:token(),environment:'production'}})).statusCode,401);
  // Another owner can't see or remove it, even through the delivery setting.
  await transaction(pool,'fixture-other',async c => {
    assert.equal((await c.query('SELECT * FROM cove_sync.push_devices')).rowCount,0);
    await c.query("SELECT set_config('cove.push_email_hash','', true)");
    assert.equal((await c.query('DELETE FROM cove_sync.push_devices')).rowCount,0);
  });
  const stored = (await admin.query('SELECT email_hash, apns_token FROM cove_sync.push_devices WHERE owner_sub=$1',['fixture-push'])).rows[0];
  assert.equal(stored.email_hash, emailHash('fixture-push@example.com'));
  assert.equal(stored.apns_token, token());
});

test('gmail push: verified Pub/Sub only, content-free APNs, unregistered devices removed', async () => {
  pushes.length = 0;
  const live = randomUUID(), dead = randomUUID();
  await request('fixture-mailbox','PUT',`/v1/push/devices/${live}`,{token:token('b'),environment:'sandbox'});
  await request('fixture-mailbox','PUT',`/v1/push/devices/${dead}`,{token:'dead'+token('c').slice(4),environment:'production'});
  assert.equal((await pubsub('fixture-mailbox@example.com', 99, null)).statusCode,401);
  assert.equal((await pubsub('fixture-mailbox@example.com', 99, 'forged')).statusCode,401);
  assert.equal(pushes.length,0);
  const r = await pubsub('Fixture-Mailbox@Example.com', '12345');
  assert.equal(r.statusCode,204,r.body);
  assert.equal(pushes.length,2);
  const sent = pushes.find(p => p.deviceToken === token('b'));
  assert.equal(sent.environment,'sandbox');
  assert.deepEqual(sent.payload.aps.alert,{title:'Cove',body:'New email'});
  assert.equal(sent.payload.cove.historyID,'12345');
  assert.ok(!JSON.stringify(sent.payload).includes('fixture-mailbox@'), 'no address in the push');
  const left = (await admin.query('SELECT device_id FROM cove_sync.push_devices WHERE owner_sub=$1',['fixture-mailbox'])).rows.map(r=>r.device_id);
  assert.deepEqual(left,[live]);
  // Unknown addresses and malformed messages are acknowledged without pushes.
  pushes.length = 0;
  assert.equal((await pubsub('nobody@example.com', 1)).statusCode,204);
  assert.equal((await app.inject({method:'POST',url:'/v1/gmail/push',headers:{authorization:'Bearer pubsub-fixture'},
    payload:{message:{data:'not-base64-json'}}})).statusCode,204);
  assert.equal(pushes.length,0);
  assert.equal((await request('fixture-mailbox','DELETE',`/v1/push/devices/${live}`)).statusCode,200);
});

test('push device limit and APNs token format', async () => {
  for (let i = 0; i < 10; i++)
    assert.equal((await request('fixture-many','PUT',`/v1/push/devices/${randomUUID()}`,{token:token(String(i)),environment:'production'})).statusCode,200);
  assert.equal((await request('fixture-many','PUT',`/v1/push/devices/${randomUUID()}`,{token:token('f'),environment:'production'})).statusCode,409);
  const {privateKey, publicKey} = generateKeyPairSync('ec', {namedCurve:'P-256'});
  const jwt = apnsJWT({keyPEM: privateKey.export({type:'pkcs8',format:'pem'}), keyID:'ABCDE12345', teamID:'27H459Y2P9'}, 1_800_000_000_000);
  const [h, c, sig] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h,'base64url')), {alg:'ES256', kid:'ABCDE12345'});
  assert.deepEqual(JSON.parse(Buffer.from(c,'base64url')), {iss:'27H459Y2P9', iat:1_800_000_000});
  assert.ok(verifySignature('sha256', Buffer.from(`${h}.${c}`), {key:publicKey, dsaEncoding:'ieee-p1363'}, Buffer.from(sig,'base64url')));
  assert.equal(newMailPayload({historyID:5, account:'x'}).aps['mutable-content'], 1);
});

test('gmail push asks Pub/Sub to retry when APNs is unreachable', async () => {
  pushes.length = 0;
  const id = randomUUID();
  await request('fixture-flaky','PUT',`/v1/push/devices/${id}`,{token:'5105'+token('d').slice(4),environment:'production'});
  assert.equal((await pubsub('fixture-flaky@example.com', 7)).statusCode, 503);
  assert.equal(pushes.length, 1);
  // The device is kept for the retry.
  assert.equal((await admin.query('SELECT count(*) FROM cove_sync.push_devices WHERE owner_sub=$1',['fixture-flaky'])).rows[0].count, '1');
});
