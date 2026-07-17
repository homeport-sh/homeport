/**
 * Svelte action: adds the `in` class when the element scrolls into view,
 * driving the `.rise` reveal transition. One-shot (unobserves after reveal),
 * and a no-op for users who prefer reduced motion (they see content instantly
 * because `.rise` is neutralized in CSS).
 */
export function reveal(node: HTMLElement, delay = 0) {
	if (typeof IntersectionObserver === 'undefined') {
		node.classList.add('in');
		return {};
	}
	const io = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				if (entry.isIntersecting) {
					node.style.transitionDelay = `${delay}ms`;
					node.classList.add('in');
					io.unobserve(node);
				}
			}
		},
		{ threshold: 0.15, rootMargin: '0px 0px -8% 0px' }
	);
	io.observe(node);
	return {
		destroy() {
			io.disconnect();
		}
	};
}
