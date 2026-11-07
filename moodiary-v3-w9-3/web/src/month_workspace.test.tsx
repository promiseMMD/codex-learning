// @vitest-environment jsdom
import React from 'react'
import {afterEach,beforeEach,describe,it,expect,vi} from 'vitest'
import {render,screen,within,fireEvent,waitFor,cleanup,act} from '@testing-library/react'
import {LanApiError,type JsonDoc} from './api'
import {MonthWorkspace} from './month_workspace'
import {documentText,type MonthApiClient,type MonthBlock,type MonthRevision,type MonthSnapshot} from './month_api'

// State-machine tests isolate the editor's DOM; actual Tiptap, formatting and
// the production bundle are exercised separately by browser acceptance tests.
vi.mock('./rich_canvas',()=>({
  RichCanvas:({initial,onChange,disabled}:{initial:JsonDoc,onChange:(d:JsonDoc)=>void,disabled:boolean})=>
    <textarea aria-label='正文草稿' value={documentText(initial)} readOnly={disabled}
      onChange={e=>onChange(doc(e.target.value))}/>,
  RichPreview:({document}:{document:JsonDoc})=><div>{documentText(document)}</div>,
}))
const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2'
function doc(text:string):JsonDoc{return {type:'doc',attrs:{v:2},content:[
  {type:'paragraph',content:text?[{type:'text',text}]:[]},
]}}
const clone=<T,>(v:T):T=>JSON.parse(JSON.stringify(v))
function fixture():MonthBlock{return {
  topicId:topic,monthKey:'2026-11',blockId:'block-initial-001',revisionId:'revision-initial-001',
  parentRevisionId:null,kind:'entry',dayKey:'2026-11-07',deleted:false,
  occurredAtMs:Date.parse('2026-11-07T08:20:30.456Z'),editedAtMs:Date.parse('2026-11-07T09:00:00Z'),
  document:doc('原来的记录'),
}}
function fakeApi(initial:MonthBlock[]=[fixture()]){
  const blocks=new Map(initial.map(b=>[b.blockId,clone(b)]))
  const api={
    topics:vi.fn(async()=>[{id:topic,title:'日常记录',months:[...new Set(['2026-11',...Array.from(blocks.values()).map(b=>b.monthKey)])],legacyCount:0}]),
    month:vi.fn(async(id:string,key:string):Promise<MonthSnapshot>=>({schemaVersion:1,
      topicId:id,monthKey:key,syncState:'local_only',blocks:clone(Array.from(blocks.values()).filter(b=>b.monthKey===key))})),
    session:vi.fn(async()=>true),
    append:vi.fn(async(id:string,key:string,r:MonthRevision):Promise<MonthBlock>=>{
      const b={...clone(r),topicId:id,monthKey:key,editedAtMs:Date.now()}
      blocks.set(b.blockId,b);return b
    }),
  }
  return {api:api as unknown as MonthApiClient,raw:api,blocks}
}
async function mount(api:MonthApiClient){
  const onLock=vi.fn()
  const ui=render(<MonthWorkspace api={api} refreshTick={0} onLock={onLock}/>)
  await waitFor(()=>expect((screen.getByRole('button',{name:'＋ 追加记录'}) as HTMLButtonElement).disabled).toBe(false))
  return {ui,onLock}
}
const body=()=>within(screen.getByRole('dialog')).getByLabelText('正文草稿') as HTMLTextAreaElement
const save=()=>fireEvent.click(within(screen.getByRole('dialog')).getByRole('button',{name:'保存到手机'}))

beforeEach(()=>vi.stubGlobal('confirm',vi.fn(()=>true)))
afterEach(()=>{cleanup();vi.unstubAllGlobals()})

