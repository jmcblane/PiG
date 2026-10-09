import Foundation

// Trusted host document and isolated-world bootstrap. Generated markup remains
// in an opaque-origin iframe; it cannot access the native message handler.
enum HTMLWidgetDocument {
    static let worldName = "PiG.HTMLWidget"
    static let handlerName = "pigWidget"
    static let contentRules = """
    [
      {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}
    ]
    """
    static let disableWebRTC = """
    for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCIceTransport']) {
      Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false });
    }
    """

    static func bootstrap(generation: String) -> String {
        // The native-generated UUID is not controlled by the HTML or the model.
        """
        (() => {
          if (window === window.top || location.href !== 'about:srcdoc') return;
          const root = document.getElementById('pig-widget-root');
          if (!root) return;
          const post = body => window.webkit.messageHandlers.pigWidget.postMessage({...body, generation: '\(generation)'});
          let scheduled = false, lastHeight = -1;
          const measure = () => {
            scheduled = false;
            const height = Math.ceil(Math.max(root.getBoundingClientRect().height, root.scrollHeight));
            if (height !== lastHeight) { lastHeight = height; post({kind: 'height', height}); }
          };
          const schedule = () => {
            if (!scheduled) { scheduled = true; setTimeout(measure, 16); }
          };
          new ResizeObserver(schedule).observe(root);
          new MutationObserver(schedule).observe(root, {subtree: true, childList: true, attributes: true, characterData: true});
          addEventListener('load', schedule);
          document.fonts.ready.then(schedule);
          document.addEventListener('click', event => {
            if (!event.isTrusted || !(event.target instanceof Element)) return;
            const button = event.target.closest('button[data-pig-action]');
            if (!button || button.disabled || !root.contains(button)) return;
            const id = button.getAttribute('data-pig-action');
            if (/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/.test(id)) post({kind: 'action', id});
          }, true);
          schedule();
        })();
        """
    }

    static func make(artifact: HTMLArtifact, theme: AppThemeChoice, textSizeStep: Int) -> String {
        let palette = theme.palette
        let scale = Double(TextSizePreference.steps[min(max(textSizeStep, 0), TextSizePreference.steps.count - 1)])
        let colorScheme = palette.background.relativeLuminance < 0.5 ? "dark" : "light"
        let accentForeground = palette.accent.relativeLuminance > 0.179 ? "#000000" : "#ffffff"
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
        let child = """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(policy) frame-src 'none';">
        <style>
          :root {
            color-scheme: \(colorScheme);
            --pig-bg: \(palette.background.hex); --pig-fg: \(palette.text.hex);
            --pig-muted: \(palette.muted.hex); --pig-accent: \(palette.accent.hex);
            --pig-panel: \(palette.panel.hex); --pig-border: \(palette.line.hex);
            --pig-control-bg: \(palette.panel2.hex); --pig-accent-fg: \(accentForeground);
          }
          * { box-sizing: border-box; }
          html, body { margin: 0; padding: 0; min-height: 0; height: auto; background: var(--pig-bg); }
          body { color: var(--pig-fg); font: \(15.5 * scale)px -apple-system, BlinkMacSystemFont, sans-serif; overflow-x: hidden; }
          #pig-widget-root { display: flow-root; padding: 4px; overflow-wrap: anywhere; }
          .pig-controls, [role="group"] { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
          button, input, select, textarea { font: inherit; font-size: \(13 * scale)px; }
          button {
            display: inline-flex; align-items: center; justify-content: center; gap: 6px;
            padding: 6px 12px; border: 1px solid var(--pig-border); border-radius: 7px;
            background: var(--pig-control-bg); color: var(--pig-fg); line-height: 1.3; cursor: pointer;
          }
          button:hover { border-color: var(--pig-muted); }
          button:active { filter: brightness(0.9); }
          button:disabled { opacity: 0.5; cursor: default; }
          button.pig-primary { background: var(--pig-accent); border-color: var(--pig-accent); color: var(--pig-accent-fg); }
          button.pig-link { border: 0; padding: 0; background: transparent; color: var(--pig-accent); }
          :is(button, input, select, textarea):focus-visible { outline: 2px solid var(--pig-accent); outline-offset: 2px; }
          input, select, textarea { accent-color: var(--pig-accent); }
          input:not([type="range"]):not([type="checkbox"]):not([type="radio"]), select, textarea {
            padding: 6px 8px; border: 1px solid var(--pig-border); border-radius: 6px;
            background: var(--pig-control-bg); color: var(--pig-fg);
          }
          a { color: var(--pig-accent); }
        </style></head><body><div id="pig-widget-root">\(artifact.html)</div></body></html>
        """
        return """
        <!doctype html><html><head>
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(policy) frame-src about:;">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:\(palette.background.hex)}iframe{display:block;width:100%;height:100%;border:0;background:transparent}</style>
        </head><body><iframe title="\(escape(artifact.title))" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="\(escape(child))"></iframe></body></html>
        """
    }

    private static func escape(_ html: String) -> String {
        html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
