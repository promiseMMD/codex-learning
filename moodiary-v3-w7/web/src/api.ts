// W7: browser-only transport, intentionally without durable client-side storage.
// The phone owns all committed notes and attachments.
import type { JSONContent } from '@tiptap/core'
export type JsonDoc = {
  type: 'doc'
  attrs: { v: 2 }
  content: JSONContent[]
}

export type RichNote = {
  id: string
  title: string
  text: string
  revision: string
  editable: boolean
  document: JsonDoc | null
  lastModified?: string
}

export type DiaryPreview = {
  id: string
  title: string
  preview: string
  date: string
  lastModified?: string
}

export class LanApiError extends Error {
  constructor(public readonly code: string, public readonly status: number) {
    super(code)
    this.name = 'LanApiError'
  }
}

const MAX_BYTES = 200000
const MAX_NODES = 4000
const PLAIN_MARKS = new Set(['bold', 'italic', 'underline', 'strike', 'code'])
const VALID_SCHEMES = new Set(['https:', 'http:', 'mailto:'])
const isObject = (v: unknown): v is Record<string, unknown> =>
  v !== null && typeof v === 'object' && !Array.isArray(v)
const keysIn = (v: Record<string, unknown>, keys: string[]) =>
  Object.keys(v).every((key) => keys.includes(key))

export function validateRichDocument(doc: unknown): asserts doc is JsonDoc {
  function fail(): never { throw new LanApiError('unsupported_rich_document', 422) }
  if (!isObject(doc) || doc.type !== 'doc' ||
    !keysIn(doc, ['type', 'attrs', 'content']) ||
    !isObject(doc.attrs) || !keysIn(doc.attrs, ['v']) ||
    doc.attrs.v !== 2 || !Array.isArray(doc.content) ||
    doc.content.length === 0) fail()

  let count = 0
  const tick = () => { if (++count > MAX_NODES) fail() }

  function inlineParts(input: unknown) {
    if (input === undefined) return
    if (!Array.isArray(input)) fail()
    for (const part of input as unknown[]) {
      tick()
      if (!isObject(part)) fail()
      if (part.type === 'hardBreak') {
        if (!keysIn(part, ['type'])) fail()
        continue
      }
      if (part.type !== 'text' || !keysIn(part, ['type', 'text', 'marks']) ||
        typeof part.text !== 'string' || part.text.length === 0) fail()
      if (part.marks === undefined) continue
      if (!Array.isArray(part.marks) || part.marks.length === 0 ||
        part.marks.length > 12) fail()
      const seen = new Set<string>()
      for (const mark of part.marks) {
        if (!isObject(mark) || typeof mark.type !== 'string' ||
          seen.has(mark.type)) fail()
        seen.add(mark.type as string)
        if (PLAIN_MARKS.has(mark.type as string)) {
          if (!keysIn(mark, ['type'])) fail()
        } else if (mark.type === 'link') {
          if (!keysIn(mark, ['type', 'attrs']) ||
            !isObject(mark.attrs) || !keysIn(mark.attrs, ['href']) ||
            typeof mark.attrs.href !== 'string' || mark.attrs.href.length > 2048) fail()
          let url: URL
          try { url = new URL(mark.attrs.href as string) }
          catch { fail(); return }
          if (!VALID_SCHEMES.has(url.protocol) ||
            (url.protocol !== 'mailto:' && !url.hostname)) fail()
        } else fail()
      }
    }
  }

  for (const node of doc.content as unknown[]) {
    tick()
    if (!isObject(node)) fail()
    if (node.type === 'paragraph') {
      if (!keysIn(node, ['type', 'content'])) fail()
    } else if (node.type === 'heading') {
      if (!keysIn(node, ['type', 'attrs', 'content']) ||
        !isObject(node.attrs) || !keysIn(node.attrs, ['level']) ||
        !Number.isInteger(node.attrs.level) || (node.attrs.level as number) < 1 ||
        (node.attrs.level as number) > 6) fail()
    } else fail()
    inlineParts(node.content)
  }

  if (new TextEncoder().encode(JSON.stringify(doc)).length > MAX_BYTES) {
    throw new LanApiError('rich_document_too_large', 413)
  }
}

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const REVISION = /^[a-f0-9]{64}$/

