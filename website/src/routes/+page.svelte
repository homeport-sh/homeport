<script lang="ts">
	import { reveal } from '$lib/reveal';

	const install = 'curl -fsSL homeport.sh/install | sh';
	let copied = $state(false);

	async function copyInstall() {
		try {
			await navigator.clipboard.writeText(install);
			copied = true;
			setTimeout(() => (copied = false), 1600);
		} catch {
			/* clipboard blocked — no-op */
		}
	}

	// Why an off-the-shelf binary docks like your own code.
	const cargo = [
		{
			k: 'FETCH',
			t: 'Fetch, don’t compile',
			d: 'The build step is a plain curl. Any released binary — a headless browser, a metrics exporter, a game server — becomes the artifact homeport ships.'
		},
		{
			k: 'HARDEN',
			t: 'Docked like the rest',
			d: 'It still lands in a locked-down systemd unit behind Caddy, health-gated blue/green with sub-second rollback. Off-the-shelf, not off-the-leash.'
		},
		{
			k: 'SANDBOX',
			t: 'Brings its own sandbox',
			d: 'sandbox: relaxed hands back the namespaces Lightpanda needs to run its own Chromium sandbox. Every other app on the box stays strict.'
		}
	];

	// The real fleet deployed to one €6.49 box.
	const fleet = [
		{ app: 'hello', framework: 'Go', mem: '1 MB', port: 8100 },
		{ app: 'website', framework: 'SvelteKit', mem: '13 MB', port: 8101 },
		{ app: 'nuxt', framework: 'Nuxt', mem: '26 MB', port: 8102 },
		{ app: 'tanstack', framework: 'TanStack Start', mem: '17 MB', port: 8103 },
		{ app: 'next', framework: 'Next.js', mem: '81 MB', port: 8104 }
	];

	const stats = [
		{ n: '5', label: 'apps docked' },
		{ n: '4', label: 'frameworks' },
		{ n: '€6.49', label: 'per month' },
		{ n: '15%', label: 'memory used' },
		{ n: '0', label: 'Docker daemons' }
	];

	const steps = [
		{
			k: '01',
			cmd: 'homeport bootstrap <ip>',
			title: 'Harden the box',
			body: 'A fresh Ubuntu VPS becomes a locked-down host: firewall, key-only SSH, fail2ban, automatic security updates, Caddy for TLS. One command, idempotent.'
		},
		{
			k: '02',
			cmd: 'homeport init',
			title: 'Point at your app',
			body: 'Detects your framework — Go, Rust, Next, Nuxt, SvelteKit, TanStack Start — and writes a homeport.yaml with the right build command.'
		},
		{
			k: '03',
			cmd: 'homeport deploy',
			title: 'Ship it',
			body: 'Build the binary, upload it, health-check the new release, flip an atomic symlink. Bad deploy? It reverts itself. Good deploy? Live with HTTPS.'
		}
	];

	const features = [
		{
			t: 'No Docker',
			d: 'systemd + Caddy and nothing else. No daemon, no registry, no base-image CVE treadmill. The server runs your binary, not a container stack.'
		},
		{
			t: 'Zero-downtime deploys',
			d: 'The new release proves itself on a private port before Caddy flips traffic to it — blue/green for a single app, rolling for replicas. A failed build never reaches a user; the old one keeps serving, and rollback is a sub-second symlink flip.'
		},
		{
			t: 'Scale to zero, then out',
			d: 'Quiet apps sleep to near-zero RAM and wake on the first request in about half a second. Busy ones autoscale on CPU between a floor and a ceiling. Serverless economics on a box you rent for a few euros a month.'
		},
		{
			t: 'Zero-downtime migrations',
			d: 'A release hook runs your migration on the box before the new code goes live — and aborts the deploy if it fails. Heroku’s release phase, without Heroku.'
		},
		{
			t: 'Many apps, one domain',
			d: 'Mount services at paths behind a single host and certificate, or load-balance an internal service on loopback. An API gateway with nothing to install.'
		},
		{
			t: 'Hardened, per app',
			d: 'The box gets a firewall, key-only SSH and fail2ban on boot. Each app then runs in a locked-down systemd sandbox — dropped capabilities, a seccomp filter, memory and CPU caps, one writable directory.'
		},
		{
			t: 'Automatic HTTPS',
			d: 'Caddy fetches and renews a certificate per domain. Point an A record, deploy, and TLS is already on — sslip.io works if you don’t have a domain yet.'
		},
		{
			t: 'Binary or static',
			d: 'Ship a compiled binary — Go, Rust, or a bun-compiled Next, Nuxt, SvelteKit or TanStack Start — or point static: at a built folder and Caddy serves the files directly. SPA or multi-page is auto-detected; a landing page or docs site runs with no process at all.'
		},
		{
			t: 'Agent-ready',
			d: 'homeport mcp exposes deploy, rollback, status and the whole fleet view as MCP tools. Hand ops to an AI agent — with the same health-gated, auto-reverting safety you get.'
		}
	];

	const compare = [
		['On the server', 'systemd + Caddy + a bash helper', 'Docker + Postgres + Redis', 'Docker daemon'],
		['Platform RAM', '~0', '~2 GB baseline', 'Docker overhead'],
		['Ships to the box', 'one binary (scp)', 'containers (registry)', 'images (registry)'],
		['Zero-downtime deploys', 'blue/green + rolling, default', 'per-service config', 'rolling via proxy'],
		['Scale to zero', 'built in, socket-activated', 'no', 'no'],
		['Rollback', 'symlink flip, instant', 'redeploy container', 'redeploy image'],
		['Access to deploy', 'per-app scoped SSH keys', 'web UI + SSH', 'root SSH']
	];
