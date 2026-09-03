import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import nimbus, { defineConfig as defineNimbusConfig } from "@cloudflare/nimbus-docs";
import { tableScroll } from "@cloudflare/nimbus-docs/markdown";

const nimbusConfig = defineNimbusConfig({
  site: "https://docs.homeport.sh",
  title: "homeport",
  description:
    "Deploy single-binary web apps to your own VPS — no Docker, no registry, nothing on the server but your binary.",
  locale: "en",
  github: "https://github.com/homeport-sh/homeport",
  socialImageAlt: "homeport documentation",
  // Explicit rail. The four top-level pages are ordered by hand (their
  // frontmatter `sidebar.order` only orders pages *within* a group, so it
  // can't sequence these); Guides and Reference autogenerate from their
  // directories and pick their internal order up from that frontmatter.
  sidebar: {
    items: [
      { label: "Introduction", link: "/introduction" },
      { label: "Installation", link: "/installation" },
      { label: "Quick start", link: "/quick-start" },
      { label: "Configuration", link: "/configuration" },
      { label: "Guides", autogenerate: { directory: "guides" } },
      { label: "Reference", autogenerate: { directory: "reference" } },
    ],
  },
});

export default defineConfig({
  output: "static",
  // Tailwind v4 via its Vite plugin (the integration Astro recommends for
  // Tailwind v4 — replaces the PostCSS plugin, which doesn't build under
  // Astro 7's Vite 8 bundler).
  vite: {
    plugins: [tailwindcss()],
  },
  // Hover-prefetch link targets so full-page navigations feel instant without
  // a client-side router.
  prefetch: {
    prefetchAll: true,
    defaultStrategy: "hover",
  },
  integrations: [
    nimbus(nimbusConfig, {
      rules: {
        "nimbus/frontmatter-shape": "error",
        "nimbus/internal-link": "error",
      },
      // Wrap wide tables so they scroll instead of overflowing the page
      // (styled by `.nb-table-scroll` in src/styles/prose.css). The
      // configuration and commands references both carry wide tables.
      markdown: {
        hastPlugins: [tableScroll()],
      },
    }),
  ],
});
