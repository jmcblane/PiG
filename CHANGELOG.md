# Changelog

## 1.5.1

- Add interface and code font preferences with searchable font previews, plus paragraph streaming mode.
- Apply shared glow styling to dialogs, popovers, sheets, Settings, and terminal tabs.
- Enable held-key repeat for terminal navigation by disabling the macOS press-and-hold accent picker in PiG.

## 1.5.0

- Redesign the chat layout, composer, and open-chats list, with pixel project folders, agent faces, and a collapsed icon rail.
- Add a command palette for chats, sessions, agents, projects, files, models, and actions (⌘K).
- Move project files into a title-bar popover.
- Add Dusk as the default theme and Glow variants of Finder Blue, Nord, Tokyo Night Storm, and Rosé Pine.
- Show Claude subscription usage, codemode calls, and background job activity.
- Add “Rename with AI” using the opening conversation turns.
- Refresh README screenshots and add an isolated demo build with fake chats.

## 1.4.0

- Add configurable agents and Hermes chat integration, with agent chats shown as sidebar threads and rendered in the shared transcript.
- Add a two-column agent and project picker and refine agent navigation.
- Fix notification clicks by routing them through the app delegate.
- Show completed-turn duration, with completion time available on hover.
- Resolve relative Markdown file links against the chat project directory and show clear errors when files cannot be opened.
- Clear stale live-update and assistant error banners after recovery or successful retries without dismissing unrelated errors.
