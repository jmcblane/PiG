#!/usr/bin/env python3
"""Seed a fake PiG home with projects, agents and sessions for README screenshots."""
import json, os, subprocess, sys, uuid, itertools
from pathlib import Path
from datetime import datetime, timedelta, timezone

ROOT = str(Path(sys.argv[1]).resolve())
HTML_SRC = Path(__file__).with_name("demo-color-studio.html")
NOW = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=2)
PROVIDER, MODEL = "openai-codex", "gpt-6.1-sol"

SUPPORT = f"{ROOT}/Library/Application Support/PiG"
SESSIONS = f"{ROOT}/.pi/agent/sessions"
os.makedirs(SUPPORT)
os.makedirs(SESSIONS)
AGENT = f"{ROOT}/.pi/agent"
json.dump({"defaultProvider": PROVIDER, "defaultModel": MODEL, "defaultThinkingLevel": "medium",
           "quietStartup": True}, open(f"{AGENT}/settings.json", "w"))

# --- projects with real files -------------------------------------------------
FILES = {
    "Code/lumen": {
        "package.json": '{\n  "name": "lumen",\n  "private": true,\n  "scripts": {\n    "dev": "vite",\n    "test": "vitest"\n  }\n}\n',
        "README.md": "# Lumen\n\nA self-hosted photo gallery.\n",
        "src/main.ts": "import { mountGallery } from './gallery/Grid'\n\nmountGallery(document.getElementById('app')!)\n",
        "src/gallery/Grid.tsx": "export function Grid() {}\n",
        "src/gallery/Thumbnail.tsx": "export function Thumbnail() {}\n",
        "src/gallery/useVisible.ts": "export function useVisible() {}\n",
        "src/upload/Uploader.tsx": "export function Uploader() {}\n",
        "src/styles/theme.css": ":root {}\n",
        "tests/upload.test.ts": "test('uploads', () => {})\n",
        "vite.config.ts": "export default {}\n",
    },
    "Code/tidepool": {
        "Cargo.toml": '[package]\nname = "tidepool"\nversion = "0.3.0"\n',
        "src/main.rs": "fn main() {}\n",
        "src/noaa.rs": "",
        "src/table.rs": "",
        "README.md": "# tidepool\n",
    },
    "Code/field-notes": {
        "config.toml": "title = 'Field Notes'\n",
        "content/posts/sourdough-timings.md": "",
        "content/posts/winter-garden.md": "",
        "templates/post.html": "",
    },
}
for project, files in FILES.items():
    for rel, text in files.items():
        path = f"{ROOT}/{project}/{rel}"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(text)
    subprocess.run(["git", "init", "-q", f"{ROOT}/{project}"], check=True)

LUMEN, TIDEPOOL, NOTES = (f"{ROOT}/Code/{p}" for p in ("lumen", "tidepool", "field-notes"))
QUICK = f"{SUPPORT}/Quick Chats"
AGENT_DIR = f"{SUPPORT}/Agents/ada"
os.makedirs(QUICK)
os.makedirs(AGENT_DIR)

ref = (NOW - datetime(2001, 1, 1, tzinfo=timezone.utc)).total_seconds()
projects = [
    {"path": LUMEN, "displayName": "lumen", "lastOpened": ref, "isPinned": True, "pinnedSortIndex": 0},
    {"path": TIDEPOOL, "displayName": "tidepool", "lastOpened": ref - 3600, "isPinned": True, "pinnedSortIndex": 1},
    {"path": NOTES, "displayName": "field-notes", "lastOpened": ref - 7200, "isPinned": False, "pinnedSortIndex": 0},
]
json.dump(projects, open(f"{SUPPORT}/projects.json", "w"))

agents = [{
    "backend": "pi", "id": "ada", "name": "Ada", "role": "Reads papers and RFCs",
    "modelID": f"{PROVIDER}/{MODEL}", "thinking": "medium", "skills": [],
    "look": {"accentColor": "#3a86ff", "accessory": "glasses", "hair": "#7a4424", "hairStyle": "ponytail",
             "happy": True, "pants": "#3d5a80", "shirt": "#457b9d", "shoes": "#2d2d2d",
             "skin": "#dca47a", "top": "collar"},
}]
json.dump(agents, open(f"{SUPPORT}/agents.json", "w"), indent=2)

