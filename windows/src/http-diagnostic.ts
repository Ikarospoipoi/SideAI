/** Only protocol identifiers and reset values are retained, never raw headers/bodies. */
export interface HTTPDiagnostic {host:string;path:string;status:number;event?:string;errorType?:string;errorCode?:string;resetFields:Record<string,string>;recordedAt:string}
export function httpDiagnostic(url:string,status:number,headers:Headers,payload:any):HTTPDiagnostic {
  const u=new URL(url),e=payload?.error??payload?.response?.error??{};
  const identifier=(v:unknown)=>typeof v==='string'&&/^[a-z][a-z0-9_.]{0,79}$/.test(v)?v:undefined;
  const reset=(v:unknown)=>['string','number'].includes(typeof v)&&String(v).length<=80&&/^(?:[0-9]+(?:\.[0-9]+)?(?:ms|s|m|h|d)?)+$|^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+Z-]+$|^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9:]{8} GMT$/.test(String(v))?String(v):undefined;
  const resetFields:Record<string,string>={};
  for(const key of ['retry-after','x-ratelimit-reset-requests','x-ratelimit-reset-tokens','x-ratelimit-reset-project-tokens']){const value=reset(headers.get(key));if(value!==undefined)resetFields[key]=value;}
  for(const key of ['reset_at','resets_at','reset_after','reset_after_seconds','retry_after','retry_after_seconds'])for(const [prefix,object]of [['error.',e],['',payload]] as const){const value=reset(object?.[key]);if(value!==undefined)resetFields[prefix+key]=value;}
  return {host:u.hostname,path:u.pathname,status,event:identifier(payload?.type),errorType:identifier(e.type),errorCode:identifier(e.code),resetFields,recordedAt:new Date().toISOString()};
}
export class HTTPChatFailure extends Error {
  constructor(public diagnostic:HTTPDiagnostic){super(diagnostic.errorCode==='subscription_sharing_usage_limit_exceeded'?'ChatGPT 授权使用额度已达上限，请等待额度恢复或选择其他连接。':`请求未完成（HTTP ${diagnostic.status}${diagnostic.errorCode?' · '+diagnostic.errorCode:''}）。可展开请求诊断查看详情。`);}
}
