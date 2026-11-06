import {createServer} from 'node:http';
import {randomBytes,createHash} from 'node:crypto';
import {Fetch,jsonRequest} from './http';
const random=()=>randomBytes(32).toString('base64url');
export async function loopback(signal:AbortSignal) {
  const state=random();let resolve!:(u:URL)=>void,reject!:(e:Error)=>void;
  const result=new Promise<URL>((r,j)=>{resolve=r;reject=j;});result.catch(()=>{});
  const server=createServer({maxHeaderSize:16384},(req,res)=>{
    const url=new URL(req.url??'/',redirect);
    const duplicate=[...url.searchParams.keys()].some(k=>url.searchParams.getAll(k).length!==1);
    const valid=req.method==='GET'&&url.pathname==='/auth/callback'&&url.searchParams.get('state')===state&&!duplicate&&req.headers.host===`127.0.0.1:${port}`;
    res.writeHead(valid?200:400,{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store','Connection':'close'});res.end(valid?'请返回 SideAI 查看登录结果。':'Invalid callback');
    if(valid){resolve(url);close();}
  });
  server.requestTimeout=10000;server.headersTimeout=10000;
  let port=0,redirect='';await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});port=(server.address() as any).port;redirect=`http://127.0.0.1:${port}/auth/callback`;
  const cancel=()=>{reject(Error('登录已取消或超时'));close();};
  const timer=setTimeout(cancel,300000);function close(){clearTimeout(timer);signal.removeEventListener('abort',cancel);server.closeAllConnections();server.close();}
  signal.addEventListener('abort',cancel,{once:true});if(signal.aborted)cancel();
  return {state,redirect,result,close};
}
export interface Tokens {access_token:string;refresh_token:string;id_token:string;expiresAt:number;clientID:string;subject:string;scopes:string[]}
async function tokens(fetcher:Fetch,fields:Record<string,string>,nonce?:string,previous?:Tokens):Promise<Tokens>{
  const raw=await jsonRequest(fetcher,'https://auth.openai.com/api/accounts/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(fields).toString()});
  const scopes=raw.scope?.split(' ')??previous?.scopes??[];
  if(!scopes.includes('resource.invoke')||!scopes.includes('chatgpt.tokens.use.direct')||raw.token_type?.toLowerCase()!=='bearer'||!raw.access_token||!(raw.expires_in>0))throw Error('未获得 ChatGPT 计划调用权限。');
  let subject=previous?.subject??'';
  if(raw.id_token){
    const {jwtVerify,createLocalJWKSet}=await import('jose');
    const discovery=await jsonRequest(fetcher,'https://auth.openai.com/.well-known/openid-configuration');
    const u=new URL(discovery.jwks_uri);if(discovery.issuer!=='https://auth.openai.com'||u.origin!=='https://auth.openai.com')throw Error('身份验证配置不匹配');
    const keys=await jsonRequest(fetcher,u.href);const {payload}=await jwtVerify(raw.id_token,createLocalJWKSet(keys),{issuer:'https://auth.openai.com',audience:fields.client_id,algorithms:['RS256']});
    if(!payload.sub||(nonce&&payload.nonce!==nonce)||(previous&&payload.sub!==previous.subject)||(Array.isArray(payload.aud)&&payload.aud.length>1&&payload.azp!==fields.client_id))throw Error('登录身份验证失败');subject=payload.sub;
  }else if(!previous||nonce)throw Error('未收到身份令牌');
  return {access_token:raw.access_token,refresh_token:raw.refresh_token??previous?.refresh_token??'',id_token:raw.id_token??previous?.id_token??'',expiresAt:Date.now()+raw.expires_in*1000,clientID:fields.client_id,subject,scopes};
}
export async function signInGPT(fetcher:Fetch,open:(url:string)=>Promise<void>,hostID:string,signal:AbortSignal){
  const cb=await loopback(signal),verifier=random(),nonce=random();
  try{const url=new URL('https://auth.openai.com/api/accounts/authorize');url.search=new URLSearchParams({client_id:'dynamic_agent_client',ext_agent_host_id:hostID,response_type:'code',redirect_uri:cb.redirect,scope:'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',resource:'https://api.openai.com/v1',state:cb.state,nonce,code_challenge_method:'S256',code_challenge:createHash('sha256').update(verifier).digest('base64url'),agent_name_hint:'SideAI'}).toString();await open(url.href);
    const result=(await cb.result).searchParams,client=result.get('client_id'),code=result.get('code');if(result.has('error')||!client||client==='dynamic_agent_client'||!code)throw Error('登录未完成或没有返回客户端注册信息');
    return await tokens(fetcher,{grant_type:'authorization_code',client_id:client,code,code_verifier:verifier,redirect_uri:cb.redirect,resource:'https://api.openai.com/v1'},nonce);
  }finally{cb.close();}
}
export async function refreshGPT(fetcher:Fetch,previous:Tokens){if(!previous.refresh_token)throw Error('请重新登录 ChatGPT');return tokens(fetcher,{grant_type:'refresh_token',client_id:previous.clientID,refresh_token:previous.refresh_token,resource:'https://api.openai.com/v1'},undefined,previous);}
export async function signInRouter(fetcher:Fetch,open:(url:string)=>Promise<void>,signal:AbortSignal){
  const cb=await loopback(signal),verifier=random();try{const url=new URL('https://openrouter.ai/auth');url.search=new URLSearchParams({callback_url:cb.redirect,state:cb.state,code_challenge:createHash('sha256').update(verifier).digest('base64url'),code_challenge_method:'S256',key_label:'SideAI'}).toString();await open(url.href);const result=(await cb.result).searchParams;if(result.has('error')||!result.get('code'))throw Error('授权未完成');const raw=await jsonRequest(fetcher,'https://openrouter.ai/api/v1/auth/keys',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:result.get('code'),code_verifier:verifier,code_challenge_method:'S256'})});if(!raw.key)throw Error('未收到密钥');return raw.key as string;}finally{cb.close();}
}
