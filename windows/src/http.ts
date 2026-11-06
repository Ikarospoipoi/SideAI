import {Connection,Conversation,endpoint} from './types';
export type Fetch = typeof fetch;
export async function jsonRequest(fetcher:Fetch,url:string,init:RequestInit={}) {
  const response=await fetcher(url,{...init,redirect:'error',signal:init.signal??AbortSignal.timeout(30000)});
  if(!response.ok)throw Error(`服务返回 HTTP ${response.status}。请检查登录、额度与连接地址。`);return response.json();
}
export function body(c:Conversation,format:Connection['format']) {
  const rows=c.items.filter(i=>['user','assistant'].includes(i.role)&&(!i.status||i.status==='completed')).map(i=>({role:i.role,content:[
    ...(i.text?[{type:format==='responses'?(i.role==='user'?'input_text':'output_text'):'text',text:i.text}]:[]),
    ...(i.role==='user'?i.images??[]:[]).map(a=>format==='anthropic'?{type:'image',source:{type:'base64',media_type:'image/png',data:a.dataURL.split(',')[1]}}:format==='responses'?{type:'input_image',image_url:a.dataURL}:{type:'image_url',image_url:{url:a.dataURL}})
  ]}));
  if(!c.model)throw Error('请先选择或填写模型。');
  return {model:c.model,stream:true,...(format==='responses'?{input:rows,store:false,...(c.effort?{reasoning:{effort:c.effort}}:{})}:{messages:rows,...(format==='anthropic'?{max_tokens:8192,...(c.effort?{output_config:{effort:c.effort}}:{})}:c.effort?{reasoning_effort:c.effort}:{})})};
}
export class SSE {
  private decoder=new TextDecoder('utf-8',{fatal:true});private buffer='';private data:string[]=[];private size=0;
  push(bytes:Uint8Array):string[] {this.buffer+=this.decoder.decode(bytes,{stream:true});if(this.buffer.length>4_000_000)throw Error('流事件过大');const lines=this.buffer.split('\n');this.buffer=lines.pop()!;const out:string[]=[];for(let line of lines){line=line.replace(/\r$/,'');if(!line){if(this.data.length)out.push(this.data.join('\n'));this.data=[];this.size=0;}else if(line.startsWith('data:')){const v=line.slice(5).replace(/^ /,'');this.size+=v.length;if(this.size>4_000_000)throw Error('流事件过大');this.data.push(v);}}return out;}
}
export async function chat(fetcher:Fetch,connection:Connection,c:Conversation,key:string,signal:AbortSignal,onText:(t:string)=>void) {
  const format=connection.format??'chatCompletions';const headers:Record<string,string>={'Content-Type':'application/json'};
  if(format==='anthropic'){headers['x-api-key']=key;headers['anthropic-version']='2023-06-01';}else headers.Authorization=`Bearer ${key}`;
  const route=format==='responses'?'responses':format==='anthropic'?'messages':'chat/completions';
  const response=await fetcher(`${endpoint(connection.endpoint!)}/${route}`,{method:'POST',headers,body:JSON.stringify(body(c,format)),signal,redirect:'error'});
  if(!response.ok)throw Error(`请求失败（HTTP ${response.status}）。请检查此连接的账号、模型与额度。`);
  if(!response.body)throw Error('服务器未返回内容');
  const sse=new SSE();let text='',done=false;
  for await(const chunk of response.body as any){for(const line of sse.push(chunk)){
    if(line==='[DONE]'){done=true;continue;}const m=JSON.parse(line);
    if(m.error||['error','response.failed','response.incomplete'].includes(m.type))throw Error('服务未完整生成回复，请检查模型、额度与网络。');
    if(m.type==='response.output_text.delta')text+=m.delta??'';
    if(m.type==='content_block_delta'&&m.delta?.type==='text_delta')text+=m.delta.text??'';
    if(m.choices?.[0]?.delta?.content)text+=m.choices[0].delta.content;
    if(m.type==='response.completed'||m.type==='message_stop')done=true;
    onText(text);
  }}
  if(!done)throw Error('连接中断，回复不完整。未自动重发。');return text;
}
