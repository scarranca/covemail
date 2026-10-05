import http2 from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

// Apple Push Notification service over HTTP/2 with a token-based (.p8) key. The key stays in Secret
// Manager; tokens are short-lived ES256 JWTs refreshed every 40 minutes, as Apple requires.
const hosts = {production: 'https://api.push.apple.com', sandbox: 'https://api.sandbox.push.apple.com'};

export function apnsJWT({keyPEM, keyID, teamID}, now = Date.now()) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({alg: 'ES256', kid: keyID})}.${encode({iss: teamID, iat: Math.floor(now / 1000)})}`;
  const signature = sign('sha256', Buffer.from(unsigned), {key: createPrivateKey(keyPEM), dsaEncoding: 'ieee-p1363'});
  return `${unsigned}.${signature.toString('base64url')}`;
}

/// The push for new mail. It carries no mail content: the device's notification extension reads the
/// new email with its own Google sign-in and replaces this placeholder text.
export function newMailPayload({historyID, account}) {
  return {
    aps: {alert: {title: 'Cove', body: 'New email'}, 'mutable-content': 1, 'thread-id': 'cove-mail'},
    cove: {historyID: String(historyID), account},
  };
}

export function apnsClient({keyPEM, keyID, teamID, topic}, {connect = http2.connect, clock = Date.now} = {}) {
  if (!keyPEM || !/^[A-Z0-9]{10}$/.test(keyID ?? '') || !/^[A-Z0-9]{10}$/.test(teamID ?? '') || !topic)
    throw new Error('APNs needs a .p8 key, key ID, team ID and topic');
  let token = null;
  const sessions = new Map();
  function bearer() {
    if (!token || clock() - token.at > 40 * 60 * 1000) token = {value: apnsJWT({keyPEM, keyID, teamID}, clock()), at: clock()};
    return token.value;
  }
  function session(environment) {
    const existing = sessions.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const created = connect(hosts[environment]);
    created.on('error', () => sessions.delete(environment));
    created.on('close', () => sessions.delete(environment));
    sessions.set(environment, created);
    return created;
  }
  /// Sends one push. Resolves {status, reason}; never throws for an APNs rejection.
  async function send({deviceToken, environment, payload, expiresInSeconds = 3600}) {
    const body = JSON.stringify(payload);
    return new Promise(resolve => {
      let request;
      try {
        request = session(environment).request({
          ':method': 'POST', ':path': `/3/device/${deviceToken}`,
          authorization: `bearer ${bearer()}`, 'apns-topic': topic, 'apns-push-type': 'alert',
          'apns-priority': '10', 'apns-expiration': String(Math.floor(clock() / 1000) + expiresInSeconds),
          'content-type': 'application/json',
        });
      } catch { resolve({status: 0, reason: 'connection_failed'}); return; }
      let status = 0;
      let text = '';
      const timer = setTimeout(() => { request.close(); resolve({status: 0, reason: 'timeout'}); }, 10000);
      request.on('response', headers => { status = Number(headers[':status']); });
      request.setEncoding('utf8');
      request.on('data', chunk => { if (text.length < 2048) text += chunk; });
      request.on('end', () => {
        clearTimeout(timer);
        let reason;
        try { reason = text ? JSON.parse(text).reason : undefined; } catch { reason = undefined; }
        resolve({status, reason: typeof reason === 'string' ? reason.slice(0, 64) : undefined});
      });
      request.on('error', () => { clearTimeout(timer); resolve({status: 0, reason: 'stream_failed'}); });
      request.end(body);
    });
  }
  return {send, close: () => { for (const s of sessions.values()) s.close(); sessions.clear(); }};
}
