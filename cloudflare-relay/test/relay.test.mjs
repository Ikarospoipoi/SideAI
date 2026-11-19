import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

let mf;
const sockets = [];
before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{ name: 'relay', modules: true, scriptPath: 'src/worker.mjs', compatibilityDate: '2026-11-01',
    durableObjects: { ROOMS: { className: 'RelayRoom', useSQLite: true } },
    ratelimits: { CONNECT_LIMIT: { namespace_id: '1001', simple: { limit: 30, period: 60 } } } }] }));
  await mf.ready;
});
after(async () => { for(const ws of sockets) { try { ws.close(); } catch {} } await mf?.dispose(); });
const sha = s => createHash('sha256').update(s).digest('hex');
function room() {
  const host = randomBytes(32).toString('base64'), phone = randomBytes(32).toString('base64');
  return { room: randomUUID(), host, phone, phoneHash: sha(phone) };
}
function headers(r, role, token = r[role]) {
  return { Upgrade: 'websocket', 'X-SideAI-Room': r.room, 'X-SideAI-Role': role,
    'X-SideAI-Token': token, 'X-SideAI-Phone-Hash': r.phoneHash };
}
function once(ws, kind, timeout = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.removeEventListener(kind, listener); reject(new Error(`Missing ${kind}`)); }, timeout);
    const listener = event => { clearTimeout(timer); ws.removeEventListener(kind, listener); resolve(event); };
    ws.addEventListener(kind, listener);
  });
}
async function connect(r, role) {
  const response = await mf.dispatchFetch('http://localhost/v1/connect', {headers: headers(r, role)});
  assert.equal(response.status, 101);
  const ws = response.webSocket; sockets.push(ws); ws.accept();
  const joined = once(ws, 'message');
  ws.send(JSON.stringify({join: true, room: r.room, role, token: r[role], phoneHash: r.phoneHash}));
  assert.deepEqual(JSON.parse((await joined).data), {joined: true});
  return ws;
}
const frame = (r, role, seq = 1) => JSON.stringify({v: 1, room: r.room, role, seq, session: randomUUID(), box: 'opaque-ciphertext'});

test('health, routes, upgrade and credentials are checked before accepting sockets', async () => {
  assert.equal((await mf.dispatchFetch('http://localhost/health')).status, 200);
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect')).status, 426);
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect?token=invalid', {headers:{Upgrade:'websocket'}})).status, 404);
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect', {headers:{Upgrade:'websocket'}})).status, 400);
  const r = room();
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect', {headers:headers(r, 'phone')})).status, 409);
  await connect(r, 'host');
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect', {headers:headers(r, 'phone', r.host)})).status, 403);
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect', {headers:headers(r, 'host', r.phone)})).status, 403);
});

test('forwards only between joined peers in the same room; replacement phone resumes', async () => {
  const r = room(), other = room(), host = await connect(r,'host'), outsider = await connect(other,'host');
  const peer = once(host,'message'), phone = await connect(r,'phone');
  assert.deepEqual(JSON.parse((await peer).data), {peer:true});
  // Drain the peer notification before asserting forwarded application messages.
  await new Promise(resolve => setTimeout(resolve, 30));
  const unrelated=[]; outsider.addEventListener('message', e=>unrelated.push(e.data));
  const message=frame(r,'host'), received=once(phone,'message'); host.send(message);
  assert.equal((await received).data,message);
  const reply=frame(r,'phone'), back=once(host,'message'); phone.send(reply);
  assert.equal((await back).data,reply);
  const closed=once(phone,'close'), replacement=await connect(r,'phone');
  await closed;
  await new Promise(resolve=>setTimeout(resolve,30));
  const resumed=once(replacement,'message'); host.send(message);
  assert.equal((await resumed).data,message);
  assert.deepEqual(unrelated,[]);
});

test('rejects role spoofing, malformed frames, oversized frames and floods', async () => {
  for(const invalid of [r=>frame(r,'phone'), ()=>'{bad', r=>JSON.stringify({v:1,room:r.room,role:'host',seq:0,session:randomUUID(),box:'x'}), ()=> 'x'.repeat(2_000_001)]) {
    const r=room(), host=await connect(r,'host'), closed=once(host,'close');
    host.send(invalid(r));
    assert.ok([1008,1009].includes((await closed).code));
  }
  const r=room(), host=await connect(r,'host'), closed=once(host,'close');
  for(let i=1;i<=101;i++) host.send(frame(r,'host',i));
  assert.equal((await closed).code,1008);
});

test('stored room ownership survives host disconnect and refuses another token', async () => {
  const r=room(), host=await connect(r,'host'); host.close();
  const thief={...r, host:randomBytes(32).toString('base64')};
  assert.equal((await mf.dispatchFetch('http://localhost/v1/connect',{headers:headers(thief,'host')})).status,403);
  await connect(r,'host');
});

test('edge limiter bounds connection attempts before creating room sockets', async () => {
  const r=room(), h={...headers(r,'phone'),'CF-Connecting-IP':'203.0.113.42'};
  const statuses=[];
  for(let i=0;i<35;i++) statuses.push((await mf.dispatchFetch('http://localhost/v1/connect',{headers:h})).status);
  assert.equal(statuses[0],409);
  assert.equal(statuses.at(-1),429);
});
