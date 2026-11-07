// @vitest-environment jsdom
import {describe,it,expect,vi} from 'vitest'
import {LanApiError,emptyDocument} from './api'
import {MonthApiClient,MonthWriteAttempt,newRevision,eventTimeFromInputs,
  validDay,chronologicalEntries,type MonthBlock,type MonthRevision} from './month_api'

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2'
const month='2026-11'
const document={...emptyDocument(),content:[{type:'paragraph',content:[
  {type:'text',text:'午餐记录',marks:[{type:'bold'}]},
]}]}
const request=()=>newRevision({kind:'entry',document,dayKey:'2026-11-07',occurredAtMs:1794038400123})
const result=(r:MonthRevision):MonthBlock=>({...r,topicId:topic,monthKey:month,createdAtMs:1794038400000,editedAtMs:1794038500123})
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status})

describe('month transport and loss-safe operation retry',()=>{
  it('retries the exact immutable request after a lost successful acknowledgement',async()=>{
    const bodies:string[]=[],receipts=new Map<string,MonthBlock>()
    let lost=true
    const fetcher=vi.fn(async(url:RequestInfo|URL,options:RequestInit={})=>{
      if(String(url)==='/api/session')return json({authorized:true,csrf:'test-csrf'})
      expect((options.headers as Record<string,string>)['x-moodiary-csrf']).toBe('test-csrf')
      expect(options.credentials).toBe('same-origin')
      bodies.push(String(options.body))
      const body=JSON.parse(String(options.body)) as MonthRevision
      const saved=receipts.get(body.operationId)??result(body)
      receipts.set(body.operationId,saved)
      if(lost){lost=false;throw new TypeError('connection lost after commit')}
      return json({state:'saved_on_phone',syncState:'local_only',block:saved})
    })
    const api=new MonthApiClient(fetcher as typeof fetch);await api.session()
    const body=request(),attempt=new MonthWriteAttempt(topic,month,body)
    await expect(attempt.commit(api)).rejects.toThrow()
    expect(attempt.phase).toBe('uncertain')
    body.revisionId='mutated-after-send'
    body.document.content=[]
    await attempt.commit(api)
    expect(attempt.phase).toBe('saved')
    expect(bodies[0]).toBe(bodies[1]);expect(receipts.size).toBe(1)
    await attempt.commit(api)
    expect(bodies).toHaveLength(2)
  })
  it('does not rebase or auto-retry a conflict and retains the original parent/body',async()=>{
    const api=new MonthApiClient(vi.fn(async(url:RequestInfo|URL)=>
      String(url)==='/api/session'?json({authorized:true,csrf:'x'}):json({error:'stale_revision'},409)) as typeof fetch)
    await api.session()
    const body=request();body.parentRevisionId='parent-original-001'
    const attempt=new MonthWriteAttempt(topic,month,body)
    await expect(attempt.commit(api)).rejects.toMatchObject({status:409})
    expect(attempt.phase).toBe('conflict')
    expect(attempt.exportDraft().request.parentRevisionId).toBe('parent-original-001')
    await expect(attempt.commit(api)).rejects.toMatchObject({code:'write_rejected'})
  })
  it('treats a malformed successful reply as uncertain instead of acknowledging loss',async()=>{
    const api=new MonthApiClient(vi.fn(async(url:RequestInfo|URL)=>
      String(url)==='/api/session'?json({authorized:true,csrf:'x'}):json({state:'saved_on_phone',syncState:'local_only',block:{}})) as typeof fetch)
    await api.session();const attempt=new MonthWriteAttempt(topic,month,request())
    await expect(attempt.commit(api)).rejects.toMatchObject({status:502})
    expect(attempt.phase).toBe('uncertain')
  })
  it('keeps uncertainty when a subsequent retry is rejected after revocation',async()=>{
    const append=vi.fn().mockRejectedValueOnce(new TypeError('lost')).mockRejectedValueOnce(new LanApiError('pairing_required',401))
    const attempt=new MonthWriteAttempt(topic,month,request())
    await expect(attempt.commit({append})).rejects.toThrow()
    const original=attempt.exportDraft()
    await expect(attempt.commit({append})).rejects.toMatchObject({status:401})
    expect(attempt.phase).toBe('uncertain');expect(attempt.exportDraft()).toEqual(original)
  })
  it('refuses topic/month mismatches and incompatible snapshots rather than emptying the view',async()=>{
    const bad={schemaVersion:2,topicId:topic,monthKey:month,syncState:'local_only',blocks:[]}
    const api=new MonthApiClient(vi.fn(async()=>json(bad)) as typeof fetch)
    await expect(api.month(topic,month)).rejects.toMatchObject({status:502})
    bad.schemaVersion=1;bad.topicId='another-topic'
    await expect(api.month(topic,month)).rejects.toMatchObject({status:502})
  })
  it('validates the topic index and discovers existing months without a write',async()=>{
    const f=vi.fn(async()=>json({schemaVersion:1,topics:[{id:topic,title:'学习',months:['2026-11'],legacyCount:4}]}))
    const api=new MonthApiClient(f as typeof fetch)
    expect((await api.topics())[0].legacyCount).toBe(4)
    expect(f.mock.calls[0]).toBeDefined()
  })
})

describe('explicit calendar grouping',()=>{
  it('rejects impossible dates and time values',()=>{
    expect(validDay('2026-11-31')).toBe(false)
    expect(validDay('0000-01-01')).toBe(false)
    expect(validDay('2028-02-29')).toBe(true)
    expect(()=>eventTimeFromInputs('2026-11-31','08:00')).toThrow()
    expect(()=>eventTimeFromInputs('2026-11-07','24:00')).toThrow()
  })
  it('sorts explicit days and clocks, excluding summary and tombstones',()=>{
    const base=result(request())
    const a={...base,blockId:'block-before',dayKey:'2026-11-06',occurredAtMs:2000}
    const b={...base,blockId:'block-later',dayKey:'2026-11-07',occurredAtMs:1000}
    expect(chronologicalEntries([b,{...b,kind:'summary'},a,{...a,deleted:true}]).map(v=>v.blockId))
      .toEqual(['block-before','block-later'])
  })
  it('uses creation time before ID for equal events and rejects missing creation metadata',async()=>{
    const base=result(request())
    const a={...base,blockId:'a-newer-block',createdAtMs:200,editedAtMs:1}
    const z={...base,blockId:'z-older-block',createdAtMs:100,editedAtMs:99999}
    expect(chronologicalEntries([a,z]).map(b=>b.blockId)).toEqual(['z-older-block','a-newer-block'])
    for(const createdAtMs of [undefined,-1,1.5]){
      const api=new MonthApiClient(vi.fn(async()=>json({schemaVersion:1,topicId:topic,monthKey:month,syncState:'local_only',blocks:[{...base,createdAtMs}]})) as typeof fetch)
      await expect(api.month(topic,month)).rejects.toMatchObject({status:502})
    }
  })

})
