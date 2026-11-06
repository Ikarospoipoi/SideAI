#!/usr/bin/env python3
"""Opt-in live integration checks. Uses the official CLI login and account quota.
Never reads credential files. Only creates/modifies a new dedicated temp directory.
"""
import argparse, json, os, pathlib, queue, shutil, subprocess, threading, time, tempfile, re

class Client:
    def __init__(self, cwd):
        self.cwd = cwd
        cli = shutil.which('codex') or '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
        env=os.environ.copy()
        proxy_text=subprocess.check_output(['/usr/sbin/scutil','--proxy'],text=True)
        for scheme in ['HTTP','HTTPS']:
            host=re.search(r'\b'+scheme+r'Proxy : (\S+)',proxy_text);port=re.search(r'\b'+scheme+r'Port : (\d+)',proxy_text)
            if host and port and re.search(r'\b'+scheme+r'Enable : 1',proxy_text):env.setdefault(scheme+'_PROXY','http://'+host[1]+':'+port[1])
        self.p = subprocess.Popen([cli, 'app-server', '--listen', 'stdio://', '-c', 'analytics.enabled=false', '-c', 'features.apps=false', '-c', 'features.multi_agent=false'], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.q = queue.Queue(); self.seq = 0; self.events = []; self.callback = None
        def reader():
            for line in self.p.stdout:
                try: self.q.put(json.loads(line))
                except ValueError: self.q.put({'fatal':'invalid JSON'})
            self.q.put({'fatal':'server exited'})
        threading.Thread(target=reader, daemon=True).start()
        self.call('initialize', {'clientInfo':{'name':'sideai_validation','title':'SideAI Validation','version':'0.1.0'},'capabilities':{'experimentalApi':False}})
        self.send({'method':'initialized'})
        auth = self.call('account/read', {'refreshToken':False})
        if auth.get('requiresOpenaiAuth') and not auth.get('account'): raise RuntimeError('Official login required: codex login')
    def send(self, x): self.p.stdin.write(json.dumps(x)+'\n'); self.p.stdin.flush()
    def event(self,x):
        if 'fatal' in x: raise RuntimeError(x['fatal'])
        if 'method' in x:
            self.events.append(x)
            if x['method']=='error': print('Backend error:',x.get('params',{}),flush=True)
            if 'id' in x:
                if self.callback: self.callback(x)
                else: self.send({'id':x['id'], 'error':{'code':-32601,'message':'Unexpected request in smoke test'}})
    def call(self, method, params):
        self.seq += 1; i = self.seq; self.send({'id':i,'method':method,'params':params})
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            x = self.q.get(timeout=max(.1,deadline-time.monotonic()))
            if x.get('id')==i and 'method' not in x:
                if 'error' in x: raise RuntimeError(f'{method}: {x["error"]}')
                return x['result']
            self.event(x)
        raise TimeoutError(method)
    def thread(self, tid=None, approval='on-request'):
        params={'cwd':self.cwd,'sandbox':'read-only','approvalPolicy':approval,'approvalsReviewer':'user','config':{'features.apps':False,'features.multi_agent':False}}
        if tid: params['threadId']=tid
        r=self.call('thread/resume' if tid else 'thread/start',params)
        assert r['sandbox']['type']=='readOnly' and r['approvalsReviewer']=='user'
        return r
    def turn(self, tid, prompt):
        self.events=[]
        return self.call('turn/start', {'threadId':tid,'input':[{'type':'text','text':prompt}],'cwd':self.cwd,'sandboxPolicy':{'type':'readOnly','networkAccess':False},'approvalPolicy':'on-request','approvalsReviewer':'user'})['turn']['id']
    def finish(self, tid, turn, timeout=180):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            for x in self.events:
                if x.get('method')=='turn/completed' and x['params']['threadId']==tid and x['params']['turn']['id']==turn:
                    return x['params']['turn']
            self.event(self.q.get(timeout=max(.1,deadline-time.monotonic())))
        raise TimeoutError('turn completion')
    def close(self):
        self.p.terminate()
        try:self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:self.p.kill();self.p.wait()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--live',action='store_true');args=parser.parse_args()
    if not args.live: parser.error('--live is required; this uses your Codex quota')
    cwd=tempfile.mkdtemp(prefix='sideai-validation-'); print('Test directory:',cwd,flush=True)
    report={'cli':subprocess.check_output(['codex','--version'],text=True).strip(),'checks':{},'test_directory':cwd}
    c=Client(cwd)
    try:
        r=c.thread();tid=r['thread']['id']; report['model']=r['model']
        turn=c.turn(tid,'记住这个测试词：青松。仅回复“已记住青松”，不要使用任何工具。')
        done=c.finish(tid,turn); assert done['status']=='completed',done
        assert any(e.get('method')=='item/agentMessage/delta' for e in c.events)
        report['checks']['streaming']=True; print('PASS streaming',flush=True)
        c.close(); c=Client(cwd); resumed=c.thread(tid)
        history=c.call('thread/turns/list',{'threadId':tid,'itemsView':'full','sortDirection':'asc','limit':100})
        assert history['data']; report['checks']['restart_resume_history']=True
        turn=c.turn(tid,'刚才让你记住的测试词是什么？只回复那个词，不使用工具。');done=c.finish(tid,turn);assert done['status']=='completed'
        reply=''.join(e['params']['item'].get('text','') for e in c.events if e.get('method')=='item/completed' and e['params']['item']['type']=='agentMessage')
        assert '青松' in reply,reply
        report['checks']['multi_turn_context']=True; print('PASS restart / resume / multi-turn',flush=True)
        turn=c.turn(tid,'不使用工具，用中文写一篇很长的关于森林的散文，至少三千字。')
        deadline=time.monotonic()+30
        while not any(e.get('method')=='turn/started' and e['params']['turn']['id']==turn for e in c.events):
            c.event(c.q.get(timeout=max(.1,deadline-time.monotonic())))
        c.call('turn/interrupt',{'threadId':tid,'turnId':turn});done=c.finish(tid,turn);assert done['status']=='interrupted',done
        report['checks']['interrupt']=True;print('PASS interrupt',flush=True)
        for decision in ['accept','decline']:
            r=c.thread();aid=r['thread']['id']; target=os.path.join(cwd,decision+'.txt');seen=[]
            def callback(x):
                method=x['method'];p=x['params']
                assert p.get('threadId')==aid
                if method in ['item/commandExecution/requestApproval','item/fileChange/requestApproval']:
                    seen.append((x['id'],p['itemId']));c.send({'id':x['id'],'result':{'decision':decision}})
                    print('Approval:',method,decision,flush=True)
                elif method=='item/permissions/requestApproval':
                    seen.append((x['id'],p['itemId']));c.send({'id':x['id'],'result':{'permissions':p['permissions'] if decision=='accept' else {},'scope':'turn'}})
                else:c.send({'id':x['id'],'error':{'code':-32601,'message':'Unsupported in test'}})
            c.callback=callback
            prompt=f'This is a permission UI integration test in a disposable directory. Use the shell command tool to execute exactly: /usr/bin/touch {target}. The session is read-only, so request elevated sandbox permission for this write. Do not try alternatives if permission is rejected. Do not claim success unless the file was created. Do not touch any other path.'
            turn=c.turn(aid,prompt);done=c.finish(aid,turn,240)
            assert seen, 'No real approval event observed'
            exists=os.path.exists(target); assert exists==(decision=='accept'),(decision,exists)
            report['checks']['approval_'+decision]={'requests':len(seen),'file_created':exists,'turn_status':done['status']}
            print('PASS approval',decision,flush=True)
        c.callback=None
    finally:
        c.close()
        out=pathlib.Path(__file__).resolve().parent.parent/'docs'/'live-validation.json'
        out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('Report:',out,flush=True)
if __name__=='__main__':main()
