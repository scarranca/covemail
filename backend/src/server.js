import { createPool, assertRuntimeRole } from './database.js';
import { googleVerifier } from './auth.js';
import { cloudProviders } from './cloud.js';
import { createAPI } from './api.js';
import { OAuth2Client } from 'google-auth-library';
import { apnsClient } from './apns.js';
import { pubsubVerifier } from './push.js';
const required = name => { if (!process.env[name]) throw new Error(`Missing ${name}`); return process.env[name]; };
const pool = createPool(required('DATABASE_URL'));
await assertRuntimeRole(pool);
const providers = cloudProviders({kmsKey: required('CONTENT_KMS_KEY'), bucketName: required('BODY_BUCKET')});
// New-mail push is optional: without its configuration the push routes answer push_unavailable.
const push = process.env.APNS_KEY && process.env.PUSH_AUDIENCE ? {
  apns: apnsClient({keyPEM: process.env.APNS_KEY, keyID: required('APNS_KEY_ID'), teamID: required('APNS_TEAM_ID'),
    topic: required('APNS_TOPIC')}),
  verifyPubSub: pubsubVerifier({audience: process.env.PUSH_AUDIENCE, serviceAccount: required('PUSH_SERVICE_ACCOUNT')},
    new OAuth2Client()),
} : {};
const app = createAPI({pool, ...providers, ...push,
  log: entry => console.log(JSON.stringify(entry)),
  verifyIdentity: googleVerifier({
    audiences: required('GOOGLE_CLIENT_IDS').split(','), pilotEmails: required('PILOT_EMAILS').split(',')})});
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, async () => { await app.close(); await pool.end(); process.exit(0); });
await app.listen({host:'0.0.0.0', port:Number(process.env.PORT ?? 8080)});
