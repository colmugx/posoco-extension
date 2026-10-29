import { defineConfig } from 'vite'
import rabbita from '@rabbita/vite'
import tailwindcss from '@tailwindcss/vite'

// The published artifact contract is fixed: two hosts (the Cetas Bun adapter and
// the native MoonBack server) read exactly `dist/index.html`, `dist/index.js`
// and `dist/board.css`. Vite's default hashed names would break both, so the
// entry and the stylesheet names are pinned here.
export default defineConfig({
  base: '/',
  // `public/` holds the legacy design-system stylesheet, which is imported by
  // `styles/app.css` instead of being copied verbatim. Copying it would emit a
  // second, unprocessed `board.css` next to the bundled one.
  publicDir: false,
  plugins: [rabbita({ mainPkgDir: 'cmd/browser' }), tailwindcss()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // One stylesheet, no per-chunk CSS: the hosts serve a single `/board.css`.
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: 'index.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: info =>
          info.names?.some(name => name.endsWith('.css'))
            ? 'board.css'
            : 'assets/[name][extname]',
      },
    },
  },
})
