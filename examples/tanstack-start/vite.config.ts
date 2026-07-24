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
      // Compiling to ONE binary (bun build --compile) leaves .output/public
      // behind, so the public assets must live inside the server bundle.
      // serveStatic:"inline" embeds them (served from memory, no disk needed);
      // inlineDynamicImports collapses the output to the single entry file that
      // bun --compile accepts. Both are top-level Nitro options.
      serveStatic: "inline",
      inlineDynamicImports: true,
      rollupConfig: {
        external: [/^@sentry\//],
      },
    }),
    tailwindcss(),
    tanstackStart(),
    viteReact(),
  ],
})

export default config
