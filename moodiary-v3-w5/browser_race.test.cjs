'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const code=fs.readFileSync(process.argv[2] || 'web_w5.js','utf8');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
class Element {
 constructor(){this.children=[];this.textContent='';this.hidden=false;this.disabled=false;this.dataset={};this.listeners={};this.value='';this.style={};}
 get firstChild(){return this.children[0] || null}
 append(child){this.children.push(child)}
 removeChild(child){const i=this.children.indexOf(child);if(i>=0)this.children.splice(i,1)}
 addEventListener(type,fn){this.listeners[type]=fn}
 click(){if(!this.disabled)this.listeners.click?.()}
 change(v){this.value=v;this.listeners.input?.()}
}
(async()=>{
 const el={};let resolveCreate,creates=[],updates=[],ws=[],listeners={};
 const document={getElementById:id=>el[id]??=(new Element()),createElement:()=>new Element(),querySelectorAll:()=>[]};
 const fetch=async(url,opts={})=>{
   if(url==='/api/session')return {ok:true,json:async()=>({authorized:true,csrf:'csrf'})};
   if(url==='/api/diaries'&&opts.method==='POST'){
     creates.push(JSON.parse(opts.body));
     return await new Promise(resolve=>{resolveCreate=()=>resolve({ok:true,json:async()=>({id:creates.at(-1).id,revision:'a'.repeat(64),editable:true})})});
   }
   if(url.startsWith('/api/diaries/')&&opts.method==='PUT'){
     updates.push(JSON.parse(opts.body));
     return {ok:true,json:async()=>({id:url.split('/').at(-1),revision:'b'.repeat(64),editable:true})};
   }
   if(url==='/api/diaries'&&!opts.method)return {ok:true,json:async()=>({items:[{id:'00000000-aaaa-4aaa-aaaa-000000000000',title:'复杂只读笔记',preview:'只读正文',date:'2026-11-07'}]})};
   if(url==='/api/diaries/00000000-aaaa-4aaa-aaaa-000000000000' && !opts.method)return {ok:true,json:async()=>({id:'00000000-aaaa-4aaa-aaaa-000000000000',revision:'c'.repeat(64),title:'复杂只读笔记',text:'只读正文',editable:false})};
   if(url==='/api/months')return {ok:true,json:async()=>({topics:[]})};
   throw Error('unexpected request '+url);
 };
 class WebSocket {static OPEN=1;constructor(url){this.url=url;this.readyState=1;ws.push(this)}send(){}close(){this.readyState=3}}
 const scope={document,fetch,WebSocket,URLSearchParams,location:{host:'192.168.1.2:1122'},window:{addEventListener:(n,f)=>listeners[n]=f},setInterval:()=>1,clearInterval:()=>{},setTimeout,clearTimeout,Date,Error,JSON,Math,Number,String,Promise,encodeURIComponent,confirm:()=>true};
 vm.runInNewContext(code,scope,{timeout:1000});
 await delay(20);
 el.editTitle.change('保存中编辑测试');el.editText.change('第一次内容');
 el.saveEntry.click();await delay(15);
 assert.equal(creates.length,1);
 assert.equal(creates[0].text,'第一次内容');
 el.editText.change('保存期间追加内容');
 resolveCreate();await delay(40);
 assert.match(el.editStatus.textContent,/新输入仍待保存/);
 assert.equal(el.editText.value,'保存期间追加内容');
 await delay(2150);
 assert.equal(updates.length,1,'dirty content must get a second CAS save');
 assert.equal(updates[0].text,'保存期间追加内容');
 assert.equal(updates[0].revision,'a'.repeat(64));
 assert.match(el.editStatus.textContent,/已保存至手机/);
 assert.ok(el.records.children.length>0);
 el.records.children[0].click();await delay(30);
 assert.equal(el.saveEntry.disabled,true,'complex note must stay read-only');
 assert.equal(el.editText.disabled,true,'complex note text field must be read-only');
 const before=updates.length;
 el.saveEntry.click();await delay(20);
 assert.equal(updates.length,before,'read-only note must never submit a write');
 listeners.pagehide();
 console.log('W5 in-flight edits, deferred autosave, and subsequent CAS save passed');
})().catch(e=>{console.error(e);process.exitCode=1});
