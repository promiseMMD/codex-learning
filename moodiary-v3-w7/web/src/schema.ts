// W7 deliberately uses only document nodes validated by W6.
// Unsupported diary content never enters an editable Tiptap instance.
import { Node } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Link from '@tiptap/extension-link'
import Underline from '@tiptap/extension-underline'

export const LanDoc = Node.create({
  name: 'doc',
  topNode: true,
  content: 'block+',
  addAttributes() {
    return { v: { default: 2 } }
  },
})

// Default Link emits target/rel/class attrs that W6 intentionally rejects.
// This extension persists ONLY href.
const LanLink = Link.extend({
  addAttributes() {
    return {
      href: {
        default: null,
        parseHTML: element => element.getAttribute('href'),
        renderHTML: attributes =>
          attributes.href ? { href: attributes.href } : {},
      },
    }
  },
}).configure({
  autolink: false,
  linkOnPaste: false,
  openOnClick: false,
  HTMLAttributes: {},
})

export const lanExtensions = [
  LanDoc,
  StarterKit.configure({
    document: false,
    blockquote: false,
    bulletList: false,
    orderedList: false,
    listItem: false,
    codeBlock: false,
    horizontalRule: false,
    // Root content is constrained to paragraphs and headings.
  }),
  Underline,
  LanLink,
]
