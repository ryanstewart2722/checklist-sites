// Uploads ~/.checklist-sync/events.json to Firestore (checklist/studio-cal-sync) using the
// service-account key at ~/.checklist-sync/key.json. No npm packages needed.
// The key never leaves this Mac except to get a short-lived Google access token.

import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DOC = 'checklist/studio-cal-sync';
const eventsFile = process.argv[2] || join(homedir(), '.checklist-sync', 'events.json');
const key = JSON.parse(readFileSync(join(homedir(), '.checklist-sync', 'key.json'), 'utf8'));
const payload = readFileSync(eventsFile, 'utf8');

const b64url = s => Buffer.from(s).toString('base64url');

async function accessToken() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: key.client_email,
    scope: 'https://www.googleapis.com/auth/datastore',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600,
  }));
  const sig = createSign('RSA-SHA256').update(`${head}.${claims}`).sign(key.private_key, 'base64url');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${head}.${claims}.${sig}`,
    }),
  });
  if (!res.ok) throw new Error('Token request failed: ' + res.status + ' ' + await res.text());
  return (await res.json()).access_token;
}

const token = await accessToken();
const url = `https://firestore.googleapis.com/v1/projects/${key.project_id}/databases/(default)/documents/${DOC}`;
const res = await fetch(url, {
  method: 'PATCH',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    fields: {
      json: { stringValue: payload },
      savedAt: { timestampValue: new Date().toISOString() },
    },
  }),
});
if (!res.ok) {
  console.error('Upload failed:', res.status, await res.text());
  process.exit(1);
}
console.error(`Uploaded ${JSON.parse(payload).events.length} events at ${new Date().toLocaleString()}.`);
