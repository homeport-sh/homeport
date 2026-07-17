// The marketing site is fully static — prerender every route to HTML at build
// time so the compiled binary serves it from memory (with content-hash ETags
// and 304s) instead of running SSR on each request. Client JS (copy button,
// scroll reveals) still hydrates normally on top of the prerendered markup.
export const prerender = true;
