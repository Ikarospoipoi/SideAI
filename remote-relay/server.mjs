import http from 'node:http';
import {createHash,timingSafeEqual} from 'node:crypto';
import {WebSocketServer,WebSocket} from 'ws';
import {pathToFileURL} from 'node:url';
const digest=s=>createHash('sha256').update(s).digest('hex');
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.length===b.length&&timingSafeEqual(Buffer.from(a),Buffer.from(b));
export function createRelay({maxRooms=200}={}){
  const rooms=new Map(),ips=new Map();
  const server=http.createServer((req,res)=>{res.writeHead(req.url==='/health'?200:404,{'Content-Type':'text/plain','Cache-Control':'no-store'});res.end(req.url==='/health'?'SideAI relay healthy':'Not found');});
  const wss=new WebSocketServer({noServer:true,maxPayload:2_000_000,perMessageDeflate:false});
  server.on('upgrade',(req,socket,head)=>{
    const ip=req.socket.remoteAddress;
    if(req.url!=='/v1/connect'||(ips.get(ip)??0)>=16||wss.clients.size>=400){socket.destroy();return;}
    wss.handleUpgrade(req,socket,head,ws=>{ips.set(ip,(ips.get(ip)??0)+1);ws.once('close',()=>{const n=(ips.get(ip)??1)-1;if(n>0)ips.set(ip,n);else ips.delete(ip);});wss.emit('connection',ws);});
  });
  wss.on('connection',ws=>{
    let room,role,alive=true,count=0,start=Date.now();
    const timeout=setTimeout(()=>ws.close(1008,'Join required'),5000);
    ws.on('pong',()=>alive=true);
    ws.isAlive=()=>{if(!alive){ws.terminate();return;}alive=false;ws.ping();};
    ws.on('error',()=>{});
    ws.on('message',(data,isBinary)=>{
      if(isBinary)return ws.close(1003,'Text only');
      if(Date.now()-start>10000){count=0;start=Date.now();}if(++count>100)return ws.close(1008,'Rate limited');
      let m;try{m=JSON.parse(data.toString());}catch{return ws.close(1008,'Invalid message');}
      if(!m||typeof m!=='object'||Array.isArray(m))return ws.close(1008,'Invalid message');
      if(!room){
        if(typeof m.room!=='string'||!m.join||!/^[-a-f0-9]{36}$/.test(m.room)||!['host','phone'].includes(m.role)||typeof m.token!=='string'||!/^.{44}$/.test(m.token))return ws.close(1008,'Invalid join');
        room=rooms.get(m.room);role=m.role;
        if(!room){
          if(role!=='host'||rooms.size>=maxRooms||!/^[a-f0-9]{64}$/.test(m.phoneHash))return ws.close(1008,'Host unavailable');
          room={id:m.room,hostHash:digest(m.token),phoneHash:m.phoneHash,last:Date.now()};rooms.set(m.room,room);
        }
        if(!equal(digest(m.token),room[role+'Hash'])){room=undefined;return ws.close(1008,'Not authorized');}
        if(room[role]&&room[role]!==ws)room[role].close(1000,'Reconnected');
        room[role]=ws;room.last=Date.now();clearTimeout(timeout);ws.send(JSON.stringify({joined:true}));
        const peer=room[role==='host'?'phone':'host'];if(peer?.readyState===WebSocket.OPEN){peer.send('{"peer":true}');ws.send('{"peer":true}');}
        return;
      }
      if(room[role]!==ws)return ws.close(1008,'Replaced');
      if(m.v!==1||m.room!==room.id||m.role!==role||typeof m.box!=='string'||m.box.length>1_900_000||!Number.isSafeInteger(m.seq)||m.seq<1||!/^[-a-f0-9]{36}$/.test(m.session))return ws.close(1008,'Invalid frame');
      const peer=room[role==='host'?'phone':'host'];
      if(peer?.readyState===WebSocket.OPEN){if(peer.bufferedAmount>4_000_000)return peer.close(1013,'Slow receiver');peer.send(data.toString());}
    });
    ws.on('close',()=>{clearTimeout(timeout);if(room?.[role]===ws){room[role]=undefined;room.last=Date.now();}});
  });
  const timer=setInterval(()=>{for(const ws of wss.clients)ws.isAlive?.();for(const [id,r]of rooms)if(!r.host&&!r.phone&&Date.now()-r.last>600000)rooms.delete(id);},15000);timer.unref();
  return {server,rooms,close:async()=>{clearInterval(timer);for(const ws of wss.clients)ws.terminate();await new Promise(resolve=>wss.close(resolve));await new Promise(resolve=>server.close(resolve));}};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){const relay=createRelay();relay.server.listen(Number(process.env.PORT??8787),process.env.HOST??'0.0.0.0',()=>console.log('SideAI relay listening'));for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>relay.close().then(()=>process.exit(0)));}
