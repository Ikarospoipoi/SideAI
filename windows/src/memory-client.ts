import {Worker} from 'node:worker_threads';
import path from 'node:path';
import {Conversation} from './types';
import {MemoryContext,MemoryDocument} from './memory';
/** A lazy worker keeps large imported archives off the window/Win32 event loop. */
export class MemoryClient {
  private worker?:Worker;private keys=new Map<string,string>();private next=0;
  private pending=new Map<number,{resolve:(m:MemoryContext)=>void;reject:(e:Error)=>void;timer:NodeJS.Timeout}>();
  query(current:Conversation,conversations:Conversation[],notes:string):Promise<MemoryContext>{
    if(!this.worker){const w=this.worker=new Worker(path.join(__dirname,'memory-worker.js'));w.unref();w.on('message',m=>{const p=this.pending.get(m.id);if(!p)return;clearTimeout(p.timer);this.pending.delete(m.id);m.error?p.reject(Error(m.error)):p.resolve(m.result);if(!this.pending.size)w.unref();});w.on('error',e=>this.close(e));w.on('exit',()=>{if(this.worker===w)this.close(Error('本地记忆检索已停止'));});}
    const changed:MemoryDocument[]=[],valid=new Set<string>();
    for(const c of conversations){if(c.memoryExcluded)continue;valid.add(c.id);const items=c.items.filter(i=>['user','assistant'].includes(i.role)&&(!i.status||i.status==='completed')&&i.text);
      const key=JSON.stringify([c.title,c.updated,c.cwd,c.mode,items.map(i=>[i.id,i.text.length,i.status])]);if(this.keys.get(c.id)===key)continue;this.keys.set(c.id,key);changed.push({id:c.id,title:c.title,updated:c.updated,cwd:c.cwd,mode:c.mode,items:items.map(i=>({role:i.role,text:i.text}))});}
    const removed=[...this.keys.keys()].filter(id=>!valid.has(id));for(const id of removed)this.keys.delete(id);
    const worker=this.worker,id=++this.next;worker.ref();return new Promise((resolve,reject)=>{const timer=setTimeout(()=>this.close(Error('本地历史检索超时，请重试')),60000);this.pending.set(id,{resolve,reject,timer});worker.postMessage({id,changed,removed,query:current.draft,current:{id:current.id,cwd:current.cwd,mode:current.mode},notes});});
  }
  close(error=Error('记忆检索已取消')){const w=this.worker;this.worker=undefined;this.keys.clear();for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(error);}this.pending.clear();void w?.terminate();}
}
