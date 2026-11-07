// Real production-bundle acceptance against explicit API protocol fixtures.
// Native HTTP/SQLite authentication and transactions are tested by Flutter.
const assert=require('node:assert/strict')
const http=require('node:http')
const fs=require('node:fs')
const path=require('node:path')
const {chromium}=require(process.env.MOODIARY_PLAYWRIGHT_MODULE||
  path.join(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES,'playwright'))
const bundle=path.resolve(process.argv[2])
const screenshotDir=process.argv[3]
const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2'
const diary='bac26e25-4a1d-4b4c-b256-9b0c347d36e2'
const doc=text=>({type:'doc',attrs:{v:2},content:[{type:'paragraph',content:[{type:'text',text}]}]})
const text=d=>d.content.map(n=>(n.content||[]).map(p=>p.text||'').join('')).join('\n')
const blocks=new Map([['block-initial-001',{
  blockId:'block-initial-001',revisionId:'revision-initial-001',parentRevisionId:null,
  topicId:topic,monthKey:'2026-11',kind:'entry',dayKey:'2026-11-07',
  occurredAtMs:Date.parse('2026-11-07T08:20:30.123Z'),editedAtMs:1794040000000,
  document:doc('原有月度记录'),deleted:false,
}]])
const receipts=new Map(),monthPages=new Set(['2026-11']),posts=[],sockets=[]
let lostNext=false,conflictNext=false,ordinaryDoc=doc('原有普通日记'),ordinaryTitle='已有普通日记'
const failures=[],requestTrace=[]
let server,browser,context,activePage
const wait=async(condition,label)=>{
  for(let i=0;i<100;i++){if(await condition())return;await new Promise(r=>setTimeout(r,50))}
  throw new Error('Timed out: '+label)
}
const checks=[]

