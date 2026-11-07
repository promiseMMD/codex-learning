// @vitest-environment jsdom
import {describe,expect,it,vi} from 'vitest'
import {Editor} from '@tiptap/core'
import {lanExtensions} from './schema'
import {
  LanClient,LanApiError,emptyDocument,newDiaryId,validateRichDocument,
} from './api'

describe('W7 schema matches W6 native allowed nodes',()=>{
  it('accepts headings, bold, italics and safe link marks from real Tiptap instance',()=>{
    const editor=new Editor({
      extensions:lanExtensions,
      injectCSS:false,
      content:emptyDocument(),
    })
    editor.commands.setContent({
      type:'doc',attrs:{v:2},
      content:[
        {type:'heading',attrs:{level:2},content:[{type:'text',text:'光刻记录',marks:[{type:'bold'}]}]},
        {type:'paragraph',content:[
          {type:'text',text:'Stage / Alignment',marks:[{type:'italic'}]},
          {type:'hardBreak'},
          {type:'text',text:'参考',marks:[{type:'link',attrs:{href:'https://example.org'}}]},
        ]},
      ],
    })
    const json=editor.getJSON()
    expect(json.attrs?.v).toBe(2)
    expect(json.content?.[1].content?.[2].marks?.[0].attrs).toEqual({href:'https://example.org'})
    expect(()=>validateRichDocument(json)).not.toThrow()
    editor.destroy()
  })
  it('rejects unknown nodes, images, future schema and invalid URLs',()=>{
    expect(()=>validateRichDocument({...emptyDocument(),attrs:{v:3}})).toThrow()
    expect(()=>validateRichDocument({...emptyDocument(),content:[{type:'image',attrs:{src:'a'}}]})).toThrow()
    expect(()=>validateRichDocument({...emptyDocument(),content:[{type:'paragraph',
      content:[{type:'text',text:'x',marks:[{type:'link',attrs:{href:'javascript:alert(1)'}}]}]}]})).toThrow()
    expect(()=>validateRichDocument({...emptyDocument(),content:[{type:'paragraph',
      content:[{type:'text',text:'x',marks:[{type:'underline',attrs:{evil:true}}]}]}]})).toThrow()
  })
  it('creates locally stable operation ids without requiring a secure context',()=>{
    expect(newDiaryId()).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  })
})

describe('W7 browser client enforces revisioned writes',()=>{
  const id='dc904ad3-d89d-44e6-8368-037299e3cb42'
  const revision='a'.repeat(64)
  it('does not transmit credentials in URLs and sends session CSRF with create/update',async()=>{
    const calls:Array<{url:string,method:string,headers:any,body:any}>=[]
    const fetcher=vi.fn(async(input:RequestInfo|URL,opts:RequestInit={})=>{
      const url=String(input)
      calls.push({url,method:opts.method??'GET',headers:opts.headers,
        body:opts.body===undefined?null:JSON.parse(String(opts.body))})
      if(url==='/api/session')return new Response(JSON.stringify({authorized:true,csrf:'secret'}),{status:200})
      return new Response(JSON.stringify({id,title:'测试',text:'记录',editable:true,
        revision,document:emptyDocument()}),{status:200})
    })
    const client=new LanClient(fetcher as typeof fetch)
    expect(await client.session()).toBe(true)
    await client.save({id,title:'测试',document:emptyDocument(),revision:null})
    await client.save({id,title:'测试',document:emptyDocument(),revision})
    expect(calls[1].url).toBe('/api/rich/diaries')
    expect(calls[1].method).toBe('POST')
    expect(calls[1].headers['x-moodiary-csrf']).toBe('secret')
    expect(calls[2].url).toBe('/api/rich/diaries/'+id)
    expect(calls[2].body.revision).toBe(revision)
  })
  it('keeps conflict visible to the UI and never retries stale PUT automatically',async()=>{
    const f=vi.fn(async(url:string,opts:RequestInit={})=> {
      if(url==='/api/session')return new Response(JSON.stringify({authorized:true,csrf:'x'}),{status:200})
      return new Response(JSON.stringify({error:'stale_revision'}),{status:409})
    })
    const client=new LanClient(f as unknown as typeof fetch)
    await client.session()
    await expect(client.save({id,title:'测试',document:emptyDocument(),revision}))
      .rejects.toMatchObject({code:'stale_revision',status:409})
    expect(f).toHaveBeenCalledTimes(2)
  })
  it('denies unsafely formatted documents before any write request',async()=>{
    const f=vi.fn(async()=>new Response(JSON.stringify({authorized:true,csrf:'x'}),{status:200}))
    const client=new LanClient(f as unknown as typeof fetch)
    await client.session()
    await expect(client.save({id,title:'坏文档',
      document:{type:'doc',attrs:{v:2},content:[{type:'image'}]} as any,
      revision:null})).rejects.toBeInstanceOf(LanApiError)
    expect(f).toHaveBeenCalledTimes(1)
  })
})
