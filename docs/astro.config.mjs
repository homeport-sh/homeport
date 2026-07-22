// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://docs.homeport.sh',
	integrations: [
		starlight({
			title: 'homeport',
			description:
				'Deploy single-binary web apps to your own VPS — no Docker, no registry, nothing on the server but your binary.',
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/homeport-sh/homeport' },
			],
			// SPA-like navigation: override Head to add Astro's ClientRouter
			// (view transitions). Starlight persists its chrome, so it's smooth.
			components: {
				Head: './src/components/Head.astro',
			},
			sidebar: [
				{ label: 'Introduction', slug: 'introduction' },
				{ label: 'Installation', slug: 'installation' },
				{ label: 'Quick start', slug: 'quick-start' },
				{ label: 'Configuration', slug: 'configuration' },
				{ label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
				{ label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
			],
		}),
	],
});
