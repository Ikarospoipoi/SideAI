import {spawn, ChildProcessWithoutNullStreams} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {StringDecoder} from 'node:string_decoder';
export class Lines {
  private decoder = new StringDecoder('utf8'); private text='';
  push(chunk:Buffer) {this.text+=this.decoder.write(chunk);if(this.text.length>32*1024*1024) throw Error('协议帧过大');const rows=this.text.split('\n');this.text=rows.pop()!;return rows.filter(x=>x.trim()).map(x=>JSON.parse(x));}
}
export class RPC extends EventEmitter {
  child:ChildProcessWithoutNullStreams; private pending=new Map<string,{resolve:(x:any)=>void;reject:(e:Error)=>void;timer:NodeJS.Timeout}>();private next=0;closed=false;
  constructor(executable:string,args:string[],cwd:string,env:NodeJS.ProcessEnv) {
    super();this.child=spawn(executable,args,{cwd,env,stdio:'pipe',windowsHide:true,shell:false});
    const lines=new Lines();this.child.stdout.on('data',b=>{try{for(const msg of lines.push(b)){if(msg.method || msg.type){this.emit('event',msg);continue;}const k=JSON.stringify(msg.id),p=this.pending.get(k);if(p){clearTimeout(p.timer);this.pending.delete(k);msg.error?p.reject(Error(msg.error.message??'协议错误')):p.resolve(msg.result);}}}catch(e){this.stop(e as Error);}});
    this.child.stderr.on('data',b=>this.emit('diagnostic',b.toString()));
    this.child.on('error',e=>this.stop(e));this.child.on('exit',()=>this.stop(Error('官方客户端已退出。请重新连接；未自动重发任务。')));
    this.child.stdin.on('error',e=>this.stop(e));
  }
  send(message:any) {if(this.closed) throw Error('连接已关闭');this.child.stdin.write(JSON.stringify(message)+'\n');}
  request(method:string,params:any={},timeout=60000):Promise<any> {
    if(this.closed) return Promise.reject(Error('连接已关闭'));const id=++this.next;
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>this.stop(Error(`${method} 超时，状态未知。请检查历史，勿重复提交。`)),timeout);this.pending.set(JSON.stringify(id),{resolve,reject,timer});this.send({jsonrpc:'2.0',id,method,params});});
  }
  reply(id:any,result:any) {this.send({jsonrpc:'2.0',id,result});}
  reject(id:any) {this.send({jsonrpc:'2.0',id,error:{code:-32601,message:'Unsupported request; no permission granted'}});}
  stop(error=Error('连接已关闭')) {if(this.closed)return;this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(error);}this.pending.clear();this.child.stdin.end();this.child.kill();this.emit('disconnect',error);}
}