;(async()=>{
  server=http.createServer((req,res)=>{
    let file=req.url.split('?')[0].split('/').pop()||'index.html'
    if(!['index.html','lan.js','lan.css'].includes(file)){res.writeHead(404);res.end();return}
    res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html')
    res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' ws://127.0.0.1:*; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    res.end(fs.readFileSync(path.join(bundle,file)))
  })
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
  browser=await chromium.launch({headless:true,
    ...(process.env.MOODIARY_CHROME?{executablePath:process.env.MOODIARY_CHROME}:{}),
    args:['--no-sandbox','--disable-dev-shm-usage']})
  context=await browser.newContext({viewport:{width:1360,height:920},timezoneId:'Asia/Shanghai'})
  const page=await context.newPage()
  activePage=page
  page.on('pageerror',e=>failures.push(e.message))
  page.on('console',m=>{if(m.type()==='error'&&/Content Security Policy|Refused to/.test(m.text()))failures.push(m.text())})
  page.on('dialog',d=>d.accept())
  await page.routeWebSocket('**/api/events*',socket=>{
    sockets.push(socket)
    socket.send(JSON.stringify({type:'reset',epoch:'browser-test',sequence:0}))
  })
  await page.route('**/api/**',async route=>{
    const req=route.request(),url=new URL(req.url()),p=url.pathname
    requestTrace.push(req.method()+' '+p)
    const send=(body,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify(body)})
    if(p==='/api/session')return send({authorized:true,csrf:'browser-test-csrf'})
    if(p==='/api/diaries')return send({items:[{id:diary,title:ordinaryTitle,preview:text(ordinaryDoc),date:'2026-11-07T08:00:00Z'}]})
    if(p===`/api/rich/diaries/${diary}`){
      if(req.method()==='PUT'){
        const b=req.postDataJSON();ordinaryDoc=b.document;ordinaryTitle=b.title
      }
      return send({id:diary,title:ordinaryTitle,text:text(ordinaryDoc),revision:'a'.repeat(64),editable:true,document:ordinaryDoc})
    }
    if(p==='/api/v3/topics')return send({schemaVersion:1,topics:[{id:topic,title:'日常记录',months:[...monthPages].sort().reverse(),legacyCount:2}]})
    const match=p.match(/^\/api\/v3\/months\/([^/]+)\/(\d{4}-\d{2})(\/revisions)?$/)
    if(!match)return send({error:'not_found'},404)
    const key=match[2]
    if(req.method()==='GET')return send({schemaVersion:1,topicId:topic,monthKey:key,syncState:'local_only',
      blocks:[...blocks.values()].filter(b=>b.monthKey===key)})
    assert.equal(req.headers()['x-moodiary-csrf'],'browser-test-csrf')
    const body=req.postDataJSON();posts.push(JSON.stringify(body))
    const receipt=receipts.get(body.operationId)
    if(receipt){
      assert.equal(receipt.payload,JSON.stringify(body));assert.equal(receipt.month,key)
      return send({state:'saved_on_phone',syncState:'local_only',block:receipt.block})
    }
    const prior=blocks.get(body.blockId)
    if(conflictNext){
      conflictNext=false
      blocks.set(prior.blockId,{...prior,revisionId:'revision-remote-999',document:doc('手机端的新版本')})
      return send({error:'stale_revision'},409)
    }
    if(prior&&prior.revisionId!==body.parentRevisionId)return send({error:'stale_revision'},409)
    if(body.kind==='summary'&&!prior&&[...blocks.values()].some(b=>b.monthKey===key&&b.kind==='summary'))
      return send({error:'summary_already_exists'},409)
    const saved={...body,topicId:topic,monthKey:key,editedAtMs:Date.now()}
    blocks.set(body.blockId,saved);monthPages.add(key)
    receipts.set(body.operationId,{payload:JSON.stringify(body),month:key,block:saved})
    if(lostNext){lostNext=false;return route.abort('failed')}
    return send({state:'saved_on_phone',syncState:'local_only',block:saved})
  })
  await page.goto(`http://127.0.0.1:${server.address().port}/lan-editor/`)
  await page.getByRole('button',{name:'已有普通日记'}).click()
  await page.locator('.tiptap-area[contenteditable=true]').fill('普通日记仍可编辑')
  await page.getByRole('button',{name:'保存到手机',exact:true}).click()
  await wait(()=>text(ordinaryDoc)==='普通日记仍可编辑','ordinary save')
  checks.push('ordinary editor retains its existing save flow')
  await page.getByRole('button',{name:'长期记录',exact:true}).click()
  await page.getByLabel('选择月份').fill('2026-11')
  await page.getByText('原有月度记录',{exact:true}).waitFor()
  assert.match(await page.locator('.legacy-notice').innerText(),/2 条旧记录/)
  checks.push('topic/month discovery and old-record boundary')

  await page.getByRole('button',{name:'＋ 追加记录'}).click()
  let dialog=page.getByRole('dialog')
  await dialog.getByLabel('事件日期').fill('2026-11-08')
  await dialog.getByLabel('事件时间').fill('08:30')
  await dialog.locator('.tiptap-area[contenteditable=true]').fill('早餐与工作记录')
  await dialog.locator('.tiptap-area').press('Control+a')
  await dialog.getByRole('button',{name:'粗体',exact:true}).click()
  for(const socket of sockets)socket.send(JSON.stringify({type:'invalidate',epoch:'browser-test',sequence:1,id:topic,kind:'updated'}))
  await dialog.getByText('手机记录有更新，当前编辑内容已保留。').waitFor()
  assert.equal(await dialog.locator('.tiptap-area').innerText(),'早餐与工作记录')
  checks.push('actual Tiptap formatting and invalidation preserve draft')
  lostNext=true
  await dialog.getByRole('button',{name:'保存到手机',exact:true}).click()
  await dialog.getByRole('alert').waitFor()
  await wait(async()=>await dialog.locator('.tiptap-area').getAttribute('contenteditable')==='false','editor locked after uncertain write')
  const sent=posts.at(-1)
  await dialog.getByRole('button',{name:'验证授权并重试保存'}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  assert.equal(posts.at(-1),sent)
  assert.equal([...blocks.values()].filter(b=>text(b.document)==='早餐与工作记录').length,1)
  const created=[...blocks.values()].find(b=>text(b.document)==='早餐与工作记录')
  assert(created.document.content[0].content[0].marks.some(m=>m.type==='bold'))
  assert.equal(await page.getByLabel('选择月份').inputValue(),'2026-11')
  await page.locator(`[data-block-id="${created.blockId}"] strong`).filter({hasText:'早餐与工作记录'}).waitFor()
  checks.push('lost acknowledgement retries identical request with one block and rich formatting')

  await page.locator(`[data-block-id="${created.blockId}"]`).getByRole('button',{name:'编辑记录'}).click()
  dialog=page.getByRole('dialog')
  await dialog.getByLabel('事件日期').fill('2026-12-02')
  await dialog.getByRole('button',{name:'保存到手机',exact:true}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  assert.equal(blocks.get(created.blockId).monthKey,'2026-12')
  assert.equal(await page.getByLabel('选择月份').inputValue(),'2026-11')
  await page.getByRole('button',{name:'2026-12',exact:true}).click()
  await page.locator(`[data-block-id="${created.blockId}"]`).waitFor()
  checks.push('cross-month edit retains identity and original view until explicit navigation')

  await page.locator(`[data-block-id="${created.blockId}"]`).getByRole('button',{name:'删除记录'}).click()
  await page.getByRole('dialog').getByRole('button',{name:'确认删除'}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  assert.equal(blocks.get(created.blockId).deleted,true)
  await page.locator('.month-trash summary').click()
  await page.locator('.month-trash').getByRole('button',{name:'恢复记录'}).click()
  await page.getByRole('dialog').getByRole('button',{name:'恢复到手机'}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  assert.equal(blocks.get(created.blockId).deleted,false)
  checks.push('soft delete and restore reuse identity')

  await page.getByRole('button',{name:'添加本月总结'}).click()
  await page.getByRole('dialog').locator('.tiptap-area[contenteditable=true]').fill('十二月总结')
  await page.getByRole('dialog').getByRole('button',{name:'保存到手机',exact:true}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  assert.equal([...blocks.values()].filter(b=>b.kind==='summary'&&b.monthKey==='2026-12').length,1)
  assert.equal(await page.locator('.month-summary details').getAttribute('open'),null)
  checks.push('one collapsed summary per month')

  await page.locator(`[data-block-id="${created.blockId}"]`).getByRole('button',{name:'编辑记录'}).click()
  await page.getByRole('dialog').locator('.tiptap-area[contenteditable=true]').fill('发生冲突后保留的草稿')
  conflictNext=true;const before=posts.length
  await page.getByRole('dialog').getByRole('button',{name:'保存到手机',exact:true}).click()
  await page.getByRole('dialog').getByRole('alert').waitFor()
  assert.equal(await page.getByRole('dialog').locator('.tiptap-area').innerText(),'发生冲突后保留的草稿')
  assert.equal(posts.length,before+1)
  assert.equal(text(blocks.get(created.blockId).document),'手机端的新版本')
  const [download]=await Promise.all([
    page.waitForEvent('download'),page.getByRole('button',{name:'导出当前草稿'}).click(),
  ])
  let exported=''
  for await(const chunk of await download.createReadStream())exported+=chunk.toString()
  assert.equal(text(JSON.parse(exported).draft.document),'发生冲突后保留的草稿')
  await page.getByRole('button',{name:'重新读取手机版本'}).click()
  await page.getByRole('dialog').waitFor({state:'detached'})
  await page.getByText('手机端的新版本',{exact:true}).waitFor()
  checks.push('409 preserves and exports draft without rebase or automatic overwrite')

  if(screenshotDir){fs.mkdirSync(screenshotDir,{recursive:true});await page.screenshot({path:path.join(screenshotDir,'month-desktop.png'),fullPage:true})}
  await page.setViewportSize({width:390,height:844})
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'mobile horizontal overflow')
  if(screenshotDir)await page.screenshot({path:path.join(screenshotDir,'month-mobile.png'),fullPage:true})
  await page.getByRole('button',{name:'＋ 追加记录'}).click()
  await page.getByRole('dialog').locator('.tiptap-area[contenteditable=true]').fill('手机宽度草稿')
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'mobile modal horizontal overflow')
  if(screenshotDir)await page.screenshot({path:path.join(screenshotDir,'month-modal.png'),fullPage:true})
  checks.push('mobile viewport and dialog have no horizontal overflow')
  assert.deepEqual(failures,[],'JavaScript/CSP failures')
  console.log(JSON.stringify({status:'passed',checks,posts:posts.length,blocks:blocks.size}))
})().catch(async e=>{
  console.error(e.stack);process.exitCode=1
  console.error(JSON.stringify({failures,requestTrace,checks}))
  if(activePage&&screenshotDir){
    try{fs.mkdirSync(screenshotDir,{recursive:true});await activePage.screenshot({path:path.join(screenshotDir,'failure.png'),fullPage:true})}catch{}
  }
}).finally(async()=>{
  if(context)await context.close()
  if(browser)await browser.close()
  if(server)await new Promise(resolve=>server.close(resolve))
})
