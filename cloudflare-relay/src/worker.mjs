import { DurableObject } from 'cloudflare:workers';
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const tokenPattern = /^[A-Za-z0-9+/]{43}=$/;
const hex = /^[a-f0-9]{64}$/;
const hash = async value => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('');
const equal = (a, b) => { if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false; let diff = 0; for(let i=0;i<a.length;i++) diff |= a.charCodeAt(i)^b.charCodeAt(i); return diff === 0; };
const response = (text, status) => new Response(text, {status, headers:{'Cache-Control':'no-store','Content-Type':'text/plain'}});
function identity(request) {
  const room = request.headers.get('X-SideAI-Room'), role = request.headers.get('X-SideAI-Role'), token = request.headers.get('X-SideAI-Token'), phoneHash = request.headers.get('X-SideAI-Phone-Hash');
  return uuid.test(room??'') && ['host','phone'].includes(role) && tokenPattern.test(token??'') && hex.test(phoneHash??'') ? {room,role,token,phoneHash} : null;
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if(url.pathname === '/health' && request.method === 'GET') return response('SideAI relay healthy',200);
    if(url.pathname !== '/v1/connect' || url.search) return response('Not found',404);
    if(request.method !== 'GET' || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return response('WebSocket required',426);
    const id = identity(request);
    if(!id) return response('Update SideAI on both devices',400);
    if(env.CONNECT_LIMIT && !(await env.CONNECT_LIMIT.limit({key:request.headers.get('CF-Connecting-IP')??'local'})).success) return response('Try again later',429);
    return env.ROOMS.get(env.ROOMS.idFromName(id.room)).fetch(request);
  }
};
export class RelayRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx,env); this.ctx=ctx;
    ctx.blockConcurrencyWhile(async()=>{ this.auth=await ctx.storage.get('auth'); });
  }
  async fetch(request) {
    const id=identity(request);
    if(!id) return response('Invalid join',400);
    const digest=await hash(id.token);
    // Serialize auth creation and replacement across simultaneous upgrades.
    return this.ctx.blockConcurrencyWhile(async()=>{
      if(!this.auth) {
        if(id.role!=='host') return response('Host unavailable',409);
        this.auth={room:id.room,hostHash:digest,phoneHash:id.phoneHash};
        await this.ctx.storage.put('auth',this.auth);
      }
      if(id.room!==this.auth.room || !equal(digest,this.auth[id.role+'Hash']) || !equal(id.phoneHash,this.auth.phoneHash)) return response('Not authorized',403);
      const sockets=this.ctx.getWebSockets();
      for(const old of sockets) if(old.deserializeAttachment()?.role===id.role) old.close(1000,'Reconnected');
      const pair=new WebSocketPair(), client=pair[0], server=pair[1];
      this.ctx.acceptWebSocket(server,[id.role]);
      server.serializeAttachment({role:id.role,joined:false,count:0,bytes:0,start:Date.now(),connection:crypto.randomUUID()});
      // Authentication hashes only. No messages, plaintext or encryption keys are persisted.
      await this.ctx.storage.setAlarm(Date.now()+7*24*3600*1000);
      return new Response(null,{status:101,webSocket:client});
    });
  }
  async webSocketMessage(ws, data) {
    if(ws.readyState!==1) return;
    const state=ws.deserializeAttachment();
    if(!state || typeof data!=='string') return ws.close(1003,'Text only');
    const size=new TextEncoder().encode(data).length;
    if(size>2_000_000) return ws.close(1009,'Frame too large');
    if(Date.now()-state.start>=10_000){state.start=Date.now();state.count=0;state.bytes=0;}
    state.count++; state.bytes+=size;
    if(state.count>100 || state.bytes>12_000_000) return ws.close(1008,'Rate limited');
    let m;try{m=JSON.parse(data);}catch{return ws.close(1008,'Invalid JSON');}
    if(!m || Array.isArray(m) || typeof m!=='object') return ws.close(1008,'Invalid message');
    if(!state.joined) {
      if(m.join!==true || m.room!==this.auth.room || m.role!==state.role || !tokenPattern.test(m.token??'') || !equal(await hash(m.token),this.auth[state.role+'Hash'])) return ws.close(1008,'Invalid join');
      state.joined=true; ws.serializeAttachment(state); ws.send('{"joined":true}');
      for(const peer of this.ctx.getWebSockets(state.role==='host'?'phone':'host')) if(peer.readyState===1 && peer.deserializeAttachment()?.joined){peer.send('{"peer":true}');ws.send('{"peer":true}');}
      return;
    }
    ws.serializeAttachment(state);
    // Ignore sockets closed/replaced by a newer connection.
    if(ws.readyState!==1) return;
    if(m.v!==1 || m.room!==this.auth.room || m.role!==state.role || typeof m.box!=='string' || m.box.length>1_900_000 || !Number.isSafeInteger(m.seq) || m.seq<1 || !uuid.test(m.session??'')) return ws.close(1008,'Invalid frame');
    for(const peer of this.ctx.getWebSockets(state.role==='host'?'phone':'host')) if(peer.readyState===1 && peer.deserializeAttachment()?.joined) {
      try{peer.send(data);}catch{peer.close(1013,'Reconnect');}
    }
  }
  webSocketClose(ws){ws.close(1000,'Closed');}
  webSocketError(ws){ws.close(1011,'Reconnect');}
  async alarm(){
    if(this.ctx.getWebSockets().some(ws=>ws.readyState===1)) await this.ctx.storage.setAlarm(Date.now()+7*24*3600*1000);
    else {await this.ctx.storage.deleteAll();this.auth=undefined;}
  }
}
