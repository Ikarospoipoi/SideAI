import {EventEmitter} from 'node:events';
import {randomUUID} from 'node:crypto';
import fs from 'node:fs';
import {Storage,Vault} from './storage';
import {Approval,Attachment,Connection,Conversation,Engine,ViewState,connectionGroup,endpoint,providers,safeError} from './types';
import {Fetch,chat,jsonRequest} from './http';
import {Runtimes,startACP,acpModels,acpPrompt,runtimeInfo} from './runtime';
import {Tokens,signInGPT,refreshGPT,signInRouter} from './auth';
import {codexConnect,codexModels,runCodex,runClaude,timeline,AgentHooks} from './agents';
export class Service extends EventEmitter {
  busy?:string;notice='';hotkeyError='';login?:AbortController;run?:AbortController;
  approvals:Approval[]=[];private replies=new Map<string,(allow:boolean,answers:Record<string,string>)=>void>();private timer?:NodeJS.Timeout;
  runtime:Runtimes;
  constructor(public storage:Storage,private vault:Vault,private fetcher:Fetch,private open:(s:string)=>Promise<void>){super();this.runtime=new Runtimes(storage,s=>this.message(s),open,fetcher);}
  get state(){return this.storage.state;}
  view():ViewState{return {...this.state,approvals:this.approvals,busy:this.busy,notice:this.notice,loginBusy:!!this.login,hotkeyError:this.hotkeyError,platform:process.platform};}
  changed(){this.storage.saveSoon();if(!this.timer)this.timer=setTimeout(()=>{this.timer=undefined;this.emit('change',this.view());},50);}
  message(s:string){this.notice=s;this.changed();}
  conversation(id=this.state.selected){const c=this.state.conversations.find(c=>c.id===id);if(!c)throw Error('会话不存在');return c;}
  connection(id:string){const c=this.state.connections.find(c=>c.id===id);if(!c)throw Error('连接已删除，请重新添加。');return c;}
  idle(){if(this.busy||this.login)throw Error('请先停止当前任务或完成登录。');}
  newConversation(connectionID:string){const connection=this.connection(connectionID);const c:Conversation={id:randomUUID(),connectionID,title:'新会话',draft:'',images:[],items:[],cwd:this.storage.directory('Scratch'),mode:'readOnly',model:connection.model??connection.models[0]?.id??'',effort:'',status:'idle',updated:Date.now()};this.state.conversations.unshift(c);this.state.selected=c.id;this.state.workspace=connection.workspace;this.changed();return c;}
  select(id:string){const c=this.conversation(id);this.state.selected=id;const connection=this.state.connections.find(x=>x.id===c.connectionID);if(connection)this.state.workspace=connection.workspace;this.changed();}
  selectConnection(id:string){const c=this.state.conversations.filter(c=>c.connectionID===id&&!c.archived).sort((a,b)=>b.updated-a.updated)[0];if(c)this.select(c.id);else this.newConversation(id);}
  patch(id:string,patch:any){const c=this.conversation(id);if(patch.draft!==undefined){if(typeof patch.draft!=='string'||patch.draft.length>1000000)throw Error('输入过长');c.draft=patch.draft;}if(patch.images!==undefined){if(!Array.isArray(patch.images)||patch.images.length>8)throw Error('每条最多 8 张图片');const known=new Map([...c.images,...c.items.flatMap(i=>i.images??[])].map(a=>[a.id,a]));c.images=patch.images.map((id:string)=>{const image=known.get(id);if(!image)throw Error('图片不存在');return image;});}
    if(this.busy!==id){for(const key of ['title','model','effort'] as const)if(typeof patch[key]==='string')c[key]=patch[key].slice(0,key==='title'?100:200);if(['readOnly','project'].includes(patch.mode))c.mode=patch.mode;if(typeof patch.archived==='boolean')c.archived=patch.archived;}this.changed();}
  addImages(images:Attachment[]){const c=this.conversation();if(c.images.length+images.length>8)throw Error('每条最多 8 张图片');c.images.push(...images);this.changed();}
  checkDuplicate(c:Connection){if(this.state.connections.some(x=>x.id!==c.id&&connectionGroup(x)===connectionGroup(c)))throw Error('这个 AI 已有连接，请在“管理连接”编辑或删除原连接。聊天与 Agent 可以分别连接。');}
  saveAPI(raw:any){this.idle();const old=raw.id?this.connection(raw.id):undefined;
    if(old&&old.engine!=='api')throw Error('官方账号请使用重新登录。');
    const provider=providers[raw.provider]?raw.provider:'custom',url=endpoint(String(raw.endpoint??'')),format=['responses','chatCompletions','anthropic'].includes(raw.format)?raw.format:'chatCompletions';
    const officialProvider=Object.entries(providers).find(([,p])=>p.endpoint&&new URL(p.endpoint).hostname===new URL(url).hostname)?.[0]??provider;
    const c:Connection={id:old?.id??randomUUID(),name:String(raw.name||providers[officialProvider].name).slice(0,100),provider:officialProvider,engine:'api',workspace:'chat',endpoint:url,format,model:String(raw.model??'').slice(0,200),models:old?.models??[]};
    if(old&&(old.endpoint!==url||old.format!==format||old.provider!==c.provider))throw Error('已有连接的目标地址不能更改。请删除后新建，旧会话仍保留。');this.checkDuplicate(c);
    if(typeof raw.key==='string'&&raw.key.trim())this.vault.put(c.id,raw.key.trim());else if(!old)throw Error('请输入 API Key');
    if(old)this.state.connections[this.state.connections.indexOf(old)]=c;else this.state.connections.push(c);this.storage.save();this.selectConnection(c.id);return c;
  }
  async removeConnection(id:string){this.idle();const connection=this.connection(id);this.storage.backup();
    if(runtimeInfo[connection.engine]){
      const home=this.storage.directory('Accounts',connection.engine);
      if(connection.engine==='gemini'&&this.runtime.find(connection.engine,connection.executable)){const {rpc}=await startACP(this.runtime,connection);try{await rpc.request('logout',{});}finally{await rpc.dispose();}}
      if(connection.engine==='claude'&&this.runtime.find(connection.engine,connection.executable)){const cmd=this.runtime.find(connection.engine,connection.executable)!;await this.runtime.runProcess(cmd.exe,[...cmd.prefix,'auth','logout'],this.runtime.prepare(connection.engine),this.runtime.env(connection.engine,cmd.node),AbortSignal.timeout(30000),()=>{});}
      fs.rmSync(home,{recursive:true,force:true});
    }
    this.vault.delete(id);this.state.connections=this.state.connections.filter(c=>c.id!==id);for(const c of this.state.conversations)if(c.connectionID===id)c.readOnly=true;this.state.selected=undefined;this.message('连接已删除。历史保留为只读档案。');}
  async reset(){this.idle();const backup=this.storage.backup();for(const c of [...this.state.connections])await this.removeConnection(c.id);this.state.conversations=[];this.state.selected=undefined;this.state.workspace='chat';this.storage.save();this.message('已解除所有连接。历史备份：'+backup);}
  async loginConnection(engine:Engine,options:any={}){
    this.idle();const existing=options.id?this.connection(options.id):undefined;
    const provider=engine==='codex'||engine==='chatgpt'?'openai':engine==='claude'?'anthropic':engine;
    if(!providers[provider]||engine==='api')throw Error('登录类型无效');
    const preset=providers[provider],c:Connection=existing??{id:randomUUID(),provider,name:engine==='codex'?'Codex':engine==='claude'?'Claude Code':preset.name,engine,workspace:engine==='codex'||engine==='claude'?'agent':'chat',endpoint:preset.endpoint,format:preset.format,models:[]};
    if(existing&&existing.engine!==engine)throw Error('连接类型不匹配');this.checkDuplicate(c);if(options.executable)c.executable=options.executable;
    const ctrl=new AbortController();this.login=ctrl;this.message('等待官方账号授权…');
    try{
      if(engine==='chatgpt')this.vault.put(c.id,JSON.stringify(await signInGPT(this.fetcher,this.open,this.state.settings.hostID,ctrl.signal)));
      else if(engine==='openrouter')this.vault.put(c.id,await signInRouter(this.fetcher,this.open,ctrl.signal));
      else{
        await this.runtime.ensure(engine,c.executable,ctrl.signal);
        if(engine==='codex'){
          const rpc=await codexConnect(this.runtime,c);const cancel=()=>rpc.stop();ctrl.signal.addEventListener('abort',cancel,{once:true});try{
            const login=await rpc.request('account/login/start',{type:options.device?'chatgptDeviceCode':'chatgpt'});const url=login.authUrl??login.verificationUrl;
            if(!url||new URL(url).protocol!=='https:'||!['auth.openai.com','openai.com','chatgpt.com'].includes(new URL(url).hostname))throw Error('官方登录地址无效');if(login.userCode)this.message('请在官方页面输入验证码：'+login.userCode);await this.open(url);
            const until=Date.now()+300000;let ready=false;while(Date.now()<until&&!ctrl.signal.aborted){const status=await rpc.request('account/read',{refreshToken:false});if(status.account){ready=true;break;}await new Promise(r=>setTimeout(r,1500));}if(!ready)throw Error('登录已取消或超时');c.models=await codexModels(rpc);
          }finally{ctrl.signal.removeEventListener('abort',cancel);rpc.stop();}
        }else if(engine==='claude'){
          await this.runtime.loginCLI(c,ctrl.signal,!!options.console);let status='';const cmd=this.runtime.find(engine,c.executable)!;
          await this.runtime.runProcess(cmd.exe,[...cmd.prefix,'auth','status'],this.runtime.prepare(engine),this.runtime.env(engine,cmd.node),ctrl.signal,s=>status+=s);if(!JSON.parse(status).loggedIn)throw Error('尚未登录 Claude Code');c.models=['sonnet','opus','haiku','fable'].map(id=>({id,name:id,efforts:['low','medium','high','xhigh','max']}));
        }else{
          if(engine!=='gemini')await this.runtime.loginCLI(c,ctrl.signal);
          const {rpc,info}=await startACP(this.runtime,c);const cancel=()=>rpc.stop();ctrl.signal.addEventListener('abort',cancel,{once:true});try{
            const method=engine==='gemini'&&options.business?'oauth-business':runtimeInfo[engine].auth;
            if(!info.authMethods?.some((m:any)=>m.id===method))throw Error('官方客户端没有提供预期的登录方式，请检查版本。');
            if(engine!=='kimi')await rpc.request('authenticate',{methodId:method},300000);
            const session=await rpc.request('session/new',{cwd:this.runtime.prepare(engine),mcpServers:[]});c.models=acpModels(session);if(!c.models.length)c.models=acpModels({models:info._meta?.modelState});
          }finally{ctrl.signal.removeEventListener('abort',cancel);rpc.stop();}
        }
      }
      if(ctrl.signal.aborted)throw Error('登录已取消');if(!existing)this.state.connections.push(c);this.storage.save();this.selectConnection(c.id);this.message('已连接，可以开始聊天。');
    }catch(e){if(!existing)this.vault.delete(c.id);throw e;}finally{this.login=undefined;this.changed();}
  }
  async credential(c:Connection){let key=this.vault.get(c.id);if(c.engine!=='chatgpt')return key;let tokens:Tokens=JSON.parse(key);if(c.endpoint!=='https://api.openai.com/v1'||c.format!=='responses')throw Error('账号与目标地址不匹配');if(tokens.expiresAt<Date.now()+60000){tokens=await refreshGPT(this.fetcher,tokens);this.vault.put(c.id,JSON.stringify(tokens));}return tokens.access_token;}
  async models(id:string){this.idle();const c=this.connection(id);
    if(c.engine==='codex'){const rpc=await codexConnect(this.runtime,c);try{c.models=await codexModels(rpc);}finally{rpc.stop();}}
    else if(['kimi','grok','gemini'].includes(c.engine)){const {rpc,info}=await startACP(this.runtime,c);try{if(c.engine==='grok')await rpc.request('authenticate',{methodId:'grok.com',_meta:{headless:true}});const s=await rpc.request('session/new',{cwd:this.runtime.prepare(c.engine),mcpServers:[]});c.models=acpModels(s);if(!c.models.length)c.models=acpModels({models:info._meta?.modelState});}finally{rpc.stop();}}
    else if(c.engine!=='claude'){const key=await this.credential(c),headers:Record<string,string>=c.format==='anthropic'?{'x-api-key':key,'anthropic-version':'2023-06-01'}:{Authorization:`Bearer ${key}`};const r=await jsonRequest(this.fetcher,endpoint(c.endpoint!)+'/models',{headers});c.models=(r.data??r.models??[]).map((m:any)=>({id:m.id??m.name,name:m.display_name??m.id??m.name}));}
    const selected=this.state.conversations.find(x=>x.id===this.state.selected);if(selected?.connectionID===id&&!selected.model)selected.model=c.models[0]?.id??'';this.message('模型列表已更新。');return c.models;
  }
  async send(id:string){this.idle();const c=this.conversation(id),connection=this.connection(c.connectionID);if(c.readOnly)throw Error('此会话为只读档案，请创建续聊副本。');if(!c.draft.trim()&&!c.images.length)return;
    if(['api','chatgpt','openrouter'].includes(connection.engine)&&!c.model)throw Error('请先选择或填写模型。');
    const user={id:'local:'+randomUUID(),role:'user' as const,text:c.draft,images:c.images,status:'completed'};c.items.push(user);c.draft='';c.images=[];if(c.title==='新会话')c.title=user.text.slice(0,24)||'图片会话';c.status='running';c.updated=Date.now();this.busy=id;this.run=new AbortController();this.notice='';this.storage.save();this.changed();
    const signal=this.run.signal;
    const hooks:AgentHooks={changed:()=>this.changed(),save:()=>this.storage.save(),approval:(a,reply)=>{this.approvals.push(a);this.replies.set(a.id,reply);this.changed();this.emit('attention');},resolved:id=>{this.approvals=this.approvals.filter(a=>a.id!==id);if(id)this.replies.delete(id);this.changed();}};
    try{
      if(connection.engine==='codex')await runCodex(this.runtime,connection,c,hooks,signal);
      else if(connection.engine==='claude')await runClaude(this.runtime,connection,c,hooks,signal);
      else{
        const answer={id:randomUUID(),role:'assistant' as const,text:'',status:'inProgress'};c.items.push(answer);
        try{if(['kimi','grok','gemini'].includes(connection.engine)){
          const {rpc,info}=await startACP(this.runtime,connection);const cancel=()=>rpc.stop();signal.addEventListener('abort',cancel,{once:true});
          try{
            if(c.items.some(i=>i.images?.length)&&!info.agentCapabilities?.promptCapabilities?.image)throw Error('此官方客户端不支持图片，请使用 API 连接。');
            if(connection.engine==='grok')await rpc.request('authenticate',{methodId:'grok.com',_meta:{headless:true}});
            const session=await rpc.request('session/new',{cwd:this.runtime.prepare(connection.engine),mcpServers:[]});
            if(c.model){const config=session.configOptions?.find((m:any)=>m.category==='model'||m.id==='model');await rpc.request(config?'session/set_config_option':'session/set_model',config?{sessionId:session.sessionId,configId:config.id,value:c.model}:{sessionId:session.sessionId,modelId:c.model});}
            rpc.on('event',m=>{const u=m.params?.update;if(m.method==='session/update'){if(['tool_call','tool_call_update'].includes(u?.sessionUpdate)){rpc.stop(Error('聊天模式检测到工具调用，已停止。'));return;}if(u?.sessionUpdate==='agent_message_chunk'&&u.content?.type==='text'){answer.text+=u.content.text;this.changed();}}});
            if(signal.aborted)throw Error('已停止');const result=await rpc.request('session/prompt',{sessionId:session.sessionId,prompt:acpPrompt(c)},300000);if(result.stopReason!=='end_turn')throw Error('回复未完整结束');
          }finally{signal.removeEventListener('abort',cancel);rpc.stop();}
        }else{const key=await this.credential(connection);await chat(this.fetcher,connection,c,key,signal,t=>{answer.text=t;this.changed();});}answer.status='completed';c.status='completed';}finally{if(answer.status==='inProgress')answer.status='interrupted';}
      }
      this.emit('completed');
    }catch(e){c.status=signal.aborted?'interrupted':'failed';this.notice=signal.aborted?'已停止。':safeError(e);}finally{this.approvals=this.approvals.filter(a=>a.conversationID!==id);this.replies.clear();this.busy=undefined;this.run=undefined;this.storage.save();this.changed();}
  }
  respond(id:string,allow:boolean,answers:Record<string,string>={}){const a=this.approvals.find(a=>a.id===id);if(!a||a.submitted||!this.replies.has(id))throw Error('此审批已失效');a.submitted=true;this.replies.get(id)!(allow,answers);this.changed();}
  async sync(id:string){this.idle();const connection=this.connection(id);if(connection.engine!=='codex')throw Error('该连接保存在本地；ChatGPT 网页历史可通过导出 JSON 导入。');const rpc=await codexConnect(this.runtime,connection);try{for(const archived of [false,true]){let cursor:string|undefined;const seen=new Set<string>();do{const r=await rpc.request('thread/list',{limit:100,archived,modelProviders:[],sourceKinds:['cli','vscode','exec','appServer','subAgent','subAgentReview','subAgentCompact','subAgentThreadSpawn','subAgentOther','unknown'],...(cursor?{cursor}:{})});for(const t of r.data??[]){let c=this.state.conversations.find(c=>c.connectionID===id&&c.threadID===t.id);if(!c){c=this.newConversation(id);c.threadID=t.id;c.title=t.name??t.preview?.slice(0,50)??'Codex 会话';c.cwd=t.cwd??c.cwd;c.archived=archived;}}cursor=r.nextCursor;if(cursor&&seen.has(cursor))throw Error('会话分页重复');if(cursor)seen.add(cursor);}while(cursor);}this.message('Codex 会话索引已同步。选择会话后可载入历史。');}finally{rpc.stop();}}
  async history(id:string){const c=this.conversation(id),connection=this.connection(c.connectionID);if(connection.engine!=='codex'||!c.threadID||this.busy===id)return;const rpc=await codexConnect(this.runtime,connection);try{const r=await rpc.request('thread/read',{threadId:c.threadID,includeTurns:false});let turns:any[]=[];if(!turns.length){let cursor:string|undefined;const seen=new Set<string>();do{const page=await rpc.request('thread/turns/list',{threadId:c.threadID,limit:100,itemsView:'full',sortDirection:'asc',...(cursor?{cursor}:{})});turns.push(...(page.data??[]));cursor=page.nextCursor;if(cursor&&seen.has(cursor))throw Error('历史分页重复');if(cursor)seen.add(cursor);}while(cursor);}c.items=turns.flatMap((t:any)=>(t.items??[]).map(timeline));this.changed();}finally{rpc.stop();}}
  handoff(sourceID:string,targetID:string){const source=this.conversation(sourceID),target=this.newConversation(targetID);target.handoffFrom=sourceID;target.draft='请继续处理以下上下文：\n\n'+source.items.filter(i=>['user','assistant'].includes(i.role)).map(i=>`${i.role}: ${i.text}`).join('\n\n')+'\n'+source.draft;target.images=[...source.images].slice(0,8);this.message('上下文已复制到新草稿，点击发送后才会提交。');}
  returnResult(id:string){const c=this.conversation(id);if(!c.handoffFrom)throw Error('此任务没有来源会话');const source=this.conversation(c.handoffFrom);source.draft+='\n'+(c.items.filter(i=>i.role==='assistant').at(-1)?.text??'');this.select(source.id);}
  importChatGPT(file:string){this.idle();const input=JSON.parse(fs.readFileSync(file,'utf8'));if(!Array.isArray(input))throw Error('请选择官方导出的 conversations.json');let count=0;for(const row of input){const id='chatgpt-import:'+row.id;if(this.state.conversations.some(c=>c.id===id))continue;let node=row.current_node;const items:Conversation['items']=[],seen=new Set<string>();while(node&&row.mapping?.[node]&&!seen.has(node)){seen.add(node);const entry=row.mapping[node],m=entry.message;if(['user','assistant'].includes(m?.author?.role)){const text=(m.content?.parts??[]).filter((x:any)=>typeof x==='string').join('\n');if(text)items.unshift({id:m.id??node,role:m.author.role,text,status:'completed'});}node=entry.parent;}this.state.conversations.push({id,connectionID:'import',title:row.title??'ChatGPT 导入',draft:'',images:[],items,cwd:this.storage.directory('Scratch'),mode:'readOnly',model:'',effort:'',status:'completed',updated:(row.update_time??0)*1000,readOnly:true});count++;}this.message(`已导入 ${count} 个只读会话。`);}
  stop(){this.run?.abort();}
  cancelLogin(){this.login?.abort();}
  shutdown(){this.cancelLogin();this.stop();this.storage.save();}
}
