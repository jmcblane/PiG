import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Reuse RPC's status channel; PiG consumes this key instead of showing status text.
export default function (pi: ExtensionAPI) {
	const key = "pig:claude-usage";
	const prefix = "anthropic-ratelimit-unified-";
	let headers: Record<string, string> = {};

	pi.on("session_start", (_event, ctx) => {
		headers = {};
		ctx.ui.setStatus(key, undefined);
	});

	pi.on("after_provider_response", (event, ctx) => {
		if (ctx.model?.provider !== "claude-bridge") return;
		let changed = false;
		for (const [name, value] of Object.entries(event.headers)) {
			const lower = name.toLowerCase();
			if (/^anthropic-ratelimit-unified-(5h|7d|7d_oi)-(utilization|reset)$/.test(lower)) {
				headers[lower.slice(prefix.length)] = value;
				changed = true;
			}
		}
		if (changed) ctx.ui.setStatus(key, JSON.stringify(headers));
	});
}
