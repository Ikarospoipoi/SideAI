import {parentPort} from 'node:worker_threads';
import {MemoryDocument,retrieve} from './memory';
const documents=new Map<string,MemoryDocument>();
parentPort!.on('message',m=>{try{for(const id of m.removed??[])documents.delete(id);for(const doc of m.changed??[])documents.set(doc.id,doc);const result=retrieve(m.query,m.current,[...documents.values()],m.notes);parentPort!.postMessage({id:m.id,result});}catch(e){parentPort!.postMessage({id:m.id,error:String(e)});}});
