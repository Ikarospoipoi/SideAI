import {contextBridge,ipcRenderer} from 'electron';
contextBridge.exposeInMainWorld('sideai',{
  call:async(method:string,params?:unknown)=>{const result=await ipcRenderer.invoke('sideai',method,params);if(!result.ok)throw Error(result.error);return result.value;},
  onState:(callback:(s:unknown)=>void)=>{ipcRenderer.on('state',(_e,s)=>callback(s));},
  onFocus:(callback:()=>void)=>{ipcRenderer.on('focus-composer',callback);},
  onSettings:(callback:()=>void)=>{ipcRenderer.on('settings',callback);}
});
