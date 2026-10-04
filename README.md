# PiG

<p>
  <img src="images/pig-main-window.png" alt="PiG main window" width="49%">
  <img src="images/pig-chat-session.png" alt="PiG chat session" width="49%">
</p>

PiG is a SwiftUI macOS GUI for the `pi` coding agent.

## Requirements

- macOS 14+ and a Swift toolchain (Xcode or compatible Swift installation)
- `pi` installed

## Features

### Projects & sessions

- Sidebar with projects and their sessions, plus a Files tab
- Project home page listing recent sessions
- Quick Chats: throwaway chats that don't belong to a project
- Session names generated automatically (by the session's model, a model you pick, or Apple Intelligence on the Mac)
- Session tree view: jump to any earlier point in a conversation and fork a new session from a prompt
- Search across all sessions (⌘F) and browse archived sessions
- Several sessions can run at once; idle ones can be unloaded or reloaded
- macOS notification when a reply finishes while you're in another app

### Chat & composer

- Markdown rendering with syntax-highlighted code previews
- Tool activity groups that expand to show commands and file reads
- Detailed views of subagent runs
- Optional display of the model's thinking traces
- Attach images by pasting or dragging
- `@` completion for files and skills, and slash-command suggestions
- Queue steering and follow-up messages while the agent works (Option-Up returns queued messages to the composer)
- Context-usage meter in the composer

### Models

- Model and thinking-level pickers for each session
- Quick Model shortcuts (⌘1–⌘5)
- Default model and thinking level for new sessions
- A schedule that picks the default model by time of day and work days
- Usage-limit meters for ChatGPT/Codex, Claude and Grok, shown only when you have credentials for that provider

### pi integration

- Extensions & Resources popover for turning extensions and skills on or off per chat
- Support for extension UI: prompts (select, confirm, input, editor), notifications, status items, widgets, window title
- Pi updates: check for them, update pi and its extensions, and a "What's New" view

### Workspace

- File tree: create, rename and trash files; reveal in Finder; open in Terminal; copy paths and references
- Custom actions: a button in the title bar that runs your saved shell commands for the project, with output shown in the chat
- Built-in terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)): fullscreen (⌘⇧F), vertical split (⌘D) or horizontal split (⌘⇧D), with tabs; opens in the session's project folder

### Appearance

- 23 themes, including Nord, Dracula, Tokyo Night, Rosé Pine and GitHub Light
- Adjustable text size (⌘+ / ⌘−)
- Native SwiftUI app for macOS 14+

## Download

Prebuilt Apple silicon builds are on the [Releases](https://github.com/jmcblane/PiG/releases) page. They are ad-hoc signed, not notarized: after the first launch attempt, allow PiG in System Settings → Privacy & Security. PiG checks for new releases at launch and from PiG → Check for Updates…

## Build

```sh
scripts/build-app.sh
open dist/PiG.app
```

`build-app.sh` accepts `--clean`. Its defaults are bundle ID `com.jacob.pig` (the same as release builds, so settings carry over) and ad-hoc signing (`PIG_SIGN_ID=-`). To customize, copy `scripts/build-app.local.env.example` to `scripts/build-app.local.env` and set `PIG_BUNDLE_ID`, `PIG_SIGN_ID`, or `PIG_SIGN_KEYCHAIN` there. The local file is gitignored; explicit environment variables override it. Set `PIG_SIGN_ID` to an existing keychain code-signing identity to use it. A missing named identity fails without changing the keychain; `--create-local-identity` (or `PIG_CREATE_LOCAL_IDENTITY=1`) explicitly opts in to creating and trusting one. Ad-hoc builds are not notarized and may need manual approval in macOS Gatekeeper before opening on another Mac.

PiG stores its data in `~/Library/Application Support/PiG` and reads pi's agent directory (`~/.pi/agent`, or `PI_CODING_AGENT_DIR` if set). If PiG can't find `pi`, set its path in Settings → General.

Optional usage-limit meters read OAuth credentials from pi's `auth.json` and query provider usage endpoints (ChatGPT/Codex and xAI), or run the `claude` CLI. Meters appear only when a matching credential exists.

Third-party licenses are in `THIRD_PARTY_NOTICES.md`.