// A diary operation ID, NOT an authentication credential.
// In insecure HTTP contexts crypto.getRandomValues may be unavailable.
export function newDiaryId(): string {
  const bytes = new Uint8Array(16)
  const c = typeof crypto === 'undefined' ? undefined : crypto
  if (c && typeof c.getRandomValues === 'function') c.getRandomValues(bytes)
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const h = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('')
  return [h.slice(0,8),h.slice(8,12),h.slice(12,16),h.slice(16,20),h.slice(20)].join('-')
}

export const emptyDocument = (): JsonDoc => ({
  type:'doc',attrs:{v:2},content:[{type:'paragraph'}],
})

// Prevent stale fetch completion from overwriting a newer local draft.
export function canApplyRemoteRead(
  requestSequence: number,
  activeSequence: number,
  editGenerationAtRequest: number,
  currentEditGeneration: number,
  hasDirtyDraft: boolean,
): boolean {
  return requestSequence === activeSequence &&
    !(hasDirtyDraft && editGenerationAtRequest !== currentEditGeneration)
}

export class LanClient {
  constructor(private readonly fetcher: typeof fetch = fetch) {}
  private csrf: string | null = null

  async session(): Promise<boolean> {
    const resp = await this.fetcher('/api/session', {credentials:'same-origin', cache:'no-store'})
    const info = await resp.json()
    this.csrf = info.authorized && typeof info.csrf === 'string' ? info.csrf : null
    return !!this.csrf
  }

  protected async call<T>(url: string, method = 'GET', body?: unknown): Promise<T> {
    const write = method !== 'GET'
    if (write && !this.csrf) throw new LanApiError('pairing_required',401)
    const controller = new AbortController()
    const timeout = setTimeout(()=>controller.abort(), 30000)
    try {
    const response = await this.fetcher(url, {
      method, credentials:'same-origin', cache:'no-store',
      signal: controller.signal,
      headers: write ? {'content-type':'application/json', 'x-moodiary-csrf':this.csrf!} : {},
      body: write ? JSON.stringify(body) : undefined,
    })
    let result: any
    try { result = await response.json() }
    catch { throw new LanApiError('invalid_response', response.status) }
    if (!response.ok) throw new LanApiError(typeof result.error==='string' ? result.error : 'request_failed',response.status)
    return result as T
    } finally { clearTimeout(timeout) }
  }

  async list(): Promise<DiaryPreview[]> {
    const result = await this.call<{items:DiaryPreview[]}>('/api/diaries')
    return result.items
  }

  async read(id:string):Promise<RichNote> {
    if (!ID.test(id)) throw new LanApiError('invalid_id',422)
    const result = await this.call<RichNote>('/api/rich/diaries/'+encodeURIComponent(id))
    if (result.editable) validateRichDocument(result.document)
    return result
  }

  async save(note: {id:string,title:string,document:JsonDoc,revision:string|null}):Promise<RichNote> {
    if (!ID.test(note.id) || note.title.length > 200) throw new LanApiError('invalid_note',422)
    validateRichDocument(note.document)
    if (note.revision !== null && !REVISION.test(note.revision)) throw new LanApiError('invalid_revision',422)
    const create = note.revision === null
    const result = await this.call<RichNote>(
      create?'/api/rich/diaries':'/api/rich/diaries/'+encodeURIComponent(note.id),
      create?'POST':'PUT',
      create?{id:note.id,title:note.title,document:note.document}:
        {title:note.title,document:note.document,revision:note.revision},
    )
    if (!REVISION.test(result.revision)) throw new LanApiError('invalid_response',502)
    return result
  }
}
