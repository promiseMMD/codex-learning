// W7 intentionally matches the schema accepted by the phone W6 writer.
import { Mark, Node } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Underline from '@tiptap/extension-underline'
// Import typing for setLink/unsetLink commands; the extension itself is NOT
// registered, because its extra stored attributes do not match W6.
import '@tiptap/extension-link'

export const LanDoc = Node.create({
  name: 'doc',
  topNode: true,
  content: 'block+',
  addAttributes() { return { v: { default: 2 } } },
})

// Only href is stored in the ProseMirror JSON; HTML rel/target are rendered
// defensively, but never become persistent document attributes.
const LanLink = Mark.create({
  name: 'link',
  priority: 1000,
  inclusive: false,
  addAttributes() {
    return {
      href: { default: null, parseHTML: el => el.getAttribute('href') },
    }
  },
  parseHTML() { return [{ tag: 'a[href]' }] },
  renderHTML({ HTMLAttributes }) {
    return ['a', {
      href: HTMLAttributes.href,
      rel: 'noopener noreferrer nofollow',
      target: '_blank',
    }, 0]
  },
  addCommands() {
    return {
      setLink: (attrs: {href: string}) => ({commands}) =>
        commands.setMark(this.name, attrs),
      unsetLink: () => ({commands}) => commands.unsetMark(this.name),
    }
  },
})

export const lanExtensions = [
  LanDoc,
  StarterKit.configure({
    document: false,
    link: false,
    underline: false,
    blockquote: false,
    bulletList: false,
    orderedList: false,
    listItem: false,
    codeBlock: false,
    horizontalRule: false,
  }),
  Underline,
  LanLink,
]
