import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import adapter from '@sveltejs/adapter-static';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// Fully prerendered marketing site (prerender = true in +layout.ts) →
			// adapter-static emits a folder of HTML/CSS/JS to build/, which homeport
			// serves via Caddy file_server (no process). See homeport.yaml's static:.
			adapter: adapter()
		})
	]
});
