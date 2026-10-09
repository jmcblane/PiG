import { createHash } from "node:crypto";
import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const maxHTMLBytes = 256 * 1024;
const actionSchema = Type.Object({
	id: Type.String({ description: "Action ID used by a button's data-pig-action attribute", pattern: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$" }),
	message: Type.String({ description: "Exact chat message PiG will show for confirmation before sending to the agent", minLength: 1, maxLength: 2000 }),
});

// Loaded explicitly by PiG, not installed in pi's user or project directories.
export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "html_render",
		label: "Render interactive controls",
		description:
			"Create a small interactive HTML fragment that blends into PiG's native chat between Markdown paragraphs. " +
			"Keep explanations, headings, notes, and recommendations in your normal reply, NOT in the HTML. " +
			"Do not build a full webpage, dashboard shell, card wrapper, title bar, or viewport-sized layout. " +
			"PiG supplies compact themed buttons, inputs, typography, spacing, and automatic height. " +
			"Use inline CSS/JavaScript only for the interactive piece; inline SVG and data URLs work. " +
			"Local JavaScript can manipulate the UI. To optionally send a chat message, declare an action and use " +
			'<button data-pig-action="action-id">Label</button>. PiG confirms the declared message before sending; ' +
			"JavaScript cannot send arbitrary messages or access native APIs. State is temporary, not saved. " +
			"Network, external dependencies, local files, forms, popups, and WebRTC are blocked. " +
			"After this tool returns, insert its exact [[pig-ui:...]] marker on its own line between paragraphs of your reply, outside code fences.",
		promptGuidelines: [
			"Use html_render for small interactive controls, not for prose or full webpages. Keep notes and explanations in Markdown.",
			"Insert each returned [[pig-ui:...]] marker on its own line where its controls belong in your answer. Never put the marker in a code fence.",
			"Use PiG's default control styles; avoid body backgrounds, enclosing cards, fixed/minimum viewport heights, and redundant titles.",
		],
		parameters: Type.Object({
			title: Type.Optional(Type.String({ description: "Accessible name for the controls (not a visible heading)", minLength: 1, maxLength: 120 })),
			html: Type.String({ description: "Small self-contained HTML fragment, not a full document (maximum 256 KiB UTF-8)", minLength: 1, maxLength: maxHTMLBytes }),
			height: Type.Optional(Type.Integer({ description: "Initial height hint only; PiG measures the actual content height", minimum: 1, maximum: 1000 })),
			actions: Type.Optional(Type.Array(actionSchema, { description: "Optional allowlisted chat-message actions, triggered by data-pig-action buttons", maxItems: 16 })),
		}),
		async execute(toolCallId: string, params: { title?: string; html: string; height?: number; actions?: { id: string; message: string }[] }) {
			if (Buffer.byteLength(params.html, "utf8") > maxHTMLBytes) {
				throw new Error("HTML exceeds the 256 KiB limit. Use a smaller self-contained fragment.");
			}
			if (!params.html.trim()) throw new Error("HTML must not be empty.");
			const actions = params.actions ?? [];
			if (new Set(actions.map((action) => action.id)).size !== actions.length) {
				throw new Error("Action IDs must be unique within a widget.");
			}
			if (actions.some((action) => !action.message.trim() || /^\s*[!/]/.test(action.message))) {
				throw new Error("Actions must contain ordinary chat messages, not shell or slash commands.");
			}
			const reference = createHash("sha256").update(toolCallId).digest("hex").slice(0, 16);
			const title = params.title?.trim() || "Interactive controls";
			return {
				content: [{ type: "text", text: `Controls ready. Insert [[pig-ui:${reference}]] on its own line between paragraphs in your normal Markdown reply. Keep your explanation outside the HTML.` }],
				details: {
					pigHtml: { version: 2, reference, title, html: params.html, height: params.height ?? 44, actions },
				},
			};
		},
	});
}
