# homeport docs

The documentation site for [homeport](https://github.com/homeport-sh/homeport),
live at <https://docs.homeport.sh>.

Built on [Nimbus](https://nimbus-docs.com) (`@cloudflare/nimbus-docs`) — an
Astro + MDX docs framework. The UI components under `src/components/ui/` are
copied into this repo by design and are ours to edit; the npm package supplies
the content schemas, sidebar/TOC, MDX→markdown, and build hooks.

## Commands

| Command             | Action                                                  |
| :------------------ | :------------------------------------------------------ |
| `bun install`       | Install dependencies                                     |
| `bun run dev`       | Dev server on `localhost:4321`                           |
| `bun run build`     | Build to `./dist/` (also runs Pagefind + sitemap)        |
| `bun run preview`   | Preview the build locally                                |
| `bun run typecheck` | `astro check`                                            |
| `bun run lint:docs` | Nimbus content lint (frontmatter shape, internal links)  |

## Writing

Pages are `.mdx` under `src/content/docs/`; the tree is the URL structure.
`Aside`, `Card`, `CardGrid`, `Steps`/`Step`, `Tabs`/`TabItem` and
`PackageManagers` are available in any page without an import — they're
registered as MDX globals in `src/components.ts`.

Frontmatter needs `title`; `description` and `sidebar.order` are the other
two in regular use. The top-level rail order and the Guides/Reference groups
are set in `astro.config.ts`.

Icons are Iconify names — Phosphor (`ph:*`) is installed.

## Deploying

`homeport deploy` from this directory; see `homeport.yaml`. The site is static,
served by Caddy on the box with no process running.
