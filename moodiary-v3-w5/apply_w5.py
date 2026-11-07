"""W5 editor-state race fix, stable auto-save, and guarded read-only mode.

Applied *after* W4 source overlay; fail closed if a prior patch changed anchors.
No repository write endpoints or monthly record storage are enabled here.
"""
from pathlib import Path
import sys
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
p = root/'mobile/lib/app/home/mod_lan_service.dart'
s = p.read_text(encoding='utf-8')

def replace(old: str, new: str):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'W5 editor patch anchor changed, matches={n}: {old[:65]!r}')
    s = s.replace(old, new, 1)

replace(
"let csrf='', openedId=null, openedRevision=null, pendingCreateId=null, loaded=false, dirty=false, writeBusy=false;",
"let csrf='', openedId=null, openedRevision=null, pendingCreateId=null, loaded=false, dirty=false, writeBusy=false;\nlet editorReadOnly=false, draftSerial=0, openSerial=0, autoSaveTimer=null;")
replace(
"function setReadOnly(lock){editTitle.disabled=lock;editText.disabled=lock;q('saveEntry').disabled=lock}",
"function setReadOnly(lock){editorReadOnly=lock;editTitle.disabled=lock;editText.disabled=lock;q('saveEntry').disabled=lock||writeBusy}")
replace(
"async function openEntry(id){\n try{",
"async function openEntry(id){\n if(writeBusy){updateEditor('正在保存，请先完成保存后再切换日记');return}\n const load=++openSerial;\n try{")
replace(
"  const d=await api('/api/diaries/'+encodeURIComponent(id));\n  if((previous===id || openedId===id) && dirty){",
"  const d=await api('/api/diaries/'+encodeURIComponent(id));\n  if(load!==openSerial)return;\n  if((previous===id || openedId===id) && dirty){")
replace(
"function newEntry(){\n openedId=null;",
"function newEntry(){\n if(writeBusy){updateEditor('正在保存，请先完成保存后再新建');return}\n ++openSerial;clearTimeout(autoSaveTimer);\n openedId=null;")
replace(
"async function saveEntry(){\n if(writeBusy || !loaded)return;\n writeBusy=true;q('saveEntry').disabled=true;",
"async function saveEntry(){\n if(writeBusy || !loaded || editorReadOnly)return;\n clearTimeout(autoSaveTimer);\n const savingSerial=draftSerial;\n writeBusy=true;q('saveEntry').disabled=true;")
replace(
"  openedId=result.id;openedRevision=result.revision;pendingCreateId=null;dirty=false;loaded=true;\n  updateEditor('已保存至手机 · WebDAV 将独立同步');",
"  openedId=result.id;openedRevision=result.revision;pendingCreateId=null;\n  const newerInput=draftSerial!==savingSerial;\n  dirty=newerInput;loaded=true;\n  updateEditor(newerInput?'已保存此前内容；保存期间的新输入仍待保存':'已保存至手机 · WebDAV 将独立同步');\n  if(newerInput)queueAutoSave();")
replace(
" }catch(e){\n  updateEditor(e.message==='stale_revision'?",
" }catch(e){\n  dirty=true; // Unacknowledged edits remain unsaved.\n  updateEditor(e.message==='stale_revision'?")
replace(
" }finally{writeBusy=false;q('saveEntry').disabled=false}\n}\neditTitle.addEventListener('input',()=>{dirty=true;updateEditor('未保存的修改')});\neditText.addEventListener('input',()=>{dirty=true;updateEditor('未保存的修改')});",
" }finally{writeBusy=false;q('saveEntry').disabled=editorReadOnly}\n}\nfunction queueAutoSave(){\n clearTimeout(autoSaveTimer);\n if(!editorReadOnly&&loaded&&dirty){\n  autoSaveTimer=setTimeout(()=>{if(!writeBusy&&dirty)saveEntry();else if(dirty)queueAutoSave()},2000);\n }\n}\nfunction markChanged(){\n dirty=true;++draftSerial;updateEditor('未保存的修改');queueAutoSave();\n}\neditTitle.addEventListener('input',markChanged);\neditText.addEventListener('input',markChanged);")
replace(
"function closeConnection(){\n  if(socket)",
"function closeConnection(){\n  clearTimeout(autoSaveTimer);\n  if(socket)")
replace(
"if(dirty&&!confirm('有未保存的编辑，确定放弃吗？'))return;dirty=false;openEntry(d.id)",
"if(writeBusy){updateEditor('正在保存，请先完成保存后再切换');return}if(dirty&&!confirm('有未保存的编辑，确定放弃吗？'))return;dirty=false;openEntry(d.id)")
replace("'mode': 'w4_basic_text_editor'", "'mode': 'w5_autosave_safe_text_editor'")
p.write_text(s, encoding='utf-8')
print('W5 safe editor persistence patch applied to', p)
