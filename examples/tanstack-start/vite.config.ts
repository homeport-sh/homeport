import { defineConfig } from 'vite'
import { devtools } from '@tanstack/devtools-vite'

import { tanstackStart } from '@tanstack/react-start/plugin/vite'

import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { nitro } from 'nitro/vite'

const config = defineConfig({
  resolve: { tsconfigPaths: true },
  plugins: [
    devtools(),
    nitro({
      preset: "bun",
      // Compiling to ONE binary (bun build --compile) means .output/public is
      // left behind — so the public assets must live inside the server bundle.
      // serveStatic:"inline" embeds them (served from memory, no disk needed),
      // inlineDynamicImports collapses to a single entry bun --compile accepts,
      // and compressPublicAssets pre-gzips them.
      serveStatic: "inline",
      compressPublicAssets: true,
      rollupConfig: {
        external: [/^@sentry\//],
        output: { inlineDynamicImports: true },
      },
    }),
    tailwindcss(),
    tanstackStart(),
    viteReact(),
  ],
})

export default config
