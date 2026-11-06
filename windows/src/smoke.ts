import {BrowserWindow,app,nativeImage} from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {Service} from './service';
/** Runs only under --smoke-test, with a temporary data directory and no cloud calls. */
export async function smokeTest(window:BrowserWindow,service:Service){
  const evaluate=(code:string)=>window.webContents.executeJavaScript(code);
  const wait=async(expression:string)=>{const until=Date.now()+5000;while(Date.now()<until){if(await evaluate(expression))return;await new Promise(r=>setTimeout(r,30));}throw Error('UI assertion timed out: '+expression);};
  await wait("document.querySelector('#connections')?.innerText.includes('还没有连接')");
  const folder=process.env.SIDEAI_SMOKE_SCREENSHOT_DIR;
  if(folder){fs.mkdirSync(folder,{recursive:true});fs.writeFileSync(path.join(folder,'home.png'),(await window.webContents.capturePage()).toPNG());}
  const id=randomUUID();service.state.connections.push({id,name:'本地界面检查',provider:'openai',engine:'api',workspace:'chat',endpoint:'http://127.0.0.1:1',format:'responses',model:'fixture',models:[{id:'fixture',name:'Fixture',efforts:['low','high']}]});
  const c=service.newConversation(id);c.items=[{id:'fixture-user',role:'user',text:'界面回归检查',status:'completed'},{id:'fixture-answer',role:'assistant',text:'此内容仅用于界面测试，没有调用 AI。\n```text\ncode sample\n```',status:'completed'}];
  service.approvals.push({id:'fixture-approval',conversationID:c.id,method:'test',title:'待确认操作（测试）',detail:'No operation will be executed.',cwd:c.cwd,created:Date.now()});service.changed();
  await wait("document.querySelector('#approvals')?.innerText.includes('批准本次') && !document.getElementById('compose').hidden");
  await evaluate("document.getElementById('composer').focus()");
  const result=await evaluate("({title:document.title,composer:document.activeElement.id,bridge:typeof window.sideai.call,approvals:document.querySelectorAll('.approval').length,code:document.querySelector('#timeline code')?.textContent})");
  if(result.composer!=='composer'||result.bridge!=='function'||result.approvals!==1||!result.code?.includes('code sample'))throw Error('Chat UI smoke failed');
  const png=nativeImage.createFromBitmap(Buffer.alloc(4*4*4,255),{width:4,height:4}).toPNG();
  await evaluate(`window.sideai.call('imageBytes',{images:[{name:'fixture.png',bytes:new Uint8Array(${JSON.stringify([...png])})}]})`);
  await wait("document.querySelector('#draftImages img')?.src.startsWith('data:image/png;base64,')");
  service.changed();await new Promise(r=>setTimeout(r,80));
  if(!await evaluate("document.querySelector('#draftImages img')?.src.startsWith('data:image/png;base64,')"))throw Error('Image preview cache was lost after a state update');
  if(folder)fs.writeFileSync(path.join(folder,'chat.png'),(await window.webContents.capturePage()).toPNG());
  const npm=path.join(path.dirname(require.resolve('npm/package.json')),'bin','npm-cli.js').replace(/app\.asar([\\/])/,'app.asar.unpacked$1');let version='';
  await service.runtime.runProcess(process.execPath,[npm,'--version'],service.storage.root,service.runtime.env('codex',true),AbortSignal.timeout(30000),s=>version+=s);
  if(!/12\.2\.2/.test(version))throw Error('Bundled official-client installer failed: '+version.slice(0,100));
  console.log(JSON.stringify({smoke:'passed',platform:process.platform,packaged:app.isPackaged,installer:version.trim(),...result}));
}
