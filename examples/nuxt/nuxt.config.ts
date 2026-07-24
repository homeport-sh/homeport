// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  devtools: { enabled: true },
  nitro: {
    // Compiling to ONE binary (bun build --compile) leaves .output/public
    // behind, so the public assets must live inside the server bundle.
    // serveStatic:'inline' embeds them (served from memory, no disk needed);
    // inlineDynamicImports collapses the output to the single entry file that
    // bun --compile accepts.
    preset: 'bun',
    serveStatic: 'inline',
    inlineDynamicImports: true,
  }
})
