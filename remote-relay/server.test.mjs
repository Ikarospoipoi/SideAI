import {test} from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {randomUUID, randomBytes, createHash, createHmac, hkdfSync, createCipheriv, createDecipheriv} from 'node:crypto';
import {WebSocket} from 'ws';
import {createRelay} from './server.mjs';
const sha=s=>createHash('sha256').update(s).digest('hex');
const token=(secret,role)=>createHmac('sha256',secret).update('SideAI relay v1 '+role).digest('base64');
function reader(ws){const queue=[],waiting=[];ws.on('message',data=>{const v=JSON.parse(data.toString());const resolve=waiting.shift();if(resolve)resolve(v);else queue.push(v);});return ()=>queue.length?Promise.resolve(queue.shift()):new Promise(r=>waiting.push(r));}
async function fixture(t){const relay=createRelay();relay.server.listen(0,'127.0.0.1');await once(relay.server,'listening');t.after(()=>relay.close());const url=`ws://127.0.0.1:${relay.server.address().port}/v1/connect`;return {relay,url,connect:async()=>{const ws=new WebSocket(url);const read=reader(ws);await once(ws,'open');return {ws,read};}};}
test('role authentication, opaque encrypted forwarding and no offline queue', {timeout:10000},async t=>{
 const {connect}=await fixture(t),secret=randomBytes(32),room=randomUUID();
 const host=await connect();host.ws.send(JSON.stringify({join:true,room,role:'host',token:token(secret,'host'),phoneHash:sha(token(secret,'phone'))}));assert.equal((await host.read()).joined,true);
 const invalid=await connect();const closed=once(invalid.ws,'close');invalid.ws.send(JSON.stringify({join:true,room,role:'phone',token:token(secret,'host')}));assert.equal((await closed)[0],1008);
 const frame={v:1,room,role:'host',session:randomUUID(),seq:1,box:'opaque-before-phone'};host.ws.send(JSON.stringify(frame));
 const phone=await connect();phone.ws.send(JSON.stringify({join:true,room,role:'phone',token:token(secret,'phone')}));assert.equal((await phone.read()).joined,true);assert.equal((await phone.read()).peer,true);assert.equal((await host.read()).peer,true);
 const role='phone',session=randomUUID(),seq=1,key=hkdfSync('sha256',secret,Buffer.from(room),Buffer.from('SideAI remote v1 '+role),32),nonce=randomBytes(12);
 const aad=Buffer.from(`${room}|${role}|${session}|${seq}`),cipher=createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(aad);
 const payload=JSON.stringify({kind:'command',text:'fixture secret message'}),encrypted=Buffer.concat([cipher.update(payload),cipher.final()]);
 const sent={v:1,room,role,session,seq,box:Buffer.concat([nonce,encrypted,cipher.getAuthTag()]).toString('base64')};phone.ws.send(JSON.stringify(sent));assert.deepEqual(await host.read(),sent);assert.ok(!JSON.stringify(sent).includes('fixture secret'));
 const box=Buffer.from(sent.box,'base64'),decipher=createDecipheriv('aes-256-gcm',key,box.subarray(0,12));decipher.setAAD(aad);decipher.setAuthTag(box.subarray(-16));assert.equal(Buffer.concat([decipher.update(box.subarray(12,-16)),decipher.final()]).toString(),payload);
 host.ws.send(JSON.stringify({...frame,seq:2,box:'current'}));assert.equal((await phone.read()).box,'current');
 const badRole=once(phone.ws,'close');phone.ws.send(JSON.stringify({...sent,role:'host'}));assert.equal((await badRole)[0],1008);
});
test('phone cannot create a room; health contains no session data',{timeout:5000},async t=>{
 const {connect,url,relay}=await fixture(t);const p=await connect();const closed=once(p.ws,'close');p.ws.send(JSON.stringify({join:true,room:randomUUID(),role:'phone',token:randomBytes(32).toString('base64')}));assert.equal((await closed)[0],1008);assert.equal(relay.rooms.size,0);
 const r=await fetch(url.replace('ws:','http:').replace('/v1/connect','/health'));assert.equal(r.status,200);assert.equal(await r.text(),'SideAI relay healthy');
});
test('malformed JSON values cannot crash relay',{timeout:5000},async t=>{
 const {connect,url}=await fixture(t);
 for(const value of ['null','[]','true','42','"string"','{']){const p=await connect();const closed=once(p.ws,'close');p.ws.send(value);assert.equal((await closed)[0],1008);}
 assert.equal((await fetch(url.replace('ws:','http:').replace('/v1/connect','/health'))).status,200);
});