</script>

<svelte:head>
	<title>Homeport — ship binaries to production</title>
	<meta
		name="description"
		content="Deploy single-binary web apps — Go, Rust, Next, Nuxt, SvelteKit, TanStack Start — to your own VPS. No Docker, no registry, no runtime on the server. Zero-downtime blue/green deploys, scale-to-zero, autoscaling and migrations — without Kubernetes."
	/>
	<link rel="canonical" href="https://homeport.sh/" />
	<meta name="theme-color" content="#05090d" />

	<!-- Open Graph -->
	<meta property="og:type" content="website" />
	<meta property="og:site_name" content="Homeport" />
	<meta property="og:url" content="https://homeport.sh/" />
	<meta property="og:title" content="Homeport — ship binaries to production" />
	<meta
		property="og:description"
		content="Single executable to a plain VPS. No Docker, no registry, nothing on the server. Zero-downtime deploys, scale-to-zero and migrations, standard."
	/>
	<meta property="og:image" content="https://homeport.sh/og.png" />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />

	<!-- Twitter -->
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Homeport — ship binaries to production" />
	<meta
		name="twitter:description"
		content="Single executable to a plain VPS. No Docker, no registry, nothing on the server. Zero-downtime deploys, scale-to-zero and migrations, standard."
	/>
	<meta name="twitter:image" content="https://homeport.sh/og.png" />
</svelte:head>

<!-- ================= NAV ================= -->
<header class="fixed top-0 z-50 w-full">
	<div
		class="mx-auto flex max-w-[1200px] items-center justify-between px-5 py-4"
		style="backdrop-filter: blur(8px); background: color-mix(in srgb, var(--color-ink) 55%, transparent); border-bottom: 1px solid var(--color-line);"
	>
		<a href="/" class="flex items-center gap-2.5">
			<span class="beacon"></span>
			<span class="display text-xl tracking-tight">Homeport</span>
		</a>
		<nav class="mono hidden items-center gap-7 text-sm text-mist md:flex">
			<a href="#how" class="transition-colors hover:text-foam">how</a>
			<a href="#fleet" class="transition-colors hover:text-foam">fleet</a>
			<a href="#features" class="transition-colors hover:text-foam">features</a>
			<a href="#compare" class="transition-colors hover:text-foam">vs</a>
		</nav>
		<div class="flex items-center gap-3">
			<a
				href="https://github.com/homeport-sh/homeport" target="_blank" rel="noopener noreferrer"
				class="mono hidden text-sm text-mist transition-colors hover:text-foam sm:block"
			>
				GitHub ↗
			</a>
			<a href="#install" class="btn btn-primary rounded-none">Deploy →</a>
		</div>
	</div>