# --- session writer -------------------------------------------------------------
ids = (f"{n:08x}" for n in itertools.count(0x1a2b3c00))
tool_ids = (f"toolu_{n:06d}" for n in itertools.count(1))


class Session:
    def __init__(self, cwd, name, start, model=MODEL):
        self.cwd, self.t, self.model = cwd, start, model
        self.uuid = str(uuid.uuid4())
        self.entries, self.parent = [], None
        self.add({"type": "model_change", "provider": PROVIDER, "modelId": model})
        self.add({"type": "thinking_level_change", "thinkingLevel": "medium"})
        self.name = name
        self.tokens = 18000

    def stamp(self, seconds=8):
        self.t += timedelta(seconds=seconds)
        return self.t.isoformat(timespec="milliseconds").replace("+00:00", "Z")

    def add(self, entry, seconds=2):
        entry = {"type": entry.pop("type"), "id": next(ids), "parentId": self.parent,
                 "timestamp": self.stamp(seconds), **entry}
        self.entries.append(entry)
        self.parent = entry["id"]
        return entry

    def msg(self, message, seconds):
        message["timestamp"] = int(self.t.timestamp() * 1000)
        return self.add({"type": "message", "message": message}, seconds)

    def user(self, text):
        self.msg({"role": "user", "content": [{"type": "text", "text": text}]}, 40)

    def assistant(self, text=None, tools=(), thinking=None, seconds=6):
        content = []
        if thinking:
            content.append({"type": "thinking", "thinking": thinking})
        if text:
            content.append({"type": "text", "text": text})
        calls = []
        for name, args, *_ in tools:
            call = {"type": "toolCall", "id": next(tool_ids), "name": name, "arguments": args}
            calls.append(call)
            content.append(call)
        self.tokens += 2400
        self.msg({"role": "assistant", "content": content, "api": "openai-codex-responses",
                  "provider": PROVIDER, "model": self.model,
                  "usage": {"input": self.tokens, "output": 600, "cacheRead": 0, "cacheWrite": 0,
                            "totalTokens": self.tokens + 600,
                            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}},
                  "stopReason": "toolUse" if tools else "stop"}, seconds)
        for call, (name, args, result, *details) in zip(calls, tools):
            message = {"role": "toolResult", "toolCallId": call["id"], "toolName": name,
                       "content": [{"type": "text", "text": result}], "isError": False}
            if details:
                message["details"] = details[0]
            self.msg(message, 3)

    def write(self):
        self.add({"type": "session_info", "name": self.name}, 1)
        start = self.entries[0]["timestamp"]
        folder = f"{SESSIONS}/--{self.cwd.strip('/').replace('/', '-')}--"
        os.makedirs(folder, exist_ok=True)
        path = f"{folder}/{start.replace(':', '-').replace('.', '-', 1)}_{self.uuid}.jsonl"
        header = {"type": "session", "version": 3, "id": self.uuid, "timestamp": start, "cwd": self.cwd}
        with open(path, "w") as f:
            for entry in [header] + self.entries:
                f.write(json.dumps(entry, separators=(",", ":"), ensure_ascii=False) + "\n")
        mtime = self.t.timestamp()
        os.utime(path, (mtime, mtime))
        return path


agent_sessions = {}

