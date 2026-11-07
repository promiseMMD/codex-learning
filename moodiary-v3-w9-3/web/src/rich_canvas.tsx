import React, {useRef,useEffect} from 'react'
import {EditorContent,useEditor} from '@tiptap/react'
import type {Editor,JSONContent} from '@tiptap/core'
import {lanExtensions} from './schema'
import {validateRichDocument,type JsonDoc} from './api'

export function RichCanvas({ initial, onChange, disabled=false }: {
  initial: JsonDoc, onChange: (next: JsonDoc)=>void, disabled?:boolean
}) {
  const callback = useRef(onChange)
  callback.current = onChange
  const editor = useEditor({
    extensions: lanExtensions,
    content: initial,
    immediatelyRender: false,
    injectCSS: false,
    editable: !disabled,
    editorProps: {attributes: {'class':'tiptap-area', 'spellcheck':'true'}},
    onUpdate: ({editor}) => callback.current(editor.getJSON() as JsonDoc),
  })
  useEffect(()=>{editor?.setEditable(!disabled,false)},[editor,disabled])
  if (!editor) return <p className="subtle">正在打开编辑器…</p>
  return <>
    <nav className="toolbar" aria-label="富文本格式">
      <Tool editor={editor} label="撤销" action={()=>editor.chain().focus().undo().run()} />
      <Tool editor={editor} label="重做" action={()=>editor.chain().focus().redo().run()} />
      <Tool editor={editor} label="粗体" action={()=>editor.chain().focus().toggleBold().run()} active={editor.isActive('bold')} />
      <Tool editor={editor} label="斜体" action={()=>editor.chain().focus().toggleItalic().run()} active={editor.isActive('italic')} />
      <Tool editor={editor} label="下划线" action={()=>editor.chain().focus().toggleUnderline().run()} active={editor.isActive('underline')} />
      <Tool editor={editor} label="删除线" action={()=>editor.chain().focus().toggleStrike().run()} active={editor.isActive('strike')} />
      <Tool editor={editor} label="行内代码" action={()=>editor.chain().focus().toggleCode().run()} active={editor.isActive('code')} />
      <Tool editor={editor} label="正文" action={()=>editor.chain().focus().setParagraph().run()} active={editor.isActive('paragraph')} />
      <Tool editor={editor} label="标题" action={()=>editor.chain().focus().toggleHeading({level:2}).run()} active={editor.isActive('heading',{level:2})} />
      <Tool editor={editor} label="链接" action={()=>{
        const typed=window.prompt('输入 http://、https:// 或 mailto: 链接')
        if (!typed) return
        let ok=false
        try { const url=new URL(typed);ok=['https:','http:','mailto:'].includes(url.protocol)&&
          (url.protocol==='mailto:'||!!url.hostname) } catch {}
        if (!ok){window.alert('只允许 http、https 或 mailto 链接');return}
        editor.chain().focus().setLink({href:typed}).run()
      }}/>
      <Tool editor={editor} label="取消链接" action={()=>editor.chain().focus().unsetLink().run()} />
    </nav>
    <EditorContent editor={editor} className="editor-wrap" />
  </>
}
function Tool({editor,label,action,active=false}:{
  editor:Editor,label:string,action:()=>void,active?:boolean
}) {
  return <button type="button" className={active?'active':''}
    aria-label={label} aria-pressed={active}
    onMouseDown={e=>e.preventDefault()}
    onClick={action} disabled={!editor.isEditable}>{label}</button>
}

export function RichPreview({document}:{document:JsonDoc}){
  try{validateRichDocument(document)}catch{return <p>此格式暂不能在网页预览，请在手机查看。</p>}
  const inline=(n:JSONContent,key:number):React.ReactNode=>{
    if(n.type==='hardBreak')return <br key={key}/>
    let out:React.ReactNode=n.text??''
    for(const m of n.marks??[]){
      if(m.type==='bold')out=<strong>{out}</strong>
      else if(m.type==='italic')out=<em>{out}</em>
      else if(m.type==='underline')out=<u>{out}</u>
      else if(m.type==='strike')out=<s>{out}</s>
      else if(m.type==='code')out=<code>{out}</code>
      else if(m.type==='link')out=<a href={m.attrs?.href} target='_blank' rel='noopener noreferrer'>{out}</a>
    }
    return <React.Fragment key={key}>{out}</React.Fragment>
  }
  return <div className='rich-preview'>{document.content.map((n,i)=>
    React.createElement(n.type==='heading'?'h'+n.attrs?.level:'p',{key:i},(n.content??[]).map(inline)))}</div>
}
