const {test}=require('node:test');const assert=require('node:assert/strict');const {chat}=require('../dist/http');const {httpDiagnostic,HTTPChatFailure}=require('../dist/http-diagnostic');
test('diagnostic allowlist strips credentials, messages and query strings',()=>{
 const d=httpDiagnostic('https://api.openai.com/v1/responses?token=private-secret',200,new Headers({'Set-Cookie':'private-secret','retry-after':'120','x-ratelimit-reset-tokens':'6m0s'}),{type:'error',error:{code:'subscription_sharing_usage_limit_exceeded',type:'invalid_request_error',message:'private-secret',reset_after_seconds:120}});
 assert.equal(d.status,200);assert.equal(d.path,'/v1/responses');assert.equal(d.resetFields['retry-after'],'120');assert.equal(d.resetFields['x-ratelimit-reset-tokens'],'6m0s');assert.ok(!JSON.stringify(d).includes('private-secret'));
});
test('stream errors preserve actual HTTP status and missing reset fields',async()=>{
 const fetcher=async()=>new Response('data: '+JSON.stringify({type:'error',error:{type:'invalid_request_error',code:'subscription_sharing_usage_limit_exceeded',message:'private-secret'}})+'\n\n');
 await assert.rejects(chat(fetcher,{endpoint:'https://api.openai.com/v1',format:'responses'},{model:'fixture',items:[]},'private-secret',new AbortController().signal,()=>{}),e=>e instanceof HTTPChatFailure&&e.diagnostic.status===200&&e.diagnostic.errorCode==='subscription_sharing_usage_limit_exceeded'&&Object.keys(e.diagnostic.resetFields).length===0&&!e.message.includes('private-secret'));
});
