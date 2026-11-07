import { afterEach, beforeEach, expect, it } from 'vitest'
import { bindApi, installBridge, resetBridgeForTest } from '@/core/bridge'
import { doc, p, renderEditor, type EditorFixture } from '@/test/editor'

let h: EditorFixture
beforeEach(() => {
  h = renderEditor()
  installBridge()
  bindApi(h.api)
  h.load(doc([p('原始记录')]))
})
afterEach(() => { h.destroy(); resetBridgeForTest() })

it('captures actual rich content even before the debounced change was sent', () => {
  h.editor.commands.setTextSelection(5)
  h.editor.commands.toggleBold()
  h.editor.commands.insertContent('当天补充')
  window.MoodiaryBridge.snapshot('native-save-1')
  const reply = h.lastPost('snapshot')?.payload as { reqId: string; document: string }
  expect(reply.reqId).toBe('native-save-1')
  expect(JSON.parse(reply.document)).toEqual(h.editor.getJSON())
  expect(reply.document).toContain('bold')
  expect(reply.document).toContain('当天补充')
  window.MoodiaryBridge.snapshot('native-save-2')
  expect(h.lastPost('snapshot')?.payload).toMatchObject({ document: reply.document })
})

it('returns no saveable document for future-schema fallback or a detached API', () => {
  h.load({ type: 'doc', attrs: { v: 99 }, content: [p('未来格式')] })
  window.MoodiaryBridge.snapshot('future')
  expect(h.lastPost('snapshot')?.payload).toEqual({ reqId: 'future', document: null })
  bindApi(null)
  window.MoodiaryBridge.snapshot('detached')
  expect(h.lastPost('snapshot')?.payload).toEqual({ reqId: 'detached', document: null })
})