</header>

<!-- ================= HERO ================= -->
<section class="relative mx-auto max-w-[1200px] px-5 pt-36 pb-20 md:pt-44">
	<p class="kicker hero-rise" style="--i: 0">Self-hosted · single binary · your VPS</p>

	<h1 class="display hero-rise mt-5 text-[clamp(3.4rem,11vw,9rem)]" style="--i: 1">
		Ship binaries<br />
		<span style="color: var(--color-signal)">to production.</span>
	</h1>

	<p class="hero-rise mt-7 max-w-2xl text-lg leading-relaxed text-mist md:text-xl" style="--i: 2">
		Deploy Go, Rust, Next, Nuxt, SvelteKit and TanStack Start apps to a plain VPS
		as a single executable — or serve a static site straight from a folder. No
		Docker. No registry. Nothing installed on the server. One command hardens the
		box — one command deploys. Zero-downtime releases, scale-to-zero and
		migrations come standard.
	</p>

	<div class="hero-rise mt-9 flex flex-wrap items-center gap-3" style="--i: 3">
		<button
			onclick={copyInstall}
			class="btn btn-ghost rounded-none"
			aria-label="Copy install command"
		>
			<span class="text-signal">$</span>
			<span>{install}</span>
			<span class="ml-1 text-mist-dim">{copied ? '✓ copied' : '⧉'}</span>
		</button>
		<a href="https://github.com/homeport-sh/homeport" target="_blank" rel="noopener noreferrer" class="btn btn-primary rounded-none">
			Read the docs →
		</a>
	</div>

	<!-- terminal -->
	<div class="hero-rise mt-14" style="--i: 4">
		<div class="panel ticked mx-auto max-w-3xl rounded-none">
			<div class="hair-b flex items-center gap-2 px-4 py-2.5">
				<span class="term-dot" style="background: var(--color-alarm)"></span>
				<span class="term-dot" style="background: var(--color-flare)"></span>
				<span class="term-dot" style="background: var(--color-signal)"></span>
				<span class="mono ml-3 text-xs text-mist-dim">deploy — drydock</span>
			</div>
			<div class="mono overflow-x-auto p-5 text-sm leading-7">
				<div><span class="text-mist-dim">$</span> homeport bootstrap 178.105.67.23</div>
				<div class="text-mist">
					<span class="text-signal">==&gt;</span> hardening · Caddy · homeportd ✓
				</div>
				<div class="mt-2"><span class="text-mist-dim">$</span> homeport init</div>
				<div class="text-mist">
					<span class="text-signal">==&gt;</span> detected sveltekit — wrote homeport.yaml
				</div>
				<div class="mt-2"><span class="text-mist-dim">$</span> homeport deploy</div>
				<div class="text-mist">
					<span class="text-signal">==&gt;</span> build → upload → health-checked activate
				</div>
				<div style="color: var(--color-signal)">
					deployed → https://app.example.com<span class="caret"></span>
				</div>
			</div>
		</div>
	</div>
</section>