# 1. Lumen: lazy loading (the showcase chat)
s = Session(LUMEN, "Lazy-load gallery thumbnails", NOW - timedelta(minutes=22))
s.user("The gallery grid loads every thumbnail up front and the first paint takes ages on big albums. Can you lazy-load them?")
s.assistant("I'll look at how the grid renders thumbnails first.", [
    ("bash", {"command": "rg -n 'Thumbnail' src --glob '*.tsx' | head"},
     "src/gallery/Grid.tsx:3:import { Thumbnail } from './Thumbnail'\nsrc/gallery/Grid.tsx:21:        <Thumbnail key={photo.id} photo={photo} />"),
    ("read", {"path": "src/gallery/Thumbnail.tsx"},
     "export function Thumbnail({ photo }: Props) {\n  return <img className=\"thumb\" src={photo.thumbUrl} alt={photo.title} />\n}\n"),
    ("read", {"path": "src/gallery/useVisible.ts"}, "export function useVisible() {}\n"),
], thinking="The grid maps every photo to an <img> with src set immediately. An IntersectionObserver hook already exists as a stub.")
s.assistant(None, [
    ("edit", {"path": "src/gallery/useVisible.ts", "edits": [{"oldText": "export function useVisible() {}", "newText": "export function useVisible(ref, margin = '400px') { /* ... */ }"}]},
     f"Successfully replaced 1 block(s) in src/gallery/useVisible.ts.",
     {"diff": "-1 export function useVisible() {}\n+1 export function useVisible<T extends Element>(ref: RefObject<T>, margin = '400px') {\n+2   const [visible, setVisible] = useState(false)\n+3   useEffect(() => {\n+4     const node = ref.current\n+5     if (!node) return\n+6     const observer = new IntersectionObserver(([entry]) => {\n+7       if (entry.isIntersecting) { setVisible(true); observer.disconnect() }\n+8     }, { rootMargin: margin })\n+9     observer.observe(node)\n+10     return () => observer.disconnect()\n+11   }, [ref, margin])\n+12   return visible\n+13 }", "firstChangedLine": 1}),
    ("edit", {"path": "src/gallery/Thumbnail.tsx", "edits": [{"oldText": "src={photo.thumbUrl}", "newText": "src={visible ? photo.thumbUrl : undefined}"}]},
     f"Successfully replaced 1 block(s) in src/gallery/Thumbnail.tsx.",
     {"diff": "-2   return <img className=\"thumb\" src={photo.thumbUrl} alt={photo.title} />\n+2   const ref = useRef<HTMLImageElement>(null)\n+3   const visible = useVisible(ref)\n+4   return <img ref={ref} className=\"thumb\" src={visible ? photo.thumbUrl : undefined} alt={photo.title} />", "firstChangedLine": 2}),
    ("bash", {"command": "npm test -- gallery"},
     " ✓ tests/gallery.test.ts (6 tests) 412ms\n\n Test Files  1 passed (1)\n      Tests  6 passed (6)"),
], seconds=20)
s.assistant(
    "Thumbnails now load as they approach the viewport.\n\n"
    "- **`useVisible`** (`src/gallery/useVisible.ts`) wraps an `IntersectionObserver` with a 400px margin, "
    "so images start loading just before they scroll into view, then disconnects.\n"
    "- **`Thumbnail`** leaves `src` unset until the hook reports it visible.\n\n"
    "```tsx\nconst ref = useRef<HTMLImageElement>(null)\nconst visible = useVisible(ref)\n"
    "return <img ref={ref} className=\"thumb\" src={visible ? photo.thumbUrl : undefined} />\n```\n\n"
    "The gallery tests pass (6/6). On the 2,400-photo fixture album the first paint drops from about "
    "3.1s to 0.4s. One caveat: unloaded thumbnails have no height, so the grid can jump while scrolling. "
    "Want me to reserve space with `aspect-ratio` from the photo metadata?", seconds=10)
lazy = s.write()

# 2. Lumen: flaky upload test
s = Session(LUMEN, "Fix flaky upload test", NOW - timedelta(hours=3))
s.user("tests/upload.test.ts fails about one run in five on CI. Find out why.")
s.assistant("Running it in a loop to reproduce.", [
    ("bash", {"command": "for i in $(seq 20); do npx vitest run tests/upload.test.ts >/dev/null || echo fail $i; done"}, "fail 4\nfail 13\nfail 17"),
])
s.assistant("The test awaits `uploader.start()` but asserts before the progress event fires. "
            "I replaced the fixed `setTimeout(50)` with `await vi.waitFor(...)`; 100 runs pass.")
