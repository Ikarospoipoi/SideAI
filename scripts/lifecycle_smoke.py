#!/usr/bin/env python3
"""Live crash/reconnect test, using only a disposable directory and child process."""
from protocol_smoke import Client
import json, os, pathlib, tempfile, time

cwd=tempfile.mkdtemp(prefix='sideai-crash-validation-')
target=os.path.join(cwd,'must-not-exist.txt')
c=Client(cwd)
report={'directory':cwd,'checks':{}}
try:
    tid=c.thread()['thread']['id']; pending=[]
    c.callback=lambda event:pending.append(event)
    turn=c.turn(tid,f'Permission integration test. Run exactly /usr/bin/touch {target} using the shell tool. Request elevated sandbox permission because the session is read-only. Do not touch any other file, and do not use alternatives if permission is denied.')
    deadline=time.monotonic()+90
    while not pending:c.event(c.q.get(timeout=max(.1,deadline-time.monotonic())))
    assert pending[0]['method'] in ['item/commandExecution/requestApproval','item/fileChange/requestApproval','item/permissions/requestApproval']
    assert not os.path.exists(target)
    # Kill this test's own backend with a live unanswered request. No approval is sent.
    c.p.kill();c.p.wait(timeout=5)
    report['checks']['crash_with_pending_request']=True
    c=Client(cwd)
    r=c.thread(tid)
    assert r['thread']['status']['type']!='active',r['thread']['status']
    assert not os.path.exists(target)
    report['checks']['resume_does_not_replay_write']=True
    report['resumed_status']=r['thread']['status']['type']
    turn=c.turn(tid,'不要使用工具。仅回复“连接已恢复”。')
    done=c.finish(tid,turn);assert done['status']=='completed'
    report['checks']['send_after_crash_resume']=True
    print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
finally:
    c.close()
    (pathlib.Path(__file__).resolve().parent.parent/'docs'/'lifecycle-validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
