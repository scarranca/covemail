import { OAuth2Client } from 'google-auth-library';
export function googleVerifier({audiences, pilotEmails}, client = new OAuth2Client()) {
  if (!audiences.length || !pilotEmails.length) throw new Error('Explicit OAuth audiences and pilot allowlist required');
  const allowed = new Set(pilotEmails.map(x => x.toLowerCase()));
  return async token => {
    const ticket = await client.verifyIdToken({idToken: token, audience: audiences});
    const p = ticket.getPayload();
    if (!p?.sub || !p.email_verified || !p.email || !allowed.has(p.email.toLowerCase()) ||
        (!p.hd && !p.email.toLowerCase().endsWith('@gmail.com'))) throw new Error('Not a pilot account');
    if (p.azp && !audiences.includes(p.azp)) throw new Error('Unexpected authorized party');
    // The verified address lets push devices be found from Gmail's notification (hashed, migration 004).
    return {sub: p.sub, email: p.email.toLowerCase()};
  };
}
