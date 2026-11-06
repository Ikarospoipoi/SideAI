/** Pure controller: native calls are injectable so races can be tested without a game. */
export interface NativeWindow { handle: bigint; pid: number }
export interface FocusPort {
  current(): NativeWindow | undefined; valid(w:NativeWindow):boolean;
  activate(w:NativeWindow):boolean; releaseCursor():boolean;
  keysDown():boolean;
}
export class FocusLease {
  previous?:NativeWindow;
  constructor(public port:FocusPort,public own:NativeWindow){}
  acquire() {
    const current=this.port.current();
    if(current && current.handle!==this.own.handle)this.previous=current;
    const active=this.port.activate(this.own);
    return {active,released:active?this.port.releaseCursor():false};
  }
  maintain() {if(this.port.current()?.handle===this.own.handle)return this.port.releaseCursor();return false;}
  restore() {
    const previous=this.previous;this.previous=undefined;
    // Never restore a stale/reused HWND or steal focus from a new third-party window.
    const current=this.port.current();
    if(previous && this.port.valid(previous) && (!current||current.handle===this.own.handle||current.handle===previous.handle))return this.port.activate(previous);
    return false;
  }
  abandon(){this.previous=undefined;}
}
export function clampBounds(b:{x:number;y:number;width:number;height:number},screens:{x:number;y:number;width:number;height:number}[]) {
  if(screens.some(s=>Math.min(b.x+b.width,s.x+s.width)-Math.max(b.x,s.x)>=48 && Math.min(b.y+b.height,s.y+s.height)-Math.max(b.y,s.y)>=48))return b;
  const s=screens[0];return {...b,x:s.x+12,y:s.y+24,width:Math.min(b.width,s.width-24),height:Math.min(b.height,s.height-48)};
}