upload = s.write()

# 3. Tidepool: NOAA parsing
s = Session(TIDEPOOL, "Parse NOAA tide tables", NOW - timedelta(hours=1, minutes=10))
s.user("Add a parser for NOAA's annual tide prediction CSV. Highs and lows only.")
s.assistant("Reading the sample file and the existing table type.", [
    ("bash", {"command": "head -4 fixtures/9414290_annual.csv"}, "Date Time, Prediction, Type\n2026-01-01 03:12, 5.82, H\n2026-01-01 09:47, 1.04, L\n2026-01-01 15:30, 4.71, H"),
    ("read", {"path": "src/table.rs"}, "pub struct Tide { pub at: NaiveDateTime, pub feet: f32, pub kind: Kind }"),
])
s.assistant("Added `noaa::parse_annual` returning `Vec<Tide>`. It skips the header, trims fields, and maps `H`/`L` to `Kind`. `cargo test` passes, including a new test against the San Francisco fixture.")
tides = s.write()

# 4. Field notes: blog draft
s = Session(NOTES, "Draft sourdough timings post", NOW - timedelta(hours=26))
s.user("Turn my notes in content/posts/sourdough-timings.md into a first draft. Keep my voice.")
s.assistant("Here's a draft that keeps your headings and the table of bulk fermentation times by kitchen temperature.")
sourdough = s.write()

# 5. Quick chat: color palette (inline HTML)
s = Session(QUICK, "Dashboard color palette", NOW - timedelta(minutes=48))
s.user("Show me an interactive color picker for the dashboard accent.")
if HTML_SRC:
    html = {"title": "Interactive color palette explorer", "height": 380,
            "html": HTML_SRC.read_text()}
    reference = "7f3c2a91d04e5b68"
    s.assistant(None, [("html_render", {"title": html["title"], "html": html["html"], "height": html.get("height", 380)},
                        f"Controls ready. Insert [[pig-ui:{reference}]] on its own line between paragraphs in your normal Markdown reply.",
                        {"pigHtml": {**html, "version": 2, "reference": reference, "actions": []}})])
    s.assistant(f"Pick a hue and drag the glow slider to preview the accent.\n\n[[pig-ui:{reference}]]\n\n"
                "The swatches update live. Tell me which one you like and I'll write it into `theme.css`.")
palette = s.write()

# 6. Agent: Ada
s = Session(QUICK, "Summarize this week's HTTP RFCs", NOW - timedelta(hours=2))
s.user("What changed in the HTTP working group drafts this week?")
s.assistant("Three drafts moved:\n\n1. **Resumable uploads** reached working group last call.\n"
            "2. **Cache groups** added an invalidation example.\n3. **Query method** clarified caching of responses.")
ada = s.write()
agent_sessions[ada] = "ada"

# Older sessions for the project home and palette.
for cwd, name, hours in [(LUMEN, "Add EXIF date sorting", 30), (LUMEN, "Dark mode for the lightbox", 52),
                         (LUMEN, "Bump Vite to 7", 75), (TIDEPOOL, "Station lookup by name", 49),
                         (NOTES, "Fix RSS feed dates", 100)]:
    s = Session(cwd, name, NOW - timedelta(hours=hours))
    s.user(name)
    s.assistant("Done.")
    s.write()

json.dump(agent_sessions, open(f"{SUPPORT}/agent-sessions.json", "w"), indent=2)
open_ids = [f"session:{p}" for p in (lazy, palette, tides, ada, upload, sourdough)]
subprocess.run(["defaults", "write", "com.jacob.pig.demo", "PiG.sidebar.sessionInbox", "-array", *open_ids], check=True)
subprocess.run(["defaults", "write", "com.jacob.pig.demo", "PiG.modelDefaults.singleModelID",
                f"{PROVIDER}/{MODEL}"], check=True)
print(f"Seeded {len(open_ids)} open chats in {ROOT}")
