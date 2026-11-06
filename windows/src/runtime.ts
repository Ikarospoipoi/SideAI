import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
import {RPC} from './rpc';
import {Engine,Connection,Model,Conversation} from './types';
import {Storage} from './storage';
import {Fetch,jsonRequest} from './http';
import {ProcessTree} from './process-tree';
export const runtimeInfo:Record<string,{exe:string;env:string;pkg?:string;bin?:string;auth?:string;hosts:string[]}>={
  codex:{exe:'codex',env:'CODEX_HOME',pkg:'@openai/codex',bin:'bin/codex.js',hosts:['auth.openai.com']},
  claude:{exe:'claude',env:'CLAUDE_CONFIG_DIR',pkg:'@anthropic-ai/claude-code',bin:'cli.js',hosts:['claude.ai','platform.claude.com','console.anthropic.com']},
  kimi:{exe:'kimi',env:'KIMI_CODE_HOME',pkg:'@moonshot-ai/kimi-code@2.5.1',auth:'login',hosts:['auth.kimi.com','auth.kimi.ai','www.kimi.com','www.kimi.ai','kimi.com','kimi.ai']},
  grok:{exe:'grok',env:'GROK_HOME',pkg:'@xai-official/grok@1.0.77',auth:'grok.com',hosts:['auth.x.ai','accounts.x.ai','grok.com']},
  gemini:{exe:'agy',env:'ANTIGRAVITY_GEMINI_DIR',auth:'oauth-personal',hosts:['accounts.google.com','antigravity.google','antigravity.google.com']}
};
export class Runtimes {
  constructor(private storage:Storage,private notice:(s:string)=>void,private open:(s:string)=>Promise<void>,private fetcher:Fetch=fetch){}
  env(engine:Engine,node=false):NodeJS.ProcessEnv {
    const env={...process.env};for(const k of Object.keys(env))if(/^(OPENAI_|CODEX_|ANTHROPIC_|CLAUDE|KIMI_|GEMINI_|GOOGLE_|GROK_|XAI_|AGY_|ANTIGRAVITY_)/.test(k))delete env[k];
    const info=runtimeInfo[engine];if(info){env[info.env]=this.storage.directory('Accounts',engine);if(engine==='gemini'){env.ANTIGRAVITY_CREDENTIAL_SCOPE='sideai-'+createHash('sha256').update(env[info.env]!).digest('hex');env.AGY_CLI_DISABLE_AUTO_UPDATE='1';}}
    env.NO_COLOR='1';env.NO_PROXY='localhost,127.0.0.1,::1';if(node)env.ELECTRON_RUN_AS_NODE='1';else delete env.ELECTRON_RUN_AS_NODE;return env;
  }
  prepare(engine:Engine){
    const cwd=this.storage.directory('Scratch','Accounts',engine),home=this.storage.directory('Accounts',engine);
    if(engine==='kimi')for(const dir of [path.join(home,'agents'),path.join(cwd,'.kimi-code','agents')]){fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'agent.md'),'---\nname: agent\ndescription: SideAI chat\noverride: true\ntools: []\nsubagents: []\n---\nAnswer the user. No local tools are available.\n');}
    if(engine==='gemini'){
      const app=path.join(home,'sideai');fs.mkdirSync(app,{recursive:true});fs.writeFileSync(path.join(app,'settings.json'),JSON.stringify({toolPermission:'strict',allowNonWorkspaceAccess:false,permissions:{deny:['read_file(*)','write_file(*)','read_url(*)','execute_url(*)','command(*)','mcp(*)']}}));
      const agents=path.join(cwd,'.agents','agents');fs.mkdirSync(agents,{recursive:true});fs.writeFileSync(path.join(agents,'sideai-chat.md'),'---\nname: sideai-chat\ndescription: SideAI chat\nmainAgent: true\nsubagent: false\ntools: []\nmcpServers: []\nskills: []\nplugins: []\ncommandExecutionPolicy: off\n---\nAnswer the user. No local tools are available.\n');
    }return cwd;
  }
  find(engine:Engine,custom?:string):{exe:string;prefix:string[];node:boolean}|undefined {
    const info=runtimeInfo[engine];if(!info)return;
    if(custom){if(!path.isAbsolute(custom)||!fs.existsSync(custom)||!/\.(exe|js|cjs|mjs)$/i.test(custom))throw Error('请选择官方客户端的 .exe 或 .js 文件。');return /\.exe$/i.test(custom)?{exe:custom,prefix:[],node:false}:{exe:process.execPath,prefix:[custom],node:true};}
    const nodeModules=path.join(this.storage.root,'Runtimes','node_modules'),packageName=info.pkg?.replace(/@[^/@]+$/,'');
    if(packageName){const dir=path.join(nodeModules,packageName),manifest=path.join(dir,'package.json');if(fs.existsSync(manifest)){const json=JSON.parse(fs.readFileSync(manifest,'utf8'));const bin=typeof json.bin==='string'?json.bin:json.bin?.[info.exe]??Object.values(json.bin??{})[0];if(typeof bin==='string'){const script=path.resolve(dir,bin);if(fs.existsSync(script))return {exe:process.execPath,prefix:[script],node:true};}}}
    const candidates=[path.join(this.storage.root,'Runtimes','bin',info.exe+'.exe'),path.join(os.homedir(),'.local','bin',info.exe+'.exe'),...(process.env.PATH??'').split(path.delimiter).filter(Boolean).map(p=>path.join(p,info.exe+(process.platform==='win32'?'.exe':'')))];
    const exe=candidates.find(p=>fs.existsSync(p));if(exe)return {exe,prefix:[],node:false};
  }
  async ensure(engine:Engine,custom:string|undefined,signal:AbortSignal){
    const existing=this.find(engine,custom);if(existing)return;
    if(engine==='gemini'&&process.platform==='win32'){
      this.notice('正在准备官方 Gemini 客户端…');
      const manifest=await jsonRequest(this.fetcher,'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/windows_amd64.json',{signal});
      const url=new URL(manifest.url);
      if(url.protocol!=='https:'||url.hostname!=='storage.googleapis.com'||!url.pathname.startsWith('/antigravity-public/antigravity-cli/')||!url.pathname.endsWith('.exe')||!/^[a-f0-9]{128}$/i.test(manifest.sha512))throw Error('官方安装清单校验失败');
      const response=await this.fetcher(url.href,{redirect:'error',signal});if(!response.ok||!response.body)throw Error('客户端下载失败');
      const chunks:Buffer[]=[];let size=0;for await(const chunk of response.body as any){size+=chunk.length;if(size>400*1024*1024)throw Error('官方客户端下载超过限制');chunks.push(Buffer.from(chunk));}
      const bytes=Buffer.concat(chunks);if(createHash('sha512').update(bytes).digest('hex')!==manifest.sha512)throw Error('官方客户端完整性校验失败');
      const file=path.join(this.storage.directory('Runtimes','bin'),'agy.exe');fs.writeFileSync(file+'.tmp',bytes);fs.renameSync(file+'.tmp',file);return;
    }
    const info=runtimeInfo[engine];if(!info?.pkg)throw Error('请在高级选项选择已安装的官方 Antigravity CLI（agy.exe）。');
    this.notice('正在安装官方客户端，首次使用可能需要几分钟…');
    const npm=path.join(path.dirname(require.resolve('npm/package.json')),'bin','npm-cli.js').replace(/app\.asar([\\/])/,'app.asar.unpacked$1');
    await this.runProcess(process.execPath,[npm,'install','--prefix',this.storage.directory('Runtimes'),'--no-audit','--no-fund',info.pkg],this.storage.root,{...this.env(engine,true)},signal,()=>{});
    if(!this.find(engine))throw Error('官方客户端安装失败，请检查网络后重试。');
  }
  start(c:Connection,args:string[],cwd?:string) {
    const command=this.find(c.engine,c.executable);if(!command)throw Error('找不到官方客户端，请重新登录或在连接设置选择路径。');
    return new RPC(command.exe,[...command.prefix,...args],cwd??this.prepare(c.engine),this.env(c.engine,command.node));
  }
  async runProcess(exe:string,args:string[],cwd:string,env:NodeJS.ProcessEnv,signal:AbortSignal,output:(s:string)=>void){
    const {spawn}=await import('node:child_process');await new Promise<void>((resolve,reject)=>{
      const p=spawn(exe,args,{cwd,env,windowsHide:true,stdio:['ignore','pipe','pipe'],shell:false});const tree=new ProcessTree(p);let settled=false;
      const finish=(e?:Error)=>{if(settled)return;settled=true;clearTimeout(timer);signal.removeEventListener('abort',cancel);e?reject(e):resolve();};
      const cancel=()=>{tree.terminate();finish(Error('登录已取消或超时'));};const timer=setTimeout(cancel,300000);signal.addEventListener('abort',cancel,{once:true});if(signal.aborted)cancel();
      p.stdout.on('data',b=>output(b.toString()));p.stderr.on('data',b=>output(b.toString()));p.on('error',e=>finish(e));p.on('close',code=>finish(code===0?undefined:Error(`官方客户端退出（${code}），请检查网络、客户端版本与账号。`)));
    });
  }
  async loginCLI(c:Connection,signal:AbortSignal,consoleAccount=false){
    const command=this.find(c.engine,c.executable)!;const args=c.engine==='claude'?['auth','login',...(consoleAccount?['--console']:[])]:c.engine==='grok'?['login','--oauth']:['login'];let opened=false,buffer='';
    await this.runProcess(command.exe,[...command.prefix,...args],this.prepare(c.engine),this.env(c.engine,command.node),signal,s=>{
      buffer=(buffer+s).slice(-32768);const code=buffer.match(/\b[A-Z0-9]{4}-[A-Z0-9]{4}\b/);if(code)this.notice('官方登录验证码：'+code[0]);
      for(const raw of buffer.match(/https:\/\/[^\s\u001b<>"']+/g)??[])try{const u=new URL(raw.replace(/[),.;]+$/,''));if(!opened&&runtimeInfo[c.engine].hosts.includes(u.hostname)){opened=true;void this.open(u.href).catch(()=>this.notice('请在官方客户端提供的浏览器窗口完成登录。'));}}catch{}
    });
  }
  acpArgs(engine:Engine){
    if(engine==='kimi')return ['acp'];
    if(engine==='grok')return ['--tools','','--deny','*','--no-subagents','--no-plan','--disable-web-search','--permission-mode','dontAsk','agent','stdio'];
    return ['acp','--gemini-dir',this.storage.directory('Accounts','gemini'),'--app-data-dir','sideai','--disable-telemetry','--include-default-customizations=false','--agent','sideai-chat','--log-file',process.platform==='win32'?'NUL':'/dev/null'];
  }
}
export function acpModels(session:any):Model[]{
  if(session.models?.availableModels?.length)return session.models.availableModels.map((m:any)=>({id:m.modelId,name:m.name??m.modelId}));
  const flatten=(a:any[]):Model[]=>a.flatMap(m=>m.options?flatten(m.options):typeof m.value==='string'?[{id:m.value,name:m.name??m.value}]:[]);
  return flatten(session.configOptions?.find((m:any)=>m.category==='model'||m.id==='model')?.options??[]);
}
export async function startACP(runtime:Runtimes,c:Connection){
  const rpc=runtime.start(c,runtime.acpArgs(c.engine));
  rpc.on('event',m=>{if(m.id!==undefined){if(m.method==='session/request_permission')rpc.reply(m.id,{outcome:{outcome:'cancelled'}});else rpc.reject(m.id);}});
  try{const info=await rpc.request('initialize',{protocolVersion:1,clientInfo:{name:'SideAI',version:'0.9.0'},clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false}});return {rpc,info};}catch(e){rpc.stop();throw e;}
}
export function acpPrompt(c:Conversation){return c.items.filter(i=>['user','assistant'].includes(i.role)&&(!i.status||i.status==='completed')).flatMap(i=>[{type:'text',text:(i.role==='user'?'User: ':'Assistant: ')+i.text},...(i.images??[]).map(a=>({type:'image',mimeType:'image/png',data:a.dataURL.split(',')[1]}))]);}
