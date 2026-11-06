const koffi = require('koffi');
import {FocusPort,NativeWindow} from './focus';
export class Win32 implements FocusPort {
  private lib=koffi.load('user32.dll');
  private foreground=this.lib.func('uintptr_t __stdcall GetForegroundWindow()');
  private setForeground=this.lib.func('int __stdcall SetForegroundWindow(uintptr_t hwnd)');
  private isWindow=this.lib.func('int __stdcall IsWindow(uintptr_t hwnd)');
  private processID=this.lib.func('uint32_t __stdcall GetWindowThreadProcessId(uintptr_t hwnd, _Out_ uint32_t *pid)');
  private setCursor=this.lib.func('int __stdcall SetCursorPos(int x, int y)');
  moveCursor(x:number,y:number){return !!this.setCursor(x,y);}
  private clip=this.lib.func('int __stdcall ClipCursor(void *rect)');
  private keyState=this.lib.func('int16_t __stdcall GetAsyncKeyState(int key)');
  private register=this.lib.func('int __stdcall RegisterHotKey(uintptr_t hwnd, int id, uint32_t modifiers, uint32_t key)');
  private unregister=this.lib.func('int __stdcall UnregisterHotKey(uintptr_t hwnd, int id)');
  private show=this.lib.func('int __stdcall ShowWindow(uintptr_t hwnd, int command)');
  private iconic=this.lib.func('int __stdcall IsIconic(uintptr_t hwnd)');
  private keys:number[]=[0x11,0x12,0x20];
  window(handle:bigint):NativeWindow {const pid=[0];this.processID(handle,pid);return {handle,pid:pid[0]};}
  current(){const h=BigInt(this.foreground());return h?this.window(h):undefined;}
  valid(w:NativeWindow){return !!this.isWindow(w.handle)&&this.window(w.handle).pid===w.pid;}
  activate(w:NativeWindow){if(!this.valid(w))return false;if(this.iconic(w.handle))this.show(w.handle,9);return !!this.setForeground(w.handle);}
  releaseCursor(){return !!this.clip(null);}
  keysDown(){return this.keys.some(k=>(this.keyState(k)&0x8000)!==0);}
  registerHotkey(hwnd:bigint,id:number,accelerator:string) {
    const {modifiers,key,keys}=parseHotkey(accelerator);
    const ok=!!this.register(hwnd,id,modifiers|0x4000,key); // MOD_NOREPEAT
    if(ok&&id===1)this.keys=keys;
    return ok;
  }
  unregisterHotkey(hwnd:bigint,id:number){this.unregister(hwnd,id);}
}
export function parseHotkey(value:string) {
  const parts=value.toLowerCase().split('+');let modifiers=0;const keys:number[]=[];
  const mods:Record<string,[number,number]>={control:[2,0x11],ctrl:[2,0x11],alt:[1,0x12],shift:[4,0x10],super:[8,0x5b],win:[8,0x5b]};
  for(const m of parts.slice(0,-1)){if(!mods[m])throw Error('快捷键修饰键无效');modifiers|=mods[m][0];keys.push(mods[m][1]);}
  const last=parts.at(-1)!;let key=last==='space'?0x20:last.length===1&&/[a-z0-9]/.test(last)?last.toUpperCase().charCodeAt(0):/^f([1-9]|1\d|2[0-4])$/.test(last)?111+Number(last.slice(1)):0;
  if(!key||!(modifiers&11))throw Error('快捷键需包含 Ctrl、Alt 或 Win，可用字母、数字、Space 或 F1–F24。');keys.push(key);return {modifiers,key,keys};
}
