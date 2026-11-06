export type Format = 'responses' | 'chatCompletions' | 'anthropic';
export type Engine = 'api' | 'chatgpt' | 'openrouter' | 'codex' | 'claude' | 'kimi' | 'grok' | 'gemini';
export type Workspace = 'chat' | 'agent';
export interface Model { id: string; name: string; efforts?: string[] }
export interface Connection { id: string; name: string; provider: string; engine: Engine; workspace: Workspace; endpoint?: string; format?: Format; model?: string; executable?: string; models: Model[] }
export interface Attachment { id: string; name: string; path: string; dataURL: string }
export interface Item { id: string; role: 'user'|'assistant'|'tool'|'reasoning'; text: string; images?: Attachment[]; status?: string }
export interface Conversation { id: string; connectionID: string; title: string; draft: string; images: Attachment[]; items: Item[]; cwd: string; mode: 'readOnly'|'project'; model: string; effort: string; status: string; updated: number; threadID?: string; sessionID?: string; hasSession?: boolean; archived?: boolean; readOnly?: boolean; handoffFrom?: string }
export interface Settings { hotkey: string; gameMode: boolean; pin: boolean; autoPeek: boolean; bounds?: {x:number;y:number;width:number;height:number}; hostID: string }
export interface Snapshot { version: 1; connections: Connection[]; conversations: Conversation[]; settings: Settings; selected?: string; workspace: Workspace }
export interface Approval { id: string; conversationID: string; method: string; title: string; detail: string; cwd: string; created: number; questions?: any[]; submitted?: boolean }
export interface ViewState extends Snapshot { approvals: Approval[]; busy?: string; notice: string; loginBusy: boolean; hotkeyError: string; platform: string }
export const providers: Record<string, {name: string; color: string; endpoint: string; format: Format; official?: Engine}> = {
  openai: {name:'GPT',color:'#82c7b3',endpoint:'https://api.openai.com/v1',format:'responses',official:'chatgpt'},
  anthropic: {name:'Claude',color:'#f59b60',endpoint:'https://api.anthropic.com/v1',format:'anthropic'},
  deepseek: {name:'DeepSeek',color:'#6698ff',endpoint:'https://api.deepseek.com',format:'chatCompletions'},
  kimi: {name:'Kimi',color:'#67c5d0',endpoint:'https://api.moonshot.cn/v1',format:'chatCompletions',official:'kimi'},
  gemini: {name:'Gemini',color:'#94a7ff',endpoint:'https://generativelanguage.googleapis.com/v1beta/openai',format:'chatCompletions',official:'gemini'},
  grok: {name:'Grok',color:'#ddd',endpoint:'https://api.x.ai/v1',format:'chatCompletions',official:'grok'},
  qwen: {name:'Qwen',color:'#b495ee',endpoint:'https://dashscope.aliyuncs.com/compatible-mode/v1',format:'chatCompletions'},
  openrouter: {name:'OpenRouter',color:'#aaa',endpoint:'https://openrouter.ai/api/v1',format:'chatCompletions',official:'openrouter'},
  custom: {name:'其他 AI',color:'#aaa',endpoint:'',format:'chatCompletions'}
};
export function endpoint(value: string): string {
  const u = new URL(value.trim());
  if (!(u.protocol === 'https:' || (u.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(u.hostname))) || u.username || u.password || u.search || u.hash) throw Error('请输入 HTTPS API 地址；仅本机服务可使用 HTTP。');
  return u.href.replace(/\/+$/, '');
}
export function connectionGroup(c: Connection): string { return `${c.workspace}:${c.provider === 'custom' ? c.endpoint : c.provider}`; }
export function safeError(error: unknown): string {
  return String(error instanceof Error ? error.message : error).replace(/(?:sk-|Bearer\s+)[A-Za-z0-9_.-]+/gi,'[已隐藏]').replace(/([?&](?:code|token|key|access_token)=)[^&\s]+/gi,'$1[已隐藏]').slice(0,800);
}
