import React, { useCallback, useEffect, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import {RichCanvas} from './rich_canvas'
import {MonthApiClient} from './month_api'
import {MonthWorkspace} from './month_workspace'
import {
  LanClient, LanApiError, emptyDocument, newDiaryId,
  validateRichDocument, canApplyRemoteRead,
  type JsonDoc, type RichNote, type DiaryPreview,
} from './api'
import './style.css'

type OpenNote = RichNote & { loadId: number }
const api = new MonthApiClient()
const msg = (e: unknown) => e instanceof LanApiError ?
  ({
    stale_revision: '手机端版本已改变：为保护草稿，已暂停覆盖保存。',
    unsupported_rich_document: '此文档包含尚未支持的格式，已拒绝覆盖。',
    pairing_required: '手机授权会话已失效，请重新配对。',
    unsafe_link: '链接地址不安全。',
  } as Record<string,string>)[e.code] ?? '请求失败：'+e.code :
  '网络不可用，尚未确认保存，请检查连接。'


function App(){
  const [authorized,setAuthorized]=useState<boolean|null>(null)
  const [items,setItems]=useState<DiaryPreview[]>([])
  const [current,setCurrent]=useState<OpenNote|null>(null)
  const [title,setTitle]=useState('')
  const [busy,setBusy]=useState(false)
  const [dirty,setDirty]=useState(false)
  const [connected,setConnected]=useState(false)
  const [status,setStatus]=useState('手机已保存的数据将在这里显示')
  const [section,setSection]=useState<'ordinary'|'monthly'>('ordinary')
  const [monthLocked,setMonthLocked]=useState(false)
  const [monthRefresh,setMonthRefresh]=useState(0)
  const [query,setQuery]=useState('')
  const noteRef=useRef<OpenNote|null>(null)
  const titleRef=useRef('')
  const docRef=useRef<JsonDoc>(emptyDocument())
  const dirtyRef=useRef(false)
  const savingRef=useRef(false)
  const conflictRef=useRef(false)
  const generationRef=useRef(0)
  const openSequence=useRef(0)
  const autoTimer=useRef<ReturnType<typeof setTimeout>|null>(null)
  const loadedNonce=useRef(0)
  const eventsEpoch=useRef('')
  const eventsSeq=useRef(0)

  function discardAutosave(){
    if(autoTimer.current!==null)clearTimeout(autoTimer.current)
    autoTimer.current=null
  }
  function setUncommitted(value:boolean) {
    dirtyRef.current=value;setDirty(value)
  }
  const refreshList = useCallback(async()=>{
    try {setItems(await api.list())} catch(e) {setStatus(msg(e))}
  },[])

  const loadNote = useCallback(async(id:string,force=false)=>{
    if (savingRef.current){setStatus('正在保存，请完成后再切换');return}
    if (!force && dirtyRef.current && !window.confirm('存在未保存修改，确定放弃本地草稿？')) return
    discardAutosave()
    const seq=++openSequence.current
    const editGenerationAtRequest=generationRef.current
    try {
      const result=await api.read(id)
      // A remote refresh may finish AFTER the user typed new local content.
      // Never replace a newer dirty draft with an older server response.
      if (!canApplyRemoteRead(seq,openSequence.current,
          editGenerationAtRequest,generationRef.current,dirtyRef.current)) {
        setStatus('读取期间发生新编辑，已保留本地草稿并忽略过期响应')
        return
      }
      conflictRef.current=false
      setUncommitted(false)
      const note={...result,loadId:++loadedNonce.current}
      noteRef.current=note
      docRef.current=result.document??emptyDocument()
      titleRef.current=result.title
      setTitle(result.title);setCurrent(note)
      setStatus(result.editable?'可以编辑，停止输入后自动保存':'该日记包含不支持的节点或媒体，保持只读')
    } catch(e){setStatus(msg(e))}
  },[])

  function newNote(){
    if (savingRef.current){setStatus('保存进行中，不允许新建');return}
    if (dirtyRef.current && !window.confirm('存在未保存修改，确定放弃本地草稿？'))return
    discardAutosave();++openSequence.current
    const fresh:OpenNote={id:newDiaryId(),title:'',text:'',revision:'',editable:true,document:emptyDocument(),loadId:++loadedNonce.current}
    noteRef.current=fresh;docRef.current=fresh.document!;titleRef.current=''
    conflictRef.current=false;setUncommitted(false)
    setTitle('');setCurrent(fresh);setStatus('新的日记尚未保存到手机')
  }

  async function save(){
    const active=noteRef.current
    if(!active||!active.editable||savingRef.current||!dirtyRef.current||conflictRef.current)return
    discardAutosave()
    savingRef.current=true;setBusy(true)
    const before=generationRef.current
    const snapshot={id:active.id,title:titleRef.current,document:docRef.current,
      revision:active.revision||null}
    try {
      validateRichDocument(snapshot.document)
      const result=await api.save(snapshot)
      if(noteRef.current?.id!==snapshot.id)return
      const next={...noteRef.current,revision:result.revision}
      noteRef.current=next
      if(before===generationRef.current){
        setUncommitted(false)
        setStatus('已保存到手机 · 云端 WebDAV 状态独立')
      } else {
        setUncommitted(true)
        setStatus('此前内容已保存，期间的新输入尚待保存')
      }
      void refreshList()
    }catch(e){
      setUncommitted(true)
      if(e instanceof LanApiError && e.status===409)conflictRef.current=true
      setStatus(msg(e))
    }finally{
      savingRef.current=false;setBusy(false)
      if(dirtyRef.current&&!conflictRef.current)queueSave()
    }
  }
  function queueSave(){
    discardAutosave()
    if(conflictRef.current||!dirtyRef.current)return
    autoTimer.current=setTimeout(()=>{
      if(savingRef.current)queueSave()
      else void save()
    },2000)
  }
  function editTitle(value:string){
    titleRef.current=value;setTitle(value)
    generationRef.current++;setUncommitted(true)
    setStatus('未保存的编辑');queueSave()
  }
  function editDoc(value:JsonDoc){
    docRef.current=value
    generationRef.current++;setUncommitted(true)
    setStatus('未保存的编辑');queueSave()
  }

  useEffect(()=>{
    let live=true
    api.session().then(ok=>{
      if(!live)return
      setAuthorized(ok)
      if(ok)void refreshList()
    }).catch(()=>{if(live)setAuthorized(false)})
    return ()=>{live=false}
  },[refreshList])

  useEffect(()=>{
    if(!authorized)return
    let closed=false
    let socket:WebSocket|null=null
    let backoff=400
    let reconnect:ReturnType<typeof setTimeout>|null=null
    let heartbeat:ReturnType<typeof setInterval>|null=null
    async function syncOpen(changedId?:string){
      setMonthRefresh(n=>n+1)
      await refreshList()
      const note=noteRef.current
      if (!note|| (changedId&&changedId!==note.id))return
      // A local browser save emits the same event before its HTTP response.
      // CAS resolves competing writes; never misclassify that event as conflict.
      if(savingRef.current)return
      if(dirtyRef.current){
        // Our own committed event may arrive after the save acknowledgment
        // while the user has already started typing the next edit.
        // Only a DIFFERENT authoritative revision is a real conflict.
        if(!note.revision)return // Unsaved new document has no remote row.
        let changed=true
        try{
          const latest=await api.read(note.id)
          changed=latest.revision!==noteRef.current?.revision
        }catch{
          // Missing or inaccessible remote state is unsafe to overwrite.
        }
        if(!changed || noteRef.current?.id!==note.id)return
        conflictRef.current=true;discardAutosave()
        setStatus('手机端已有新版本：本地草稿已保留，需先处理版本冲突')
        return
      }
      if(!note.revision)return // New, not-yet-committed document.
      await loadNote(note.id,true)
    }
    function connect(){
      if(closed)return
      const params=new URLSearchParams()
      if(eventsEpoch.current){
        params.set('epoch',eventsEpoch.current)
        params.set('since',String(eventsSeq.current))
      }
      const wsurl=`ws://${window.location.host}/api/events${params.size?'?'+params.toString():''}`
      socket=new WebSocket(wsurl)
      socket.onopen=()=>{
        if(closed)return
        setConnected(true);backoff=400
        heartbeat=setInterval(()=>{
          if(socket?.readyState===WebSocket.OPEN)socket.send('ping')
        },20000)
      }
      socket.onmessage=event=>{
        try{
          const data=JSON.parse(event.data)
          if(data.type==='reset'){
            eventsEpoch.current=data.epoch
            eventsSeq.current=Number(data.sequence)||0
            void syncOpen()
          }else if(data.type==='invalidate'){
            const n=Number(data.sequence)||0
            if(data.epoch!==eventsEpoch.current||n!==eventsSeq.current+1){
              eventsEpoch.current=data.epoch;eventsSeq.current=n
              void syncOpen()
            }else{
              eventsSeq.current=n;void syncOpen(data.id)
            }
          }
        }catch{void syncOpen()}
      }
      socket.onclose=()=>{
        setConnected(false)
        if(heartbeat)clearInterval(heartbeat)
        heartbeat=null
        if(!closed){reconnect=setTimeout(connect,backoff);backoff=Math.min(10000,backoff*2)}
      }
      socket.onerror=()=>socket?.close()
    }
    connect()
    return ()=>{
      closed=true
      if(reconnect)clearTimeout(reconnect)
      if(heartbeat)clearInterval(heartbeat)
      socket?.close()
      setConnected(false)
    }
  },[authorized,refreshList,loadNote])

  useEffect(()=>{
    const listener=(e:KeyboardEvent)=>{
      if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='s'){
        e.preventDefault();void save()
      }
    }
    const leaving=(e:BeforeUnloadEvent)=>{
      if(dirtyRef.current){e.preventDefault();e.returnValue=''}
    }
    window.addEventListener('keydown',listener)
    window.addEventListener('beforeunload',leaving)
    return ()=>{
      window.removeEventListener('keydown',listener)
      window.removeEventListener('beforeunload',leaving)
      discardAutosave()
    }
  },[])

  function switchSection(next:'ordinary'|'monthly'){
    if(next===section||monthLocked)return
    if(savingRef.current){setStatus('正在保存，请完成后再切换');return}
    if(dirtyRef.current){
      if(!window.confirm('存在未保存修改，确定放弃本地草稿？'))return
      discardAutosave();++openSequence.current;setUncommitted(false)
      noteRef.current=null;setCurrent(null)
    }
    setSection(next)
  }

  if(authorized===null)return <main className="center">正在验证手机授权…</main>
  if(!authorized)return <main className="center"><h1>Moodiary Web</h1>
    <p>请先在手机端批准连接，再打开富文本工作台。</p>
    <a href="/">返回手机配对页面</a></main>

  const showing=items.filter(x=>
    (x.title+' '+x.preview).toLowerCase().includes(query.toLowerCase()))

  return <><nav className="workspace-tabs" aria-label="工作台视图">
    <button aria-pressed={section==='ordinary'} disabled={monthLocked}
      onClick={()=>switchSection('ordinary')}>普通日记</button>
    <button aria-pressed={section==='monthly'} disabled={monthLocked}
      onClick={()=>switchSection('monthly')}>长期记录</button>
    <span>{connected?'已连接手机':'正在连接手机'}</span>
  </nav>{section==='monthly'?<MonthWorkspace api={api} refreshTick={monthRefresh} onLock={setMonthLocked}/>:<div className="app ordinary-app">
    <aside className="sidebar">
      <div className="sidebar-top"><strong>Moodiary Web</strong><span className={connected?'online':'offline'}>{connected?'● 实时连接':'○ 重新连接中'}</span></div>
      <button className="primary new" onClick={newNote}>＋ 新建富文本日记</button>
      <input className="search" aria-label="搜索当前日记列表" placeholder="搜索日记…" value={query} onChange={e=>setQuery(e.target.value)}/>
      <button className="secondary refresh" onClick={()=>void refreshList()}>刷新日记列表</button>
      <div className="note-list">{showing.map(x=>
        <button key={x.id} className={'note'+(current?.id===x.id?' selected':'')}
          onClick={()=>void loadNote(x.id)}>
          <strong>{x.title||'无标题'}</strong>
          <small>{x.preview?.slice(0,70)}</small>
        </button>
      )}</div>
      <div className="sidebar-foot"><a href="/">返回基础工作台</a><small>HTTP 仅限可信 Wi-Fi，传输未加密</small></div>
    </aside>
    <main className="document-pane">
      {current ? <>
        <header className="document-header">
          <input className="title-input" aria-label="日记标题" value={title} readOnly={!current.editable}
            onChange={e=>editTitle(e.target.value)} placeholder="日记标题"/>
          <button className="primary" disabled={busy||!dirty||!current.editable||conflictRef.current}
            onClick={()=>void save()}>{busy?'保存中…':'保存到手机'}</button>
        </header>
        <div className={'save-state'+(conflictRef.current?' alert':'')} role="status">
          {dirty?'● ':'✓ '}{status}
          {conflictRef.current&&<button className="secondary" onClick={()=>
            window.confirm('放弃当前未保存草稿，载入手机最新版本？')&&void loadNote(current.id,true)}>
            放弃草稿并读取手机版本
          </button>}
        </div>
        {current.editable && current.document ?
          <RichCanvas key={current.loadId} initial={current.document} onChange={editDoc}/> :
          <div className="readonly"><h2>只读保护</h2>
            <p>该日记包含暂未支持的富文本节点、旧版格式或媒体附件，网页不会修改原文。</p>
            <pre>{current.text}</pre>
          </div>}
      </>:<div className="empty"><h2>局域网富文本工作台</h2>
        <p>从左侧选择普通日记，或创建新日记。</p>
        <p>当前支持标题、段落、标题格式、文字标记、换行和安全链接。可切换到“长期记录”管理月度记录；图片编辑尚未开放。</p></div>}
    </main>
  </div>}</>
}
createRoot(document.getElementById('root')!).render(<App/>)
