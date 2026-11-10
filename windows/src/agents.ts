import {MemoryContext,augment,originalMessage} from './memory';
import {randomUUID} from 'node:crypto';
import {RPC} from './rpc';
import {Runtimes} from './runtime';
import {Approval,Connection,Conversation,Item,Model} from './types';
export interface AgentHooks {changed:()=>void;approval:(a:Approval,reply:(allow:boolean,answers:Record<string,string>)=>void)=>void;resolved:(id?:string)=>void;save:()=>void}
export async function codexConnect(runtime:Runtimes,c:Connection){
  const rpc=runtime.start(c,['app-server','--listen','stdio://','-c','features.apps=false','-c','features.multi_agent=false']);
  try{await rpc.request('initialize',{clientInfo:{name:'sideai',title:'SideAI',version:'0.9.0'},capabilities:{experimentalApi:false}});rpc.send({method:'initialized'});return rpc;}catch(e){rpc.stop();throw e;}
}
export async function codexModels(rpc:RPC):Promise<Model[]>{const models:Model[]=[];let cursor:string|undefined;const seen=new Set<string>();do{const r=await rpc.request('model/list',{limit:100,...(cursor?{cursor}:{})});models.push(...(r.data??[]).map((m:any)=>({id:m.model,name:m.displayName??m.model,efforts:m.supportedReasoningEfforts?.map((e:any)=>e.reasoningEffort)})));cursor=r.nextCursor;if(cursor&&seen.has(cursor))throw Error('模型分页重复');if(cursor)seen.add(cursor);}while(cursor);return models;}
export function timeline(raw:any):Item {
  const role=raw.type==='userMessage'?'user':raw.type==='agentMessage'?'assistant':raw.type==='reasoning'?'reasoning':'tool';
  const text=raw.text??(raw.type==='userMessage'?(raw.content??[]).filter((x:any)=>x.type==='text').map((x:any)=>x.text).join('\n'):raw.type==='commandExecution'?`${raw.command??''}\n${raw.aggregatedOutput??''}`:raw.type==='fileChange'?JSON.stringify(raw.changes,null,2):JSON.stringify(raw,null,2));
  return {id:raw.id??randomUUID(),role,text:(role==='user'?originalMessage(String(text)):String(text)).slice(-100000),status:raw.status==='inProgress'?'inProgress':'completed'};
}
export async function runCodex(runtime:Runtimes,connection:Connection,c:Conversation,hooks:AgentHooks,signal:AbortSignal,memory?:MemoryContext){
  const rpc=await codexConnect(runtime,connection),generation=randomUUID();let turnID='',interrupted=false;
  const stop=()=>{interrupted=true;if(turnID)void rpc.request('turn/interrupt',{threadId:c.threadID,turnId:turnID}).catch(()=>rpc.stop());else rpc.stop();};signal.addEventListener('abort',stop,{once:true});
  let resolve!:(v:void)=>void,reject!:(e:Error)=>void;const completed=new Promise<void>((r,j)=>{resolve=r;reject=j;});completed.catch(()=>{});
  const pending=new Map<string,{id:string;itemID?:string}>(),tombstones=new Set<string>();
  rpc.on('disconnect',reject);
  rpc.on('event',m=>{
    const p=m.params??{},method=m.method;
    if(m.id!==undefined){
      if(p.threadId!==c.threadID||!['item/commandExecution/requestApproval','item/fileChange/requestApproval','item/permissions/requestApproval','item/tool/requestUserInput'].includes(method)){rpc.reject(m.id);return;}
      const key=JSON.stringify(m.id);if(tombstones.has(key)||pending.has(key))return;
      const id=generation+':'+key;pending.set(key,{id,itemID:p.itemId});c.status='awaitingApproval';
      hooks.approval({id,conversationID:c.id,method,title:p.command??p.reason??(method.includes('fileChange')?'修改文件':method.includes('requestUserInput')?'需要你的回答':'请求权限'),detail:JSON.stringify(p,null,2),cwd:p.cwd??c.cwd,created:Date.now(),questions:p.questions},(allow,answers)=>{
        if(rpc.closed||tombstones.has(key))return;const result=method==='item/tool/requestUserInput'?{answers:Object.fromEntries(Object.entries(answers).map(([k,v])=>[k,{answers:[v]}]))}:method==='item/permissions/requestApproval'?{permissions:allow?p.permissions:{},scope:'turn'}:{decision:allow?'accept':'decline'};
        rpc.reply(m.id,result);tombstones.add(key);
      });return;
    }
    if(p.threadId!==c.threadID)return;
    const upsert=(item:Item)=>{const i=c.items.findIndex(x=>x.id===item.id);if(i>=0)c.items[i]=item;else c.items.push(item);};
    if(method==='turn/started'){turnID=p.turn.id;c.status='running';if(signal.aborted)stop();}
    if(method==='item/agentMessage/delta'||method==='item/commandExecution/outputDelta'||method==='item/reasoning/summaryTextDelta'){
      let item=c.items.find(i=>i.id===p.itemId);if(!item){item={id:p.itemId,role:method.includes('agentMessage')?'assistant':method.includes('reasoning')?'reasoning':'tool',text:'',status:'inProgress'};c.items.push(item);}if(item.status==='inProgress')item.text=(item.text+(p.delta??'')).slice(-100000);
    }
    if(method==='item/started'||method==='item/completed'){
      const item=timeline(p.item);if(p.item.type==='userMessage'){const local=c.items.findIndex(i=>i.id.startsWith('local:')&&i.text===item.text);if(local>=0){item.images=c.items[local].images;c.items.splice(local,1);}}
      if(method==='item/started'){item.status='inProgress';if(!c.items.some(x=>x.id===item.id))upsert(item);}else {upsert(item);for(const [key,a] of pending)if(a.itemID===item.id){hooks.resolved(a.id);pending.delete(key);tombstones.add(key);}}
    }
    if(method==='serverRequest/resolved'){const key=JSON.stringify(p.requestId),a=pending.get(key);if(a)hooks.resolved(a.id);pending.delete(key);tombstones.add(key);}
    if(!pending.size&&c.status==='awaitingApproval')c.status='running';
    if(method==='turn/plan/updated')upsert({id:'plan:'+p.turnId,role:'tool',text:[p.explanation,...(p.plan??[]).map((x:any)=>`${x.status} · ${x.step}`)].filter(Boolean).join('\n'),status:'completed'});
    if(method==='turn/diff/updated')upsert({id:'diff:'+p.turnId,role:'tool',text:p.diff,status:'completed'});
    if(method==='turn/completed'){if(turnID&&p.turn.id!==turnID)return;c.status=p.turn.status==='completed'?'completed':'interrupted';p.turn.status==='failed'?reject(Error(p.turn.error?.message??'任务失败')):resolve();}
    if(method==='error'&&!p.willRetry)reject(Error(p.error?.message??'后端错误'));hooks.changed();
  });
  try{
    const params={cwd:c.cwd,sandbox:c.mode==='project'?'workspace-write':'read-only',approvalPolicy:'on-request',approvalsReviewer:'user',config:{'features.apps':false,'features.multi_agent':false},...(c.model?{model:c.model}:{}),...(c.threadID?{threadId:c.threadID}:{})};
    const r=await rpc.request(c.threadID?'thread/resume':'thread/start',params);c.threadID=r.thread.id;hooks.save();
    if(signal.aborted)throw Error('已停止');const user=c.items.filter(i=>i.role==='user').at(-1)!;
    const sandboxPolicy=c.mode==='project'?{type:'workspaceWrite',writableRoots:[c.cwd],networkAccess:false,excludeSlashTmp:true,excludeTmpdirEnvVar:true}:{type:'readOnly',networkAccess:false};
    await rpc.request('turn/start',{threadId:c.threadID,input:[...(augment(user.text,memory)?[{type:'text',text:augment(user.text,memory)}]:[]),...(user.images??[]).map(a=>({type:'localImage',path:a.path}))],cwd:c.cwd,approvalPolicy:'on-request',approvalsReviewer:'user',sandboxPolicy,...(c.model?{model:c.model}:{}),...(c.effort?{effort:c.effort}:{})});await completed;
  }finally{signal.removeEventListener('abort',stop);rpc.stop();for(const a of pending.values())hooks.resolved(a.id);if(interrupted)c.status='interrupted';}
}
export async function runClaude(runtime:Runtimes,connection:Connection,c:Conversation,hooks:AgentHooks,signal:AbortSignal,memory?:MemoryContext){
  const tools=c.mode==='project'?['Read','Glob','Grep','Edit','Write']:['Read','Glob','Grep'];c.sessionID??=randomUUID();hooks.save();
  const args=['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--include-partial-messages','--safe-mode','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools',tools.join(','),'--permission-mode','manual','--disable-slash-commands','--restricted','--permission-prompt-tool','stdio',c.hasSession?'--resume':'--session-id',c.sessionID,...(c.model?['--model',c.model]:[]),...(c.effort?['--effort',c.effort]:[])];
  const rpc=runtime.start(connection,args,c.cwd),generation=randomUUID(),answer:Item={id:randomUUID(),role:'assistant',text:'',status:'inProgress'};c.items.push(answer);const requests=new Set<string>();
  const cancel=()=>rpc.stop(Error('已停止'));signal.addEventListener('abort',cancel,{once:true});
  try{await new Promise<void>((resolve,reject)=>{
    rpc.on('disconnect',reject);rpc.on('event',m=>{try{
      if(m.type==='control_response'&&m.response?.request_id==='initialize'){
        if(m.response.subtype!=='success')throw Error('Claude 初始化失败');const user=c.items.filter(i=>i.role==='user').at(-1)!;rpc.send({type:'user',message:{role:'user',content:[...(augment(user.text,memory)?[{type:'text',text:augment(user.text,memory)}]:[]),...(user.images??[]).map(a=>({type:'image',source:{type:'base64',media_type:'image/png',data:a.dataURL.split(',')[1]}}))]}});
      }
      if(m.type==='system'&&m.subtype==='init'){if((m.tools??[]).some((t:string)=>!tools.includes(t))||(m.mcp_servers??[]).length)throw Error('官方客户端启用了未授权工具，已停止。');c.hasSession=true;hooks.save();}
      if(m.type==='control_request'){
        const request=m.request,key=m.request_id,id=generation+':'+key;
        const reply=(allow:boolean)=>rpc.send({type:'control_response',response:{subtype:'success',request_id:key,response:allow?{behavior:'allow',updatedInput:request.input}:{behavior:'deny',message:'SideAI 未批准此操作。'}}});
        if(request.subtype!=='can_use_tool'||!tools.includes(request.tool_name)){reply(false);return;}if(requests.has(id))return;requests.add(id);c.status='awaitingApproval';hooks.approval({id,conversationID:c.id,method:'claude',title:request.tool_name,detail:JSON.stringify(request.input,null,2),cwd:c.cwd,created:Date.now()},allow=>{if(!rpc.closed){reply(allow);hooks.resolved(id);c.status='running';}});
      }
      if(m.type==='stream_event'&&m.event?.delta?.type==='text_delta')answer.text+=m.event.delta.text;
      if(m.type==='assistant'){const text=(m.message?.content??[]).filter((b:any)=>b.type==='text').map((b:any)=>b.text).join('');if(text)answer.text=text;for(const t of m.message?.content??[])if(t.type==='tool_use')c.items.push({id:t.id,role:'tool',text:t.name+'\n'+JSON.stringify(t.input,null,2),status:'completed'});}
      if(m.type==='result'){if(m.is_error||m.subtype!=='success')throw Error(m.result??'Claude 任务失败');if(m.result)answer.text=m.result;answer.status='completed';c.status='completed';resolve();}hooks.changed();
    }catch(e){reject(e);}});rpc.send({type:'control_request',request_id:'initialize',request:{subtype:'initialize',hooks:null}});if(signal.aborted)cancel();
  });}finally{signal.removeEventListener('abort',cancel);rpc.stop();for(const id of requests)hooks.resolved(id);if(answer.status==='inProgress')answer.status='interrupted';}
}