<!-- ================= STAT BAND ================= -->
<section class="relative">
	<div
		class="mx-auto grid max-w-[1200px] grid-cols-2 md:grid-cols-5"
		style="border-top: 1px solid var(--color-line); border-bottom: 1px solid var(--color-line);"
	>
		{#each stats as s, i (s.label)}
			<div
				use:reveal={i * 70}
				class="rise flex flex-col gap-1 px-5 py-8"
				style="border-right: 1px solid var(--color-line);"
			>
				<span class="display text-5xl md:text-6xl" style="color: var(--color-foam)">{s.n}</span>
				<span class="mono text-xs tracking-wide text-mist-dim uppercase">{s.label}</span>
			</div>
		{/each}
		<div
			class="mono hidden items-center gap-2 px-5 py-8 text-xs text-mist md:col-span-5 md:flex"
			style="border-top: 1px solid var(--color-line);"
		>
			<span class="beacon"></span>
			Real numbers — five production apps across four frameworks, live on one €6.49
			Hetzner box, 85% of it still idle.
		</div>
	</div>
</section>

<!-- ================= HOW ================= -->
<section id="how" class="mx-auto max-w-[1200px] px-5 py-24 md:py-32">
	<div use:reveal class="rise flex items-end justify-between gap-6">
		<h2 class="display text-[clamp(2.4rem,6vw,4.5rem)]">Three commands<br />to a live app</h2>
		<span class="mono mb-2 hidden text-xs text-mist-dim md:block">01 → 03</span>
	</div>

	<div class="mt-14 grid gap-5 md:grid-cols-3">
		{#each steps as step, i (step.k)}
			<div use:reveal={i * 90} class="rise panel ticked rounded-none p-7">
				<div class="flex items-baseline justify-between">
					<span class="display text-6xl" style="color: var(--color-line-bright)">{step.k}</span>
					<span class="beacon"></span>
				</div>
				<div
					class="mono mt-5 inline-block px-2.5 py-1.5 text-xs"
					style="background: var(--color-ink); border: 1px solid var(--color-line); color: var(--color-signal);"
				>
					$ {step.cmd}
				</div>
				<h3 class="display mt-5 text-2xl">{step.title}</h3>
				<p class="mt-3 text-sm leading-relaxed text-mist">{step.body}</p>
			</div>
		{/each}
	</div>
</section>

<!-- ================= FLEET ================= -->
<section id="fleet" class="relative">
	<div class="mx-auto max-w-[1200px] px-5 py-24 md:py-32">
		<div use:reveal class="rise">
			<p class="kicker">The harbor</p>
			<h2 class="display mt-4 text-[clamp(2.4rem,6vw,4.5rem)]">One box.<br />The whole fleet.</h2>
			<p class="mt-5 max-w-xl text-mist">
				Every vessel below is a real app compiled to a single binary and docked on
				the same server — each in its own hardened systemd unit, served from memory
				behind Caddy.
			</p>
		</div>

		<div use:reveal class="rise panel ticked mt-12 rounded-none">
			<div
				class="mono hair-b hidden grid-cols-12 gap-4 px-6 py-3 text-xs tracking-wide text-mist-dim uppercase md:grid"
			>
				<span class="col-span-1"></span>
				<span class="col-span-4">app</span>
				<span class="col-span-4">framework</span>
				<span class="col-span-2">memory</span>
				<span class="col-span-1 text-right">port</span>
			</div>
			{#each fleet as v, i (v.app)}
				<div
					class="grid grid-cols-12 items-center gap-4 px-6 py-4 transition-colors"
					style={i < fleet.length - 1 ? 'border-bottom: 1px solid var(--color-line);' : ''}
				>
					<span class="col-span-2 md:col-span-1"><span class="beacon"></span></span>
					<span class="mono col-span-10 text-sm md:col-span-4" style="color: var(--color-foam)">
						{v.app}
					</span>
					<span class="col-span-6 text-sm text-mist md:col-span-4">{v.framework}</span>
					<span class="mono col-span-4 text-sm text-signal md:col-span-2">{v.mem}</span>
					<span class="mono col-span-2 text-right text-sm text-mist-dim md:col-span-1">
						:{v.port}
					</span>
				</div>
			{/each}
			<div
				class="mono flex items-center justify-between px-6 py-3 text-xs text-mist-dim"
				style="border-top: 1px solid var(--color-line);"
			>
				<span>5 active · 0 failed</span>
				<span>host memory: 559 MB / 3.8 GB</span>
			</div>
		</div>
	</div>
</section>

<!-- ================= FEATURES ================= -->
<section id="features" class="mx-auto max-w-[1200px] px-5 py-24 md:py-32">
	<div use:reveal class="rise">
		<p class="kicker">Why it holds up</p>
		<h2 class="display mt-4 text-[clamp(2.4rem,6vw,4.5rem)]">Batteries, no bloat</h2>
	</div>
	<div class="mt-14 grid gap-px md:grid-cols-3" style="background: var(--color-line);">
		{#each features as f, i (f.t)}
			<div
				use:reveal={(i % 3) * 80}
				class="rise p-8"
				style="background: linear-gradient(180deg, var(--color-berth), var(--color-hull));"
			>
				<div class="flex items-center gap-2.5">
					<span class="mono text-xs" style="color: var(--color-flare)"
						>{String(i + 1).padStart(2, '0')}</span
					>
					<h3 class="display text-2xl">{f.t}</h3>
				</div>
				<p class="mt-3 text-sm leading-relaxed text-mist">{f.d}</p>
			</div>
		{/each}
	</div>
</section>

<!-- ================= ANY BINARY ================= -->
<section id="cargo" class="mx-auto max-w-[1200px] px-5 py-24 md:py-32">
	<div use:reveal class="rise max-w-2xl">
		<p class="kicker">Off-the-shelf</p>
		<h2 class="display mt-4 text-[clamp(2.4rem,6vw,4.5rem)]">Cargo you<br />didn’t build</h2>
		<p class="mt-5 max-w-xl text-mist">
			Homeport ships whatever your build step produces — and that needn’t be your
			own code. Point the build at a released binary and it docks like any other
			vessel: one hardened unit, HTTPS, health-gated deploys. Here’s the Lightpanda
			headless browser, live straight from its GitHub release.
		</p>
	</div>

	<div class="mt-12 grid gap-5 lg:grid-cols-5">
		<!-- the manifest -->
		<div use:reveal class="rise panel ticked rounded-none lg:col-span-3">
			<div class="hair-b flex items-center gap-2 px-4 py-2.5">
				<span class="term-dot" style="background: var(--color-alarm)"></span>
				<span class="term-dot" style="background: var(--color-flare)"></span>
				<span class="term-dot" style="background: var(--color-signal)"></span>
				<span class="mono ml-3 text-xs text-mist-dim">homeport.yaml — cargo manifest</span>
			</div>
<pre class="mono overflow-x-auto p-5 text-[0.8rem] leading-7 text-foam"><span class="text-mist">app:</span> lightpanda
<span class="text-mist">server:</span> deploy@vps
<span class="text-mist">domain:</span> browser.example.com

<span class="text-mist-dim"># the build just fetches a release — no compile step</span>
<span class="text-mist">build:</span>
  <span class="text-mist">command:</span> <span class="text-signal">curl</span> -fsSL github.com/lightpanda-io/…/lightpanda-x86_64-linux <span class="text-signal">-o</span> server
  <span class="text-mist">artifact:</span> server

<span class="text-mist">run:</span> serve --host <span style="color: var(--color-flare)">&#123;HOST&#125;</span> --port <span style="color: var(--color-flare)">&#123;PORT&#125;</span>
<span class="text-mist">sandbox:</span> <span style="color: var(--color-flare)">relaxed</span>   <span class="text-mist-dim"># runs its own browser sandbox</span></pre>
		</div>

		<!-- why it works -->
		<div class="flex flex-col justify-center gap-7 lg:col-span-2">
			{#each cargo as c, i (c.k)}
				<div
					use:reveal={i * 90}
					class="rise pl-4"
					style="border-left: 2px solid var(--color-line-bright);"
				>
					<div class="mono text-xs tracking-widest text-signal">{c.k}</div>
					<h3 class="display mt-2 text-xl">{c.t}</h3>
					<p class="mt-1.5 text-sm leading-relaxed text-mist">{c.d}</p>
				</div>
			{/each}
		</div>
	</div>
</section>

<!-- ================= COMPARE ================= -->
<section id="compare" class="mx-auto max-w-[1200px] px-5 py-24 md:py-32">
	<div use:reveal class="rise mb-12">
		<h2 class="display text-[clamp(2.4rem,6vw,4.5rem)]">The difference<br />is the server</h2>
		<p class="mt-5 max-w-xl text-mist">
			Everyone can deploy an app. The question is what's left running on the box
			afterward — and how many apps fit before it fills up.
		</p>
	</div>

	<!-- overflow-x-auto is for phones (table min-w). On md+ the table fits but
	     border-collapse rounds it 1px wide, which would summon a do-nothing
	     scrollbar pair — clip swallows that pixel instead. -->
	<div use:reveal class="rise panel ticked overflow-x-auto md:overflow-x-clip rounded-none">
		<table class="w-full min-w-[640px] border-collapse text-left">
			<thead>
				<tr class="mono text-xs tracking-wide text-mist-dim uppercase">
					<th class="hair-b px-6 py-4 font-medium"></th>
					<th class="hair-b px-6 py-4 font-medium" style="color: var(--color-signal)">Homeport</th>
					<th class="hair-b px-6 py-4 font-medium">Coolify</th>
					<th class="hair-b px-6 py-4 font-medium">Kamal</th>
				</tr>
			</thead>
			<tbody class="text-sm">
				{#each compare as row (row[0])}
					<tr>
						<td class="px-6 py-4 text-mist-dim" style="border-bottom: 1px solid var(--color-line);">
							{row[0]}
						</td>
						<td
							class="mono px-6 py-4"
							style="border-bottom: 1px solid var(--color-line); color: var(--color-foam);"
						>
							{row[1]}
						</td>
						<td class="px-6 py-4 text-mist" style="border-bottom: 1px solid var(--color-line);">
							{row[2]}
						</td>
						<td class="px-6 py-4 text-mist" style="border-bottom: 1px solid var(--color-line);">
							{row[3]}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
</section>

<!-- ================= FINAL CTA ================= -->
<section id="install" class="relative mx-auto max-w-[1200px] px-5 py-28 md:py-40">
	<div use:reveal class="rise flex flex-col items-center text-center">
		<span class="beacon mb-8" style="width: 0.8rem; height: 0.8rem;"></span>
		<h2 class="display text-[clamp(3rem,9vw,7rem)]">Dock your app.</h2>
		<p class="mt-6 max-w-lg text-lg text-mist">
			A cheap VPS, three commands, and your app is live with HTTPS. Your app, docked.
		</p>

		<button
			onclick={copyInstall}
			class="panel ticked mono mt-10 flex items-center gap-3 rounded-none px-6 py-4 text-left text-sm md:text-base"
			aria-label="Copy install command"
		>
			<span class="text-signal">$</span>
			<span style="color: var(--color-foam)">{install}</span>
			<span class="ml-2 text-mist-dim">{copied ? '✓' : '⧉'}</span>
		</button>

		<div class="mt-8 flex flex-wrap justify-center gap-3">
			<a href="https://github.com/homeport-sh/homeport" target="_blank" rel="noopener noreferrer" class="btn btn-primary rounded-none">
				Get started →
			</a>
			<a href="#fleet" class="btn btn-ghost rounded-none">See the fleet</a>
		</div>
	</div>
</section>

<!-- ================= FOOTER ================= -->
<footer style="border-top: 1px solid var(--color-line);">
	<div
		class="mx-auto flex max-w-[1200px] flex-col gap-6 px-5 py-12 md:flex-row md:items-center md:justify-between"
	>
		<div class="flex items-center gap-2.5">
			<span class="beacon"></span>
			<span class="display text-lg">Homeport</span>
			<span class="mono ml-2 text-xs text-mist-dim">the fastest way to ship binaries</span>
		</div>
		<div class="mono flex flex-wrap gap-6 text-sm text-mist">
			<a href="https://github.com/homeport-sh/homeport" target="_blank" rel="noopener noreferrer" class="hover:text-foam">GitHub</a>
			<a href="https://www.npmjs.com/package/svelte-bun-compile" target="_blank" rel="noopener noreferrer" class="hover:text-foam">
				svelte-bun-compile
			</a>
			<a href="https://www.npmjs.com/package/next-bun-compile" target="_blank" rel="noopener noreferrer" class="hover:text-foam">
				next-bun-compile
			</a>
			<span class="text-mist-dim">MIT</span>
		</div>
	</div>
	<div class="mx-auto max-w-[1200px] px-5 pb-8">
		<p class="mono text-xs text-mist-dim">
			This site is a prerendered SvelteKit build, served as static files by
			Homeport on a cheap VPS — no process, no runtime, just Caddy.
		</p>
	</div>
</footer>
