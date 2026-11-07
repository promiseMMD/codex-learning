import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  root,
  base: '/lan-editor/',
  plugins: [react()],
  build: {
    outDir: resolve(root, '../../../../../mobile/assets/lan'),
    emptyOutDir: true,
    sourcemap: false,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: 'lan.js',
        chunkFileNames: 'lan-chunk-[name].js',
        assetFileNames: 'lan.css',
      },
    },
  },
})
