import { defineConfig } from "astro/config";
import icon from "astro-icon";
import tailwindcss from "@tailwindcss/vite";
import nimbus, { defineConfig as defineNimbusConfig } from "nimbus-docs";
import { tableScroll } from "nimbus-docs/markdown";

const nimbusConfig = defineNimbusConfig({
  site: "https://docs.homeport.sh",
  title: "homeport",
  description:
    "Deploy single-binary web apps to your own VPS — no Docker, no registry, nothing on the server but your binary.",
  locale: "en",
  github: "https://github.com/homeport-sh/homeport",
  socialImageAlt: "homeport documentation",
  // Explicit order — the core pages first, then the two groups. Autogenerating
  // the whole tree interleaves directory-groups unpredictably among the
  // top-level pages; listing items fixes their placement. Group children still
  // order by each page's `sidebar.order`.
  sidebar: {
    items: [
      "introduction",
      "installation",
      "quick-start",
      "configuration",
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
    icon(),
    nimbus(nimbusConfig, {
      // Authoring rules are opt-in by design — your repo, your taste. The
      // two below are the load-bearing pair: frontmatter has to validate
      // against the content schema for the page to render properly, and
      // broken internal links are 404s for your readers. Add the others
      // (heading hierarchy, code-block language, style, etc.) when you're
      // ready to enforce them — see `nimbus-docs lint --help`.
      rules: {
        "nimbus/frontmatter-shape": "error",
        "nimbus/internal-link": "error",
      },
      // Wrap wide tables so they scroll instead of overflowing the page
      // (styled by `.nb-table-scroll` in src/styles/prose.css).
      markdown: {
        hastPlugins: [tableScroll()],
      },
    }),
  ],
});
