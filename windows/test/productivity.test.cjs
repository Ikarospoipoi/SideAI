const {test}=require('node:test');const assert=require('node:assert/strict');
const {memoryHistory,readHistoryTool,planContext,planContextWithMemory,branch,transcript,enhancedConnection,searchHistory}=require('../dist/productivity');
const {chatWithHistory}=require('../dist/responses-memory');
const c=(id,cwd='C:\\Project')=>({id,connectionID:'api',title:id,draft:'',images:[],items:[{id:id+'-u',role:'user',text:'SELECT 用户名',status:'completed'}],cwd,mode:'project',model:'fixture',effort:'',status:'idle',updated:1});
const connection={id:'api',name:'Fixture',provider:'openai',engine:'api',workspace:'chat',format:'responses',endpoint:'https://example.test/v1',models:[]};
const stream=events=>new Response(events.map(e=>'data: '+JSON.stringify(e)+'\n\n').join(''));
test('history scope normalizes Windows paths and excludes private sources',()=>{
 const current=c('current'),same=c('same','c:/project/'),other=c('other','C:\\Elsewhere');
 assert.deepEqual(memoryHistory(current,[current,same,other]).map(x=>x.id),['same']);
 current.historyScope='selected';current.memorySourceIDs=['other'];assert.deepEqual(memoryHistory(current,[same,other]).map(x=>x.id),['other']);
 other.memoryExcluded=true;assert.equal(memoryHistory(current,[other]).length,0);
});
test('tools page readable text only and enforce scope on direct read',()=>{
 const current=c('current'),source=c('source');source.items.push({id:'tool',role:'tool',text:'hidden'});
 const result=readHistoryTool('read_history',JSON.stringify({conversation_id:'source',offset:0}),current,[source]);
 assert.match(result.sources[0].excerpt,/用户名/);assert.ok(!JSON.stringify(result).includes('hidden'));
 source.memoryExcluded=true;assert.throws(()=>readHistoryTool('read_history',JSON.stringify({conversation_id:'source',offset:0}),current,[source]));
 assert.throws(()=>readHistoryTool('read_history','{"offset":-1}',current,[source]));
});
test('budget keeps full latest turn and rejects oversized input without mutation',()=>{
 const current=c('current');current.contextBudget=4000;current.items=[{id:'old',role:'user',text:'旧'.repeat(2600)},{id:'answer',role:'assistant',text:'答'.repeat(500)},{id:'new',role:'user',text:'新'.repeat(500)}];
 assert.deepEqual(planContext(current).items.map(x=>x.id),['new']);assert.equal(current.items.length,3);
 current.items.at(-1).text='长'.repeat(5000);assert.throws(()=>planContext(current));
});
test('budget reserves attached memory and preserves configured limit for tool rounds',()=>{
 const current=c('current');current.contextBudget=4000;
 current.items=[{id:'old',role:'user',text:'旧'.repeat(1700)},{id:'latest',role:'user',text:'新'.repeat(300)}];
 const memory={sources:[],notes:'记'.repeat(1300)};
 assert.equal(planContext(current).items.length,2);
 const planned=planContextWithMemory(current,memory);assert.deepEqual(planned.items.map(i=>i.id),['latest']);assert.equal(planned.contextBudget,4000);
 assert.throws(()=>planContextWithMemory(current,{sources:[],notes:'长'.repeat(5000)}));assert.equal(current.items.length,2);
});
test('branch clears execution identity and export excludes tools',()=>{
 const source=c('source');source.threadID='existing';source.sessionID='old';source.items.push({id:'log',role:'tool',text:'secret'});
 const copy=branch(source,{...connection,engine:'codex'});assert.notEqual(copy.id,source.id);assert.equal(copy.threadID,undefined);assert.equal(copy.sessionID,undefined);assert.equal(copy.items.length,0);assert.ok(!transcript(source).includes('secret'));
 assert.equal(enhancedConnection({...connection,engine:'claude'},source),false);
 assert.equal(enhancedConnection(connection,{...source,model:'anthropic/claude-fixture'}),false);
});
test('full-text search returns original message identity',()=>{
 const source=c('source');const hits=searchHistory('select 用户名',[source]);assert.equal(hits[0].messageID,'source-u');assert.equal(searchHistory('select absent',[source]).length,0);
});
test('Responses history loop replays encrypted output and calls only allowed tools',async()=>{
 let rounds=0,calls=0;const requests=[];
 const fetcher=async(url,init)=>{requests.push(JSON.parse(init.body));rounds++;return rounds===1?stream([{type:'response.completed',response:{output:[{type:'reasoning',encrypted_content:'opaque'},{type:'function_call',namespace:'sideai_memory',name:'search_history',arguments:'{"query":"sql","offset":0}',call_id:'one'}]}}]):stream([{type:'response.output_text.delta',delta:'查到历史'},{type:'response.completed',response:{output:[]}}]);};
 const result=await chatWithHistory(fetcher,connection,c('current'),'fixture-key',new AbortController().signal,()=>{},{sources:[],notes:''},async()=>{calls++;return {sources:[]};});
 assert.equal(result,'查到历史');assert.equal(calls,1);assert.equal(rounds,2);assert.ok(requests[1].input.some(i=>i.encrypted_content==='opaque'));assert.ok(requests[1].input.some(i=>i.type==='function_call_output'));
});
test('truncated stream never executes tools and unknown tools are denied',async()=>{
 let calls=0;const call={type:'function_call',namespace:'other',name:'write_file',arguments:'{}',call_id:'one'};
 await assert.rejects(chatWithHistory(async()=>stream([{type:'response.output_item.done',item:call}]),connection,c('current'),'key',new AbortController().signal,()=>{},{sources:[],notes:''},async()=>{calls++;}));assert.equal(calls,0);
 let n=0;await chatWithHistory(async()=>++n===1?stream([{type:'response.completed',response:{output:[call]}}]):stream([{type:'response.output_text.delta',delta:'done'},{type:'response.completed',response:{output:[]}}]),connection,c('current'),'key',new AbortController().signal,()=>{},{sources:[],notes:''},async()=>{calls++;});assert.equal(calls,0);
});
test('cancelled history request never starts transport',async()=>{
 const controller=new AbortController();controller.abort();let calls=0;
 await assert.rejects(chatWithHistory(async()=>{calls++;return stream([]);},connection,c('current'),'key',controller.signal,()=>{},{sources:[],notes:''},async()=>({})));assert.equal(calls,0);
});
