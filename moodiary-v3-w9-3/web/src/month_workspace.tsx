import React,{useCallback,useEffect,useRef,useState} from 'react'
import {LanApiError,emptyDocument,type JsonDoc} from './api'
import {RichCanvas,RichPreview} from './rich_canvas'
import {MonthWriteAttempt,newRevision,chronologicalEntries,documentText,
  localDay,localClock,eventTimeFromInputs,validMonth,
  type MonthApiClient,type MonthTopic,type MonthSnapshot,type MonthBlock} from './month_api'
import './month.css'

type Draft={key:number,kind:'entry'|'summary',document:JsonDoc,day:string,clock:string,
  previous?:MonthBlock,intent:'edit'|'delete'|'restore',dirty:boolean}
const message=(e:unknown)=>e instanceof LanApiError?({
  stale_revision:'记录已有新版本。你的草稿已保留，请先导出草稿或重新读取。',
  summary_already_exists:'本月已有总结。草稿已保留，请读取现有总结后再编辑。',
  pairing_required:'手机授权已失效。请在配对页面重新授权后重试。',
  csrf_required:'手机授权已更新，请重新验证授权后重试。',
  session_revoked:'手机已撤销授权，请重新配对后重试。',
  topic_not_found:'主题已归档、删除或不可访问。当前草稿仍保留在此窗口。',
  invalid_record_time:'请选择有效的日期和时间。',
  blank_record:'请输入需要保存的内容。',
  invalid_month_response:'读取到的数据不完整或格式不兼容，已停止更改。',
  unsupported_rich_document:'当前内容包含暂不支持的格式，草稿仍保留。',
} as Record<string,string>)[e.code]??'未完成操作，请保留草稿并重试。':
  '连接中断，尚未确认保存。请重试同一次保存。'