describe('monthly PC editor user flow',()=>{
  it('appends a block and closes the dialog while remaining in the same month',async()=>{
    const f=fakeApi();await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'＋ 追加记录'}))
    fireEvent.change(body(),{target:{value:'新的追加内容'}})
    save()
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect((screen.getByLabelText('选择月份') as HTMLInputElement).value).toBe('2026-11')
    expect(screen.getByText('新的追加内容')).toBeDefined()
    expect(f.raw.append).toHaveBeenCalledTimes(1)
    expect(f.blocks.size).toBe(2)
  })
  it('preserves the exact event timestamp when editing only the body',async()=>{
    const f=fakeApi();await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'编辑记录'}))
    fireEvent.change(body(),{target:{value:'只修改正文'}})
    save()
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    const sent=f.raw.append.mock.calls[0][2]
    expect(sent.occurredAtMs).toBe(fixture().occurredAtMs)
    expect(sent.parentRevisionId).toBe(fixture().revisionId)
    expect(sent.blockId).toBe(fixture().blockId)
    expect(f.blocks.size).toBe(1)
  })
  it('moves an edited record across months without changing the stable block ID',async()=>{
    const f=fakeApi();await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'编辑记录'}))
    fireEvent.change(screen.getByLabelText('事件日期'),{target:{value:'2026-12-02'}})
    save()
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect(f.raw.append.mock.calls[0][1]).toBe('2026-12')
    expect(f.raw.append.mock.calls[0][2].blockId).toBe(fixture().blockId)
    expect((screen.getByLabelText('选择月份') as HTMLInputElement).value).toBe('2026-11')
    expect(screen.queryByText('原来的记录')).toBeNull()
    expect(screen.getByRole('status').textContent).toContain('当前仍停留在 2026-11')
  })
  it('deletes to a tombstone and restores the same block from the recycle view',async()=>{
    const f=fakeApi();await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'删除记录'}))
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button',{name:'确认删除'}))
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect(f.blocks.get(fixture().blockId)?.deleted).toBe(true)
    fireEvent.click(screen.getByRole('button',{name:'恢复记录'}))
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button',{name:'恢复到手机'}))
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect(f.blocks.get(fixture().blockId)?.deleted).toBe(false)
    expect(f.blocks.size).toBe(1)
  })
  it('restores the unique summary identity instead of creating another summary',async()=>{
    const s={...fixture(),kind:'summary' as const,dayKey:null,deleted:true}
    const f=fakeApi([s]);await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'恢复并编辑本月总结'}))
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button',{name:'恢复到手机'}))
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect(f.raw.append.mock.calls[0][2].blockId).toBe(s.blockId)
    expect(f.raw.append.mock.calls[0][2].parentRevisionId).toBe(s.revisionId)
    expect(f.blocks.size).toBe(1)
  })
  it('keeps and locks a draft after an ambiguous save, then retries identical IDs',async()=>{
    const f=fakeApi();const real=f.raw.append.getMockImplementation()!
    f.raw.append.mockImplementationOnce(async(id,key,r)=>{await real(id,key,r);throw new TypeError('lost acknowledgement')})
    await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'＋ 追加记录'}))
    fireEvent.change(body(),{target:{value:'断线前的草稿'}});save()
    await waitFor(()=>expect(screen.getByRole('alert').textContent).toContain('保存结果尚未确认'))
    expect(body().value).toBe('断线前的草稿');expect(body().readOnly).toBe(true)
    expect((within(screen.getByRole('dialog')).getByRole('button',{name:'关闭'}) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button',{name:'验证授权并重试保存'}))
    await waitFor(()=>expect(screen.queryByRole('dialog')).toBeNull())
    expect(f.raw.append.mock.calls[0]).toEqual(f.raw.append.mock.calls[1])
    expect(f.blocks.size).toBe(2)
  })
  it('does not lose an uncertain request when reauthorization fails',async()=>{
    const f=fakeApi();f.raw.append.mockRejectedValueOnce(new TypeError('network'))
    await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'＋ 追加记录'}))
    fireEvent.change(body(),{target:{value:'授权中断也保留'}});save()
    await screen.findByRole('alert')
    f.raw.session.mockResolvedValueOnce(false)
    fireEvent.click(screen.getByRole('button',{name:'验证授权并重试保存'}))
    await waitFor(()=>expect(screen.getAllByRole('status').some(n=>n.textContent?.includes('授权已失效'))).toBe(true))
    expect(body().value).toBe('授权中断也保留');expect(body().readOnly).toBe(true)
    expect(screen.getByRole('link',{name:'另开窗口配对'}).getAttribute('target')).toBe('_blank')
    expect(f.raw.append).toHaveBeenCalledTimes(1)
  })
  it('retains a conflicting draft and never auto-saves with a new parent',async()=>{
    const f=fakeApi();f.raw.append.mockRejectedValueOnce(new LanApiError('stale_revision',409))
    await mount(f.api);fireEvent.click(screen.getByRole('button',{name:'编辑记录'}))
    fireEvent.change(body(),{target:{value:'未合并的本地草稿'}});save()
    await screen.findByRole('alert')
    expect(body().value).toBe('未合并的本地草稿')
    expect(screen.getByRole('button',{name:'导出当前草稿'})).toBeDefined()
    expect(f.raw.append).toHaveBeenCalledTimes(1)
    expect(f.blocks.get(fixture().blockId)?.document).toEqual(fixture().document)
  })
  it('remote invalidation while typing preserves the editor without fetching over it',async()=>{
    const f=fakeApi();const {ui,onLock}=await mount(f.api)
    fireEvent.click(screen.getByRole('button',{name:'＋ 追加记录'}))
    fireEvent.change(body(),{target:{value:'输入中的记录'}})
    const reads=f.raw.month.mock.calls.length
    ui.rerender(<MonthWorkspace api={f.api} refreshTick={1} onLock={onLock}/>)
    expect(body().value).toBe('输入中的记录')
    expect(f.raw.month.mock.calls.length).toBe(reads)
    expect(f.raw.append).not.toHaveBeenCalled()
  })
  it('late responses from a previous month cannot replace the active month',async()=>{
    const f=fakeApi();await mount(f.api)
    let finish!:(v:MonthSnapshot)=>void
    const held=new Promise<MonthSnapshot>(r=>{finish=r})
    f.raw.month.mockImplementationOnce(()=>held)
    fireEvent.change(screen.getByLabelText('选择月份'),{target:{value:'2026-12'}})
    fireEvent.change(screen.getByLabelText('选择月份'),{target:{value:'2027-01'}})
    await waitFor(()=>expect((screen.getByRole('button',{name:'＋ 追加记录'}) as HTMLButtonElement).disabled).toBe(false))
    finish({schemaVersion:1,topicId:topic,monthKey:'2026-12',syncState:'local_only',blocks:[{...fixture(),monthKey:'2026-12',dayKey:'2026-12-02'}]})
    await waitFor(()=>expect((screen.getByLabelText('选择月份') as HTMLInputElement).value).toBe('2027-01'))
    expect(screen.queryByText('原来的记录')).toBeNull()
  })
  it('failed reads disable new writes for an unverified month',async()=>{
    const f=fakeApi();await mount(f.api)
    f.raw.month.mockRejectedValueOnce(new TypeError('disconnected'))
    fireEvent.change(screen.getByLabelText('选择月份'),{target:{value:'2026-12'}})
    await waitFor(()=>expect(screen.getByRole('status').textContent).toContain('连接中断'))
    expect((screen.getByRole('button',{name:'＋ 追加记录'}) as HTMLButtonElement).disabled).toBe(true)
    expect(f.raw.append).not.toHaveBeenCalled()
  })
  it('incompatible refresh preserves the previous content as read-only until verified again',async()=>{
    const f=fakeApi();await mount(f.api)
    f.raw.month.mockRejectedValueOnce(new LanApiError('invalid_month_response',502))
    await act(async()=>fireEvent.click(screen.getByRole('button',{name:'刷新主题与记录'})))
    expect(screen.getByText('原来的记录')).toBeDefined()
    expect(screen.getByRole('alert').textContent).toContain('仅供查看')
    expect((screen.getByRole('button',{name:'＋ 追加记录'}) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button',{name:'编辑记录'}) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button',{name:'删除记录'}) as HTMLButtonElement).disabled).toBe(true)
    await act(async()=>fireEvent.click(screen.getByRole('button',{name:'刷新主题与记录'})))
    await waitFor(()=>expect((screen.getByRole('button',{name:'编辑记录'}) as HTMLButtonElement).disabled).toBe(false))
    expect(f.raw.append).not.toHaveBeenCalled()
  })
  it('a failed topic refresh cannot be bypassed by a successful month response',async()=>{
    const f=fakeApi();await mount(f.api)
    f.raw.topics.mockRejectedValueOnce(new LanApiError('invalid_month_response',502))
    await act(async()=>fireEvent.click(screen.getByRole('button',{name:'刷新主题与记录'})))
    expect(screen.getByText('原来的记录')).toBeDefined()
    expect(screen.getByRole('alert').textContent).toContain('仅供查看')
    expect((screen.getByRole('button',{name:'编辑记录'}) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button',{name:'＋ 追加记录'}) as HTMLButtonElement).disabled).toBe(true)
  })
})
