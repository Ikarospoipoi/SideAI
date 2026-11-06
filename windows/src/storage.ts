import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {Snapshot} from './types';
export class Storage {
  state: Snapshot;
  private timer?: NodeJS.Timeout;
  constructor(public root: string) {
    fs.mkdirSync(root,{recursive:true,mode:0o700});
    const file=path.join(root,'state.json');
    if (fs.existsSync(file)) {
      const s=JSON.parse(fs.readFileSync(file,'utf8'));
      if(s.version!==1 || !Array.isArray(s.connections) || !Array.isArray(s.conversations) || !s.settings) throw Error('数据格式不兼容。原文件已保留，请备份后检查。');
      this.state=s;
      for(const c of this.state.conversations) if(['running','awaitingApproval'].includes(c.status)) c.status='interrupted';
    } else this.state={version:1,connections:[],conversations:[],workspace:'chat',settings:{hotkey:'Control+Alt+Space',gameMode:true,pin:false,autoPeek:true,hostID:`urn:uuid:${randomUUID()}`}};
  }
  directory(...parts:string[]) { const p=path.join(this.root,...parts);fs.mkdirSync(p,{recursive:true,mode:0o700});return p; }
  saveSoon() { if(!this.timer) this.timer=setTimeout(()=>{this.timer=undefined;this.save();},1500); }
  save() {
    if(this.timer) clearTimeout(this.timer);this.timer=undefined;
    const file=path.join(this.root,'state.json');
    fs.writeFileSync(file+'.tmp',JSON.stringify(this.state),{mode:0o600});fs.renameSync(file+'.tmp',file);
  }
  backup() { this.save(); const file=path.join(this.directory('Backups'),`${Date.now()}.json`);fs.copyFileSync(path.join(this.root,'state.json'),file);return file; }
}
export interface Cipher { encryptString(s:string):Buffer; decryptString(b:Buffer):string; isEncryptionAvailable():boolean }
export class Vault {
  constructor(private root:string, private cipher:Cipher) {fs.mkdirSync(root,{recursive:true,mode:0o700});}
  private file(id:string) { if(!/^[a-f0-9-]{36}$/i.test(id)) throw Error('凭据 ID 无效');return path.join(this.root,id+'.bin'); }
  put(id:string,value:string) {if(!this.cipher.isEncryptionAvailable()) throw Error('Windows 凭据加密不可用，未保存密钥。'); const p=this.file(id);fs.writeFileSync(p+'.tmp',this.cipher.encryptString(value),{mode:0o600});fs.renameSync(p+'.tmp',p);}
  get(id:string) {const p=this.file(id);if(!fs.existsSync(p)) throw Error('请重新登录或填写 API Key。');return this.cipher.decryptString(fs.readFileSync(p));}
  delete(id:string) {fs.rmSync(this.file(id),{force:true});}
}