export function MonthWorkspace({api,refreshTick,onLock}:{
  api:MonthApiClient,refreshTick:number,onLock:(locked:boolean)=>void,
}){
  const [topics,setTopics]=useState<MonthTopic[]|null>(null)
  const [topicId,setTopicId]=useState('')
  const [month,setMonth]=useState(localDay().slice(0,7))
  const [snapshot,setSnapshot]=useState<MonthSnapshot|null>(null)
  const [loading,setLoading]=useState(false)
  const [status,setStatus]=useState('正在读取手机中的长期主题…')
  const [query,setQuery]=useState('')
  const [limit,setLimit]=useState(50)
  const [draft,setDraft]=useState<Draft|null>(null)
  const [busy,setBusy]=useState(false)
  const [uncertain,setUncertain]=useState(false)
  const [conflict,setConflict]=useState(false)
  const [remoteChanged,setRemoteChanged]=useState(false)
  const draftRef=useRef<Draft|null>(null)
  const attemptRef=useRef<MonthWriteAttempt|null>(null)
  const busyRef=useRef(false)
  const selection=useRef({topicId:'',month})
  const readSeq=useRef(0),topicSeq=useRef(0),nonce=useRef(0),alive=useRef(true)
  const observedTick=useRef(false)
  const dialogRef=useRef<HTMLDivElement|null>(null)

  const replaceDraft=(next:Draft|null)=>{draftRef.current=next;setDraft(next)}
  const refreshTopics=useCallback(async()=>{
    const seq=++topicSeq.current
    try{
      const list=await api.topics()
      if(!alive.current||seq!==topicSeq.current)return
      setTopics(list)
      if(!selection.current.topicId&&list[0]){
        selection.current.topicId=list[0].id;setTopicId(list[0].id)
      }
      if(!list.length)setStatus('还没有长期主题。请先在手机中创建主题。')
    }catch(e){if(alive.current&&seq===topicSeq.current)setStatus(message(e))}
  },[api])

  const readSelection=useCallback(async(confirmedMessage?:string)=>{
    const chosen={...selection.current}
    if(!chosen.topicId||!validMonth(chosen.month))return
    if(draftRef.current||attemptRef.current){setRemoteChanged(true);return}
    const seq=++readSeq.current
    setLoading(true)
    try{
      const data=await api.month(chosen.topicId,chosen.month)
      if(!alive.current||seq!==readSeq.current||draftRef.current||attemptRef.current)return
      setSnapshot(data);setRemoteChanged(false)
      setStatus(confirmedMessage??'已从手机读取 · 这些月度记录目前仅保存在手机')
    }catch(e){if(alive.current&&seq===readSeq.current)setStatus(message(e))}
    finally{if(alive.current&&seq===readSeq.current)setLoading(false)}
  },[api])

  useEffect(()=>{alive.current=true;void refreshTopics();return()=>{
    alive.current=false;readSeq.current++;topicSeq.current++
  }},[refreshTopics])
  useEffect(()=>{void readSelection()},[topicId,month,readSelection])
  useEffect(()=>{
    if(!observedTick.current){observedTick.current=true;return}
    if(draftRef.current||attemptRef.current){setRemoteChanged(true);return}
    void refreshTopics();void readSelection()
  },[refreshTick,refreshTopics,readSelection])
  useEffect(()=>{onLock(!!draft);return()=>onLock(false)},[!!draft,onLock])
  useEffect(()=>{
    const leave=(e:BeforeUnloadEvent)=>{
      if(draftRef.current?.dirty||attemptRef.current){e.preventDefault();e.returnValue=''}
    }
    window.addEventListener('beforeunload',leave)
    return()=>window.removeEventListener('beforeunload',leave)
  },[])
  useEffect(()=>{
    if(draft)dialogRef.current?.focus()
  },[draft?.key])

  const topic=topics?.find(t=>t.id===topicId)
  const ready=!!topic&&snapshot?.topicId===topicId&&snapshot?.monthKey===month&&!loading
  const blocks=ready?snapshot!.blocks:[]
  const summary=blocks.find(b=>b.kind==='summary')
  const entries=chronologicalEntries(blocks)
  const filtered=entries.filter(b=>documentText(b.document).toLowerCase().includes(query.toLowerCase()))
  const deleted=blocks.filter(b=>b.deleted)
  const frozen=busy||uncertain||conflict

  function choose(nextTopic:string,nextMonth:string){
    if(draftRef.current||attemptRef.current)return
    ++readSeq.current;selection.current={topicId:nextTopic,month:nextMonth}
    setTopicId(nextTopic);setMonth(nextMonth);setQuery('');setLimit(50)
  }
  function open(kind:'entry'|'summary',previous?:MonthBlock,intent:Draft['intent']='edit'){
    if(!ready||draftRef.current||attemptRef.current)return
    ++readSeq.current;setLoading(false)
    const date=previous?new Date(previous.occurredAtMs):new Date()
    const day=previous?.dayKey??(localDay().startsWith(month)?localDay():month+'-01')
    replaceDraft({key:++nonce.current,kind,document:previous?.document??emptyDocument(),
      day,clock:localClock(date),previous,intent,dirty:false})
    setConflict(false);setUncertain(false)
  }
  function change(patch:Partial<Draft>){
    const active=draftRef.current
    if(!active||busyRef.current||attemptRef.current||conflict)return
    replaceDraft({...active,...patch,dirty:true})
    setStatus('未保存的编辑')
  }
  function close(){
    if(busyRef.current||attemptRef.current)return
    if(draftRef.current?.dirty&&!window.confirm('放弃当前未保存的草稿？'))return
    replaceDraft(null);setConflict(false);setUncertain(false)
    if(remoteChanged)void readSelection()
  }
  function exportDraft(){
    const data=attemptRef.current?.exportDraft()??{topicId,monthKey:month,draft:draftRef.current}
    const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}))
    const a=document.createElement('a');a.href=url;a.download='Moodiary-未保存草稿.json';a.click()
    setTimeout(()=>URL.revokeObjectURL(url),1000)
  }
  async function save(){
    const active=draftRef.current
    if(!active||busyRef.current||conflict)return
    busyRef.current=true;setBusy(true)
    let attempt=attemptRef.current
    try{
      if(!await api.session())throw new LanApiError('pairing_required',401)
      if(!attempt){
        const deleting=active.intent==='delete'
        if(!deleting&&!documentText(active.document).trim())throw new LanApiError('blank_record',422)
        const day=active.kind==='summary'?null:active.day
        const targetMonth=day?.slice(0,7)??month
        const unchangedTime=active.previous&&active.day===active.previous.dayKey&&
          active.clock===localClock(new Date(active.previous.occurredAtMs))
        const occurred=active.kind==='summary'?active.previous?.occurredAtMs??Date.now():
          deleting||unchangedTime?active.previous!.occurredAtMs:eventTimeFromInputs(active.day,active.clock)
        attempt=new MonthWriteAttempt(topicId,targetMonth,newRevision({
          kind:active.kind,document:active.document,dayKey:day,occurredAtMs:occurred,
          previous:active.previous,deleted:deleting,
        }))
        attemptRef.current=attempt
      }
      const saved=await attempt.commit(api)
      if(!alive.current)return
      attemptRef.current=null;replaceDraft(null);setUncertain(false);setConflict(false)
      const confirmed=saved.deleted?'已移入回收站，可在本月恢复':
        saved.monthKey!==month?`已保存到手机的 ${saved.monthKey}，当前仍停留在 ${month}`:'已保存到手机'
      setStatus(confirmed)
      await refreshTopics();await readSelection(confirmed)
    }catch(e){
      if(!alive.current)return
      if(attempt?.phase==='uncertain'||(attempt?.phase==='saving'&&attemptRef.current)){
        setUncertain(true)
      }else if(attempt?.phase==='conflict'){
        attemptRef.current=null;setConflict(true)
      }else if(attempt?.phase==='rejected')attemptRef.current=null
      // A session failure while retrying an uncertain request must not mint
      // new operation IDs: the first request may already have committed.
      if(attemptRef.current?.phase==='uncertain')setUncertain(true)
      setStatus(message(e))
    }finally{busyRef.current=false;if(alive.current)setBusy(false)}
  }
  async function reloadAfterConflict(){
    if(!window.confirm('当前草稿将被放弃。请先导出需要保留的内容，再确认读取手机最新版本。'))return
    attemptRef.current=null;replaceDraft(null);setConflict(false);setUncertain(false)
    await readSelection()
  }
  function dialogKey(e:React.KeyboardEvent){
    if(e.key==='Escape'){e.preventDefault();close()}
    if(e.key==='Tab'){
      const focusable=dialogRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),[contenteditable="true"],a[href]')
      if(!focusable?.length)return
      const first=focusable[0],last=focusable[focusable.length-1]
      if(e.shiftKey&&(document.activeElement===first||document.activeElement===dialogRef.current)){
        e.preventDefault();last.focus()
      }else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}
    }
    if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'){e.preventDefault();e.stopPropagation();void save()}
  }

  return <div className='month-layout'>
    <aside className='month-sidebar'>
      <div className='sidebar-top'><strong>我的长期记录</strong></div>
      <button className='secondary' disabled={!!draft} onClick={()=>{void refreshTopics();void readSelection()}}>刷新主题与记录</button>
      {topics===null?<p>正在读取主题…</p>:!topics.length?<p>请先在手机创建长期主题，再刷新此页。</p>:
        <div className='topic-list'>{topics.map(t=><button key={t.id}
          className={'note'+(t.id===topicId?' selected':'')} disabled={!!draft}
          onClick={()=>choose(t.id,month)}><strong>{t.title}</strong>
          <small>{t.months.length} 个已记录月份</small></button>)}</div>}
      <a href='/' target='_blank' rel='noopener noreferrer'>打开配对页面</a>
    </aside>
    <main className='month-main' aria-label='月度记录工作区'>
      <header className='month-heading'><div><p className='eyebrow'>长期记录</p><h1>{topic?.title??'选择一个主题'}</h1></div>
        <label>月份 <input aria-label='选择月份' type='month' min='0001-01' max='9999-12'
          value={month} disabled={!!draft} onChange={e=>choose(topicId,e.target.value)}/></label></header>
      {!!topic?.months.length&&<nav className='month-history' aria-label='已记录月份'>{topic.months.map(m=>
        <button key={m} className='secondary' disabled={!!draft} aria-pressed={month===m} onClick={()=>choose(topicId,m)}>{m}</button>)}</nav>}
      <div className='month-notice'>新月度记录目前仅保存在手机，尚未接入云端同步。请勿将本版作为唯一长期存档。</div>
      {!!topic?.legacyCount&&<p className='legacy-notice'>此主题另有 {topic.legacyCount} 条旧记录，仍可在手机原有页面查看；本页暂不合并显示。</p>}
      <div role='status' className={'save-state'+(conflict||uncertain?' alert':'')}>{loading?'正在读取手机记录…':status}</div>
      {remoteChanged&&!draft&&<button className='secondary' onClick={()=>void readSelection()}>读取最新记录</button>}
      <section className='month-summary' aria-label='本月总结'>
        {summary&&!summary.deleted?<details><summary>本月总结</summary><RichPreview document={summary.document}/>
          <div className='block-actions'><button className='secondary' onClick={()=>open('summary',summary)}>编辑总结</button>
            <button className='secondary' onClick={()=>open('summary',summary,'delete')}>删除总结</button></div></details>:
          <button className='secondary' disabled={!ready} onClick={()=>open('summary',summary,summary?'restore':'edit')}>
            {summary?'恢复并编辑本月总结':'添加本月总结'}</button>}
      </section>
      <div className='month-tools'><button className='primary' disabled={!ready} onClick={()=>open('entry')}>＋ 追加记录</button>
        <input className='search' aria-label='搜索本月记录' placeholder='搜索本月记录…' value={query}
          onChange={e=>{setQuery(e.target.value);setLimit(50)}}/><span>{entries.length} 条记录</span></div>
      {ready&&!filtered.length&&<p className='month-empty'>{entries.length?'本月没有匹配的记录。':'本月还没有记录，点击“追加记录”开始。'}</p>}
      <div className='month-timeline'>{filtered.slice(0,limit).map((b,i)=>
        <React.Fragment key={b.blockId}>
          {(i===0||filtered[i-1].dayKey!==b.dayKey)&&<h2 className='day-heading'>{b.dayKey}</h2>}
          <article className='month-block' data-block-id={b.blockId}>
            <header><time>{localClock(new Date(b.occurredAtMs))}</time><div className='block-actions'>
              <button className='secondary' onClick={()=>open('entry',b)}>编辑记录</button>
              <button className='secondary' onClick={()=>open('entry',b,'delete')}>删除记录</button></div></header>
            <RichPreview document={b.document}/>
          </article>
        </React.Fragment>)}</div>
      {filtered.length>limit&&<button className='secondary' onClick={()=>setLimit(n=>n+50)}>再显示 50 条</button>}
      <p className='subtle month-timezone'>日期按所选日期归档；时间按当前浏览器时区 {Intl.DateTimeFormat().resolvedOptions().timeZone} 显示。</p>
      {ready&&deleted.length>0&&<details className='month-trash'><summary>回收站 · {deleted.length} 条</summary>
        {deleted.map(b=><article key={b.blockId}><p>{b.kind==='summary'?'本月总结':b.dayKey} · {documentText(b.document).slice(0,100)}</p>
          <button className='secondary' onClick={()=>open(b.kind,b,'restore')}>恢复记录</button></article>)}</details>}
    </main>
    {draft&&<div className='month-modal-backdrop'><div className='month-dialog' role='dialog' aria-modal='true'
      aria-labelledby='month-dialog-title' tabIndex={-1} ref={dialogRef} onKeyDown={dialogKey}>
      <header><h2 id='month-dialog-title'>{draft.intent==='delete'?'删除记录':draft.intent==='restore'?'恢复记录':
        draft.kind==='summary'?'编辑本月总结':draft.previous?'编辑记录':'追加记录'}</h2>
        <button className='secondary' disabled={busy||!!attemptRef.current} onClick={close}>关闭</button></header>
      {draft.intent==='delete'&&<p>确认移入回收站？记录内容和修订历史会保留，可从本月回收站恢复。</p>}
      {draft.kind==='entry'&&<fieldset disabled={frozen||draft.intent==='delete'} className='record-time'>
        <label>事件日期 <input type='date' aria-label='事件日期' min='0001-01-01' max='9999-12-31'
          value={draft.day} onChange={e=>change({day:e.target.value})}/></label>
        <label>时间 <input type='time' aria-label='事件时间' value={draft.clock} onChange={e=>change({clock:e.target.value})}/></label>
      </fieldset>}
      {draft.intent==='delete'?<RichPreview document={draft.document}/>:
        <RichCanvas key={draft.key} initial={draft.document} onChange={document=>change({document})} disabled={frozen}/>}
      {remoteChanged&&<p className='month-notice'>手机记录有更新，当前编辑内容已保留。</p>}
      {uncertain&&<p className='alert' role='alert'>保存结果尚未确认。当前内容已锁定，重试会核对同一次保存，不会新建第二条。</p>}
      {conflict&&<p className='alert' role='alert'>版本冲突：草稿仍在此处，请先导出需要保留的内容，再读取最新版本。</p>}
      <p className='save-state' role='status'>{status}</p>
      <footer><button className='secondary' onClick={exportDraft}>导出当前草稿</button>
        <a className='secondary' href='/' target='_blank' rel='noopener noreferrer'>另开窗口配对</a>
        {conflict?<button className='primary' onClick={()=>void reloadAfterConflict()}>重新读取手机版本</button>:
          <button className='primary' disabled={busy} onClick={()=>void save()}>{busy?'保存中…':uncertain?'验证授权并重试保存':
            draft.intent==='delete'?'确认删除':draft.intent==='restore'?'恢复到手机':'保存到手机'}</button>}</footer>
    </div></div>}
  </div>
}
