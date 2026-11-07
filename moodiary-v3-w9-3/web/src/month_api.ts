import {LanClient, LanApiError, validateRichDocument, newDiaryId, type JsonDoc} from './api'

export type MonthTopic = {id:string,title:string,months:string[],legacyCount:number}
export type MonthBlock = {
  blockId:string, revisionId:string, parentRevisionId:string|null,
  topicId:string, monthKey:string, kind:'entry'|'summary', dayKey:string|null,
  occurredAtMs:number, editedAtMs:number, document:JsonDoc, deleted:boolean,
}
export type MonthRevision = Pick<MonthBlock,
  'blockId'|'revisionId'|'parentRevisionId'|'kind'|'dayKey'|'occurredAtMs'|'document'|'deleted'> &
  {operationId:string}
export type MonthSnapshot = {
  schemaVersion:1,topicId:string,monthKey:string,syncState:'local_only',blocks:MonthBlock[],
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const ID = /^[a-zA-Z0-9_-]{8,120}$/
const object = (v:unknown):v is Record<string,unknown> =>
  !!v&&typeof v==='object'&&!Array.isArray(v)
function fail():never {throw new LanApiError('invalid_month_response',502)}
const copy = <T,>(v:T):T => JSON.parse(JSON.stringify(v))

export const validMonth = (s:string) => /^\d{4}-(0[1-9]|1[0-2])$/.test(s)&&!s.startsWith('0000')
export function validDay(s:string):boolean {
  if(!/^\d{4}-\d{2}-\d{2}$/.test(s)||!validMonth(s.slice(0,7)))return false
  const d = new Date(s+'T00:00:00Z')
  return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===s
}
export const localDay=(d=new Date())=>
  `${String(d.getFullYear()).padStart(4,'0')}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`
export const localClock=(d=new Date())=>
  `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`
export function eventTimeFromInputs(day:string,clock:string):number {
  if(!validDay(day)||!/^([01]\d|2[0-3]):[0-5]\d$/.test(clock))
    throw new LanApiError('invalid_record_time',422)
  const d=new Date(`${day}T${clock}:00`)
  if(!Number.isFinite(d.getTime())||localDay(d)!==day||localClock(d)!==clock)
    throw new LanApiError('invalid_record_time',422)
  return d.getTime()
}

function block(raw:unknown):MonthBlock {
  if(!object(raw)||typeof raw.blockId!=='string'||!ID.test(raw.blockId)||
    typeof raw.revisionId!=='string'||!ID.test(raw.revisionId)||
    (raw.parentRevisionId!==null&&(typeof raw.parentRevisionId!=='string'||!ID.test(raw.parentRevisionId)))||
    typeof raw.topicId!=='string'||!UUID.test(raw.topicId)||
    typeof raw.monthKey!=='string'||!validMonth(raw.monthKey)||
    (raw.kind!=='entry'&&raw.kind!=='summary')||typeof raw.deleted!=='boolean'||
    !Number.isSafeInteger(raw.occurredAtMs)||Number(raw.occurredAtMs)<0||
    !Number.isFinite(new Date(Number(raw.occurredAtMs)).getTime())||
    !Number.isSafeInteger(raw.editedAtMs))fail()
  if(raw.kind==='summary'?raw.dayKey!==null:
    typeof raw.dayKey!=='string'||!validDay(raw.dayKey)||!raw.dayKey.startsWith(raw.monthKey+'-'))fail()
  try{validateRichDocument(raw.document)}catch{fail()}
  return copy(raw as unknown as MonthBlock)
}

export class MonthApiClient extends LanClient {
  async topics():Promise<MonthTopic[]> {
    const result=await this.call<unknown>('/api/v3/topics')
    if(!object(result)||result.schemaVersion!==1||!Array.isArray(result.topics))fail()
    const seen=new Set<string>()
    return result.topics.map(t=>{
      if(!object(t)||typeof t.id!=='string'||!UUID.test(t.id)||seen.has(t.id)||
        typeof t.title!=='string'||!Array.isArray(t.months)||
        t.months.some(m=>typeof m!=='string'||!validMonth(m))||
        new Set(t.months).size!==t.months.length||
        !Number.isSafeInteger(t.legacyCount)||Number(t.legacyCount)<0)fail()
      seen.add(t.id)
      return copy(t as MonthTopic)
    })
  }
  async month(topicId:string,monthKey:string):Promise<MonthSnapshot> {
    if(!UUID.test(topicId)||!validMonth(monthKey))throw new LanApiError('invalid_month',422)
    const result=await this.call<unknown>(`/api/v3/months/${topicId}/${monthKey}?includeDeleted=true`)
    if(!object(result)||result.schemaVersion!==1||result.topicId!==topicId||
      result.monthKey!==monthKey||result.syncState!=='local_only'||!Array.isArray(result.blocks))fail()
    const blocks=result.blocks.map(block), ids=new Set<string>()
    for(const b of blocks){
      if(b.topicId!==topicId||b.monthKey!==monthKey||ids.has(b.blockId))fail()
      ids.add(b.blockId)
    }
    if(blocks.filter(b=>b.kind==='summary').length>1)fail()
    return {schemaVersion:1,topicId,monthKey,syncState:'local_only',blocks}
  }
  async append(topicId:string,monthKey:string,request:MonthRevision):Promise<MonthBlock> {
    if(!UUID.test(topicId)||!validMonth(monthKey))throw new LanApiError('invalid_month',422)
    validateRichDocument(request.document)
    const response=await this.call<unknown>(`/api/v3/months/${topicId}/${monthKey}/revisions`,'POST',request)
    if(!object(response)||response.state!=='saved_on_phone'||response.syncState!=='local_only')fail()
    const saved=block(response.block)
    if(saved.topicId!==topicId||saved.monthKey!==monthKey||saved.blockId!==request.blockId||
      saved.revisionId!==request.revisionId||saved.parentRevisionId!==request.parentRevisionId||
      saved.deleted!==request.deleted||saved.kind!==request.kind||saved.dayKey!==request.dayKey||
      saved.occurredAtMs!==request.occurredAtMs||
      JSON.stringify(saved.document)!==JSON.stringify(request.document))fail()
    return saved
  }
}

// The identical operation/revision/body survives an ambiguous network result.
// Never mint a second root or silently replace a conflicting parent on retry.
export class MonthWriteAttempt {
  private readonly payload:MonthRevision
  private saved:MonthBlock|null=null
  private current:'ready'|'saving'|'uncertain'|'conflict'|'rejected'|'saved'='ready'
  constructor(readonly topicId:string,readonly monthKey:string,request:MonthRevision){
    validateRichDocument(request.document)
    this.payload=copy(request)
  }
  get phase(){return this.current}
  exportDraft(){return copy({topicId:this.topicId,monthKey:this.monthKey,request:this.payload})}
  async commit(client:Pick<MonthApiClient,'append'>):Promise<MonthBlock>{
    if(this.saved)return copy(this.saved)
    if(this.current==='saving')throw new LanApiError('write_in_progress',409)
    if(this.current==='conflict'||this.current==='rejected')throw new LanApiError('write_rejected',409)
    const wasUncertain=this.current==='uncertain'
    this.current='saving'
    try{
      this.saved=await client.append(this.topicId,this.monthKey,copy(this.payload))
      this.current='saved'
      return copy(this.saved)
    }catch(e){
      this.current=wasUncertain||!(e instanceof LanApiError)||e.status>=500?
        'uncertain':e.status===409?'conflict':'rejected'
      throw e
    }
  }
}

export function newRevision(input:{kind:'entry'|'summary',document:JsonDoc,
  dayKey:string|null,occurredAtMs:number,previous?:MonthBlock,deleted?:boolean}):MonthRevision {
  return {operationId:newDiaryId(),blockId:input.previous?.blockId??newDiaryId(),
    revisionId:newDiaryId(),parentRevisionId:input.previous?.revisionId??null,
    kind:input.kind,dayKey:input.dayKey,occurredAtMs:input.occurredAtMs,
    document:copy(input.document),deleted:input.deleted??false}
}

export function chronologicalEntries(blocks:MonthBlock[]):MonthBlock[]{
  return blocks.filter(b=>b.kind==='entry'&&!b.deleted).sort((a,b)=>
    a.dayKey!.localeCompare(b.dayKey!)||a.occurredAtMs-b.occurredAtMs||a.blockId.localeCompare(b.blockId))
}
export function documentText(doc:JsonDoc):string {
  return doc.content.map(n=>(n.content??[]).map(p=>p.type==='hardBreak'?'\n':p.text??'').join('')).join('\n')
}
