import {app,BrowserWindow,Tray,Menu,nativeImage,ipcMain,dialog,safeStorage,net,screen,globalShortcut,shell,powerMonitor} from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {randomUUID} from 'node:crypto';
import {Storage,Vault} from './storage';
import {Service} from './service';
import {Win32} from './win32';
import {FocusLease,clampBounds} from './focus';
import {Attachment,safeError,providers} from './types';
const smoke=process.argv.includes('--smoke-test'),lab=process.argv.includes('--game-lab');
if(smoke)app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'SideAI-smoke-')));
else app.setPath('userData',path.join(app.getPath('appData'),'SideAI-Windows'));
if(!smoke&&!app.requestSingleInstanceLock()){app.quit();}
let window:BrowserWindow,tray:Tray,handle:BrowserWindow,service:Service,native:Win32|undefined,lease:FocusLease|undefined;
let closing=false,modal=false,quitting=false,cursorTimer:NodeJS.Timeout|undefined,returnTimer:NodeJS.Timeout|undefined;
let hotkey='',shownAt=0,stats={opens:0,lastFocusMs:0,lastNativeFocus:false,cursorReleased:false,restored:false};
function icon(color='#82c7b3') {const pixels=Buffer.alloc(24*24*4);const rgb=color.match(/\w\w/g)!.map(x=>parseInt(x,16));for(let y=4;y<20;y++)for(let x=4;x<20;x++)if(x<8||y<7||y>16){const i=(y*24+x)*4;pixels[i]=rgb[2];pixels[i+1]=rgb[1];pixels[i+2]=rgb[0];pixels[i+3]=255;}return nativeImage.createFromBitmap(pixels,{width:24,height:24});}
function sendFocus(){window.webContents.send('focus-composer');}
function show(){
  if(!window||window.isDestroyed())return;closing=false;if(returnTimer)clearTimeout(returnTimer);returnTimer=undefined;
  shownAt=Date.now();stats.opens++;
  // Capture foreground before Electron show/focus changes it.
  if(lease){const previous=native!.current();if(previous&&previous.handle!==lease.own.handle)lease.previous=previous;}
  const displays=screen.getAllDisplays().map(d=>d.workArea);window.setBounds(clampBounds(window.getBounds(),displays));
  handle.hide();window.setAlwaysOnTop(true,'screen-saver');window.show();
  if(native&&lease){stats.lastNativeFocus=native.activate(lease.own);stats.cursorReleased=stats.lastNativeFocus&&service.state.settings.gameMode?native.releaseCursor():false;}
  window.focus();window.webContents.focus();sendFocus();
  if(native&&lease&&service.state.settings.gameMode&&native.current()?.handle===lease.own.handle){native.releaseCursor();const b=window.getBounds(),point=screen.dipToScreenPoint({x:Math.round(b.x+b.width/2),y:Math.round(b.y+b.height-160)});native.moveCursor(point.x,point.y);}
  if(cursorTimer)clearInterval(cursorTimer);
  if(native&&service.state.settings.gameMode)cursorTimer=setInterval(()=>{if(window.isVisible()&&window.isFocused())stats.cursorReleased=lease!.maintain();},120);
  if(native&&!window.isFocused())service.message('Windows 未授予输入焦点，请点击侧栏。独占全屏可改用无边框模式。');
}
function hide(restore=true){
  if(closing||!window?.isVisible())return;closing=true;if(cursorTimer)clearInterval(cursorTimer);cursorTimer=undefined;
  const deadline=Date.now()+2000;
  const finish=()=>{
    if(!closing)return;
    // Return only after modifiers are physically released. Never synthesize game inputs.
    if(restore&&native?.keysDown()&&Date.now()<deadline){returnTimer=setTimeout(finish,16);return;}
    if(restore&&lease){stats.restored=lease.restore();}else lease?.abandon();
    window.setAlwaysOnTop(false);window.hide();closing=false;returnTimer=undefined;positionHandle();handle.showInactive();
  };finish();
}
function toggle(){window.isVisible()&&window.isFocused()?hide():show();}
function positionHandle(){const display=screen.getDisplayMatching(window.getBounds()),area=display.workArea;handle.setBounds({x:area.x,y:Math.round(area.y+area.height/2-32),width:10,height:64});}
function registerHotkey(next:string){
  if(next===hotkey)return;
  if(native&&lease){
    // Reserve a temporary ID first; a bad new binding must not discard the working one.
    if(!native.registerHotkey(lease.own.handle,3,next))throw Error('快捷键已被占用，请换一个组合。');native.unregisterHotkey(lease.own.handle,3);
    if(hotkey)native.unregisterHotkey(lease.own.handle,1);
    if(!native.registerHotkey(lease.own.handle,1,next)){if(hotkey)native.registerHotkey(lease.own.handle,1,hotkey);throw Error('无法注册快捷键');}
  }else{if(!globalShortcut.register(next,toggle))throw Error('快捷键已被占用');if(hotkey)globalShortcut.unregister(hotkey);}
  hotkey=next;service.hotkeyError='';
}
async function pick(options:Electron.OpenDialogOptions){modal=true;try{return await dialog.showOpenDialog(window,options);}finally{modal=false;}}
async function attachment(bytes:Buffer,name:string):Promise<Attachment>{
  if(bytes.length>20*1024*1024)throw Error('每张图片不能超过 20 MB');let image=nativeImage.createFromBuffer(bytes);if(image.isEmpty())throw Error('图片格式无法读取，请使用 PNG、JPG 或 WebP');const size=image.getSize();if(Math.max(size.width,size.height)>2048)image=image.resize(size.width>size.height?{width:2048}:{height:2048});
  const id=randomUUID(),file=path.join(service.storage.directory('Attachments'),id+'.png'),png=image.toPNG();fs.writeFileSync(file,png);return {id,name:name.slice(0,150),path:file,dataURL:'data:image/png;base64,'+png.toString('base64')};
}
async function action(method:string,p:any={}){
  switch(method){
    case 'state':return service.view();
    case 'catalog':return providers;
    case 'hide':hide();return;
    case 'home':service.state.selected=undefined;service.changed();return;
    case 'workspace':if(!['chat','agent'].includes(p.value))throw Error('模式无效');service.state.workspace=p.value;service.state.selected=undefined;service.changed();return;
    case 'selectConnection':service.selectConnection(p.id);return;
    case 'select':service.select(p.id);return;
    case 'new':return service.newConversation(p.id);
    case 'patch':service.patch(p.id,p.patch);return;
    case 'send':return service.send(p.id);
    case 'stop':service.stop();return;
    case 'models':return service.models(p.id);
    case 'saveAPI':return service.saveAPI(p);
    case 'login':return service.loginConnection(p.engine,p);
    case 'cancelLogin':service.cancelLogin();return;
    case 'deleteConnection':await service.removeConnection(p.id);return;
    case 'reset':await service.reset();return;
    case 'approve':service.respond(p.id,p.allow===true,p.answers??{});return;
    case 'project':{const c=service.conversation();if(service.busy===c.id)throw Error('请先停止当前任务');const result=await pick({title:'选择项目文件夹',properties:['openDirectory']});if(!result.canceled){c.cwd=result.filePaths[0];service.changed();}return;}
    case 'executable':{const result=await pick({title:'选择官方客户端',properties:['openFile'],filters:[{name:'官方客户端',extensions:['exe','js','cjs','mjs']}]});return result.filePaths[0];}
    case 'images':{const result=await pick({properties:['openFile','multiSelections'],filters:[{name:'图片',extensions:['png','jpg','jpeg','webp','gif']}]});if(result.canceled)return;const c=service.conversation();if(c.images.length+result.filePaths.length>8)throw Error('每条最多 8 张图片');const images=[];for(const file of result.filePaths){if(fs.statSync(file).size>20*1024*1024)throw Error('图片超过 20 MB');images.push(await attachment(fs.readFileSync(file),path.basename(file)));}service.addImages(images);return;}
    case 'imageBytes':{if(!Array.isArray(p.images)||p.images.length+service.conversation().images.length>8)throw Error('每条最多 8 张图片');const images=[];for(const image of p.images){if(!(image.bytes instanceof Uint8Array)||image.bytes.length>20*1024*1024)throw Error('图片过大');images.push(await attachment(Buffer.from(image.bytes),String(image.name??'图片')));}service.addImages(images);return;}
    case 'sync':return service.sync(p.id);
    case 'history':return service.history(p.id);
    case 'handoff':service.handoff(p.source,p.target);return;
    case 'returnResult':service.returnResult(p.id);return;
    case 'import':{const result=await pick({title:'导入 ChatGPT 导出文件',properties:['openFile'],filters:[{name:'ChatGPT JSON',extensions:['json']}]});if(!result.canceled){if(fs.statSync(result.filePaths[0]).size>100*1024*1024)throw Error('导入文件不能超过 100 MB');service.importChatGPT(result.filePaths[0]);}return;}
    case 'settings':{
      if(typeof p.hotkey==='string'){registerHotkey(p.hotkey);service.state.settings.hotkey=p.hotkey;}
      for(const key of ['gameMode','pin','autoPeek'] as const)if(typeof p[key]==='boolean')service.state.settings[key]=p[key];
      service.changed();return;
    }
    case 'diagnostics':return {...stats,platform:process.platform,version:app.getVersion(),hotkey,windowsNative:!!native};
    case 'focusAck':stats.lastFocusMs=Date.now()-shownAt;return;
    case 'sandbox':{service.idle();const c=service.connection(p.id);if(c.engine!=='codex')throw Error('请选择 Codex 连接');const {codexConnect}=await import('./agents.js');const rpc=await codexConnect(service.runtime,c);try{return await rpc.request('windowsSandbox/setupStart',{mode:'unelevated',cwd:service.storage.directory('Scratch')});}finally{rpc.stop();}}
    default:throw Error('不支持的操作');
  }
}
async function start(){
  const storage=new Storage(app.getPath('userData'));
  service=new Service(storage,new Vault(storage.directory('Credentials'),safeStorage),net.fetch as typeof fetch,async url=>{const u=new URL(url);if(u.protocol!=='https:')throw Error('登录地址无效');await shell.openExternal(u.href);});
  const primary=screen.getPrimaryDisplay().workArea,bounds=storage.state.settings.bounds??{x:primary.x+12,y:primary.y+40,width:460,height:Math.min(820,primary.height-80)};
  window=new BrowserWindow({...clampBounds(bounds,screen.getAllDisplays().map(d=>d.workArea)),minWidth:360,minHeight:420,show:false,frame:false,backgroundColor:'#202020',skipTaskbar:true,resizable:true,webPreferences:{preload:path.join(__dirname,'preload.js'),contextIsolation:true,nodeIntegration:false,sandbox:true,spellcheck:false}});
  window.setMenu(null);window.webContents.setWindowOpenHandler(()=>({action:'deny'}));window.webContents.on('will-navigate',e=>e.preventDefault());window.webContents.session.setPermissionRequestHandler((_w,_p,callback)=>callback(false));
  handle=new BrowserWindow({width:10,height:64,frame:false,transparent:true,show:false,skipTaskbar:true,resizable:false,focusable:false,alwaysOnTop:true,webPreferences:{preload:path.join(__dirname,'preload.js'),sandbox:true,contextIsolation:true,nodeIntegration:false}});handle.setMenu(null);
  await handle.loadURL('data:text/html,'+encodeURIComponent(`<html><body style="margin:0;background:#82c7b3;border-radius:8px;cursor:pointer" title="SideAI"></body></html>`));
  // Native handle receives mouse events without taking keyboard focus from a game.
  if(process.platform==='win32'){
    native=new Win32();lease=new FocusLease(native,native.window(window.getNativeWindowHandle().readBigUInt64LE()));
    window.hookWindowMessage(0x0312,wparam=>{const id=wparam.readUInt32LE();if(id===1)toggle();else if(id===2)hide();});
    handle.hookWindowMessage(0x0201,()=>show());
    native.registerHotkey(lease.own.handle,2,'Control+Alt+Shift+F12');
  }else handle.on('focus',show);
  try{registerHotkey(storage.state.settings.hotkey);}catch(e){service.hotkeyError=safeError(e);}
  ipcMain.handle('sideai',async(event,method,p)=>{
    if(event.sender!==window.webContents||event.senderFrame!==window.webContents.mainFrame)throw Error('无效的窗口请求');
    try{return {ok:true,value:await action(method,p)};}catch(e){const message=safeError(e);service.message(message);return {ok:false,error:message};}
  });
  service.on('change',state=>{if(!window.isDestroyed())window.webContents.send('state',state);const waiting=state.approvals.length;tray?.setToolTip(waiting?`SideAI · ${waiting} 项等待确认`:service.busy?'SideAI · 任务进行中':'SideAI');tray?.setImage(icon(waiting?'#e2b766':'#82c7b3'));});
  service.on('attention',()=>{tray?.setImage(icon('#e2b766'));if(!storage.state.settings.gameMode&&storage.state.settings.autoPeek){window.flashFrame(true);}});
  window.on('focus',()=>{window.flashFrame(false);sendFocus();});
  window.on('blur',()=>{if(!modal&&!storage.state.settings.pin&&!closing)hide(false);});
  window.on('close',e=>{if(!quitting){e.preventDefault();hide();}});
  const saveBounds=()=>{storage.state.settings.bounds=window.getBounds();storage.saveSoon();};window.on('moved',saveBounds);window.on('resized',saveBounds);
  screen.on('display-removed',()=>{window.setBounds(clampBounds(window.getBounds(),screen.getAllDisplays().map(d=>d.workArea)));positionHandle();});
  powerMonitor.on('lock-screen',()=>hide(false));powerMonitor.on('suspend',()=>hide(false));
  tray=new Tray(icon());tray.setToolTip('SideAI');tray.on('click',toggle);tray.setContextMenu(Menu.buildFromTemplate([{label:'显示 / 隐藏 SideAI',click:toggle},{label:'连接与设置',click:()=>{show();window.webContents.send('settings');}},{type:'separator'},{label:'退出',click:async()=>{
    if(service.busy){modal=true;const result=await dialog.showMessageBox(window,{type:'question',message:'还有任务在运行。退出会断开本客户端的后端连接，确定退出？',buttons:['继续运行','退出'],defaultId:0,cancelId:0});modal=false;if(result.response!==1)return;}quitting=true;app.quit();}}]));
  await window.loadFile(path.join(__dirname,'index.html'));show();
  if(lab)await gameLab();
  if(smoke){await new Promise(r=>setTimeout(r,800));const result=await window.webContents.executeJavaScript(`({title:document.title,composer:!!document.getElementById('composer'),bridge:typeof window.sideai?.call,body:document.body.innerText})`);if(!result.composer||result.bridge!=='function')throw Error('UI smoke test failed');if(process.platform==='win32'&&!native)throw Error('Win32 binding missing');console.log(JSON.stringify({smoke:'passed',platform:process.platform,native:!!native,...result}));quitting=true;app.quit();}
}
async function gameLab(){
  const game=new BrowserWindow({width:1100,height:760,title:'SideAI 游戏切换测试场',backgroundColor:'#121820',webPreferences:{sandbox:true,nodeIntegration:false,contextIsolation:true,partition:'sideai-game-lab'}});
  game.webContents.session.setPermissionRequestHandler((_w,permission,callback)=>callback(['pointerLock','fullscreen'].includes(permission)));
  await game.loadURL('data:text/html,'+encodeURIComponent(`<html><body style="background:#121820;color:#ddd;font:20px system-ui;padding:60px"><h1>游戏切换测试场</h1><p>这是窗口 / 鼠标锁定测试，不代表真实游戏或反作弊测试。</p><p>点击进入后，按 ${service.state.settings.hotkey} 唤出 SideAI；再按一次返回。</p><button id="go">全屏并锁定鼠标</button><p id="status"></p><pre id="events"></pre><script>let n=0;go.onclick=async()=>{await document.documentElement.requestFullscreen();document.body.requestPointerLock()};function log(s){events.textContent=(s+'\\n'+events.textContent).slice(0,2000)};onfocus=()=>log('游戏窗口获得焦点');onblur=()=>{document.exitPointerLock();log('游戏窗口失去焦点')};onkeydown=e=>log('游戏收到按键 '+e.code);document.onpointerlockchange=()=>document.getElementById('status').textContent=document.pointerLockElement?'鼠标已锁定':'鼠标已释放';</script></body></html>`));
}
app.on('second-instance',()=>show());app.on('window-all-closed',()=>{});
app.on('before-quit',()=>{quitting=true;if(cursorTimer)clearInterval(cursorTimer);if(returnTimer)clearTimeout(returnTimer);if(native&&lease){native.unregisterHotkey(lease.own.handle,1);native.unregisterHotkey(lease.own.handle,2);}globalShortcut.unregisterAll();service?.shutdown();});
app.whenReady().then(start).catch(e=>{console.error(safeError(e));if(!smoke)dialog.showErrorBox('SideAI 无法启动',safeError(e));app.exit(1);});
