import {ChildProcess,execFile} from 'node:child_process';
import path from 'node:path';
/** Each official runtime and its children belong to a private kill-on-close job. */
export class ProcessTree {
  private job:any;private kernel:any;private closeHandle:any;
  constructor(private child:ChildProcess){
    if(process.platform!=='win32')return;
    const koffi=require('koffi');this.kernel=koffi.load('kernel32.dll');
    const create=this.kernel.func('uintptr_t __stdcall CreateJobObjectW(void *attributes, void *name)');
    const set=this.kernel.func('int __stdcall SetInformationJobObject(uintptr_t job, int infoClass, void *info, uint32_t length)');
    this.closeHandle=this.kernel.func('int __stdcall CloseHandle(uintptr_t handle)');
    this.job=create(null,null);
    // x64/arm64 JOBOBJECT_EXTENDED_LIMIT_INFORMATION, LimitFlags at offset 16.
    const info=Buffer.alloc(144);info.writeUInt32LE(0x2000,16); // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if(!this.job||!set(this.job,9,info,info.length)){if(this.job)this.closeHandle(this.job);this.job=undefined;}
    child.once('spawn',()=>{
      if(!this.job||!child.pid)return;
      const open=this.kernel.func('uintptr_t __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)');
      const assign=this.kernel.func('int __stdcall AssignProcessToJobObject(uintptr_t job, uintptr_t process)');
      const handle=open(0x101,0,child.pid); // SET_QUOTA | TERMINATE
      if(!handle||!assign(this.job,handle)){this.closeHandle(this.job);this.job=undefined;}
      if(handle)this.closeHandle(handle);
    });
    child.once('exit',()=>{if(this.job){this.closeHandle(this.job);this.job=undefined;}});
  }
  terminate(){
    if(this.job){this.closeHandle(this.job);this.job=undefined;return;}
    if(process.platform==='win32'&&this.child.pid&&this.child.exitCode===null&&this.child.signalCode===null){
      // Only the PID of this still-running child, never an image-name-wide kill.
      const executable=path.join(process.env.SystemRoot??'C:\\Windows','System32','taskkill.exe');
      execFile(executable,['/PID',String(this.child.pid),'/T','/F'],{windowsHide:true},()=>{});
    }else this.child.kill();
  }
}
