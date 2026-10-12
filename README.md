<p align="center">
  <img src="docs/brand/lizard-app-icon-1024.png" width="140" alt="Lizard app icon">
</p>

<h1 align="center">Lizard</h1>

<p align="center">
  <b>A fast, private, native launcher for macOS.</b><br>
  Apps, notes, clipboard, screenshots, windows, translation, a calculator, local AI that knows your notes,<br>
  and Raycast-compatible extensions from any GitHub repo, all one keystroke away.
</p>

<p align="center">
  <img src="docs/brand/splash.png" width="560" alt="Lizard splash screen">
</p>

<p align="center">
  <i>Native Swift · Runs on your Mac · No account · No subscription · No extension store</i>
</p>

---

## Contents

- [Why Lizard](#why-lizard)
- [Install](#install)
- [First run](#first-run)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [The launcher](#the-launcher)
- [Features](#features)
  - [Search, quicklinks & calculator](#search-quicklinks--calculator)
  - [Notes](#notes)
  - [Work Log](#work-log)
  - [Clipboard history](#clipboard-history)
  - [Screenshots](#screenshots)
  - [Search by meaning & Ask Your Notes](#search-by-meaning--ask-your-notes)
  - [AI chat & AI actions](#ai-chat--ai-actions)
  - [Translate](#translate)
  - [Window management](#window-management)
  - [Developer tools](#developer-tools)
- [Private AI](#private-ai)
- [Extensions](#extensions)
- [GitHub in your menu bar](#github-in-your-menu-bar)
- [Sync, backup & moving from Raycast](#sync-backup--moving-from-raycast)
- [Privacy](#privacy)
- [Troubleshooting](#troubleshooting)
- [For developers](#for-developers)
- [Roadmap](#roadmap)

---

## Why Lizard

| | |
|---|---|
| 🦎 **Native and instant** | Written in Swift with SwiftUI and AppKit. The panel opens over any app without taking focus away from it, and reopens exactly where you left it. |
| 🔒 **Private by default** | Notes, the work log, clipboard history, screenshots and the AI all stay on your Mac. Cloud AI is off until you turn it on. |
| 🧠 **AI that knows your stuff** | Search your notes, work log, clipboard, chats and screenshots by *meaning*, and ask questions answered from them, with sources. |
| 🧩 **Open extensions** | Runs Raycast extensions. Install anything from any GitHub repo; there's no store and no review queue. Lizard checks for updates for you. |
| ☁️ **Yours everywhere** | Syncs through your Apple ID (iCloud Drive), backs up to a single file, and imports your Raycast setup. |

## Install

> **Requires macOS 26 Tahoe on an Apple silicon Mac (M1 or later).** Homebrew won't install it on older systems.

**Updates:** Lizard checks GitHub once a day and offers new versions in the menu bar and Settings › General.
One click installs it: `brew upgrade` for Homebrew installs, otherwise it downloads the DMG, checks it is signed by
Lizard's developer and notarized by Apple, swaps the app and restarts. From Terminal:

```sh
brew trust get-lizard/tap   # once: lets Homebrew run the tap's command
brew lizard-update          # refreshes only Lizard's tap, upgrades Lizard, restarts it
brew lizard-update --check  # just show installed and latest versions
```

(`brew update && brew upgrade --cask lizard` works too; plain `brew upgrade` may say "already installed" until
Homebrew refreshes its taps, which it does once a day.)

```sh
brew install --cask get-lizard/tap/lizard
brew install node        # for extensions
```

Releases are signed with a Developer ID and notarized by Apple, and also available as a DMG on the
[Releases](../../releases) page.

### Build from source

**Requirements:** an Apple Silicon Mac on **macOS 26**. To build: Xcode 26.2, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and **Node.js** for extensions (`brew install node`).

```sh
git clone <this repo> lizard && cd lizard
xcodebuild -downloadComponent MetalToolchain        # once per machine (local AI)
xcodegen generate
xcodebuild -project Lizard.xcodeproj -scheme Lizard -configuration Release \
  -derivedDataPath DerivedData -destination 'platform=macOS,arch=arm64' -skipMacroValidation build
open DerivedData/Build/Products/Release/Lizard.app
```

Lizard lives in the menu bar (🦎) and has no Dock icon. Press **⌘Space** anywhere to open it (setup offers it and turns off Spotlight's shortcut for you; pick ⌃Space or any other combination instead if you prefer).

## First run

An animated gecko greets you, then a short setup walks through each step. You can skip any of them and come back
later from **Settings › General › Run setup again**.

1. **Shortcuts:** click a field and press the keys you want.
   - ⌘Space is preselected. Lizard switches off Spotlight's ⌘Space, and gives it back if you later choose another shortcut.
   - ⌃Space also switches keyboard input sources if you use several layouts; Lizard warns you.
   - ⌘Space belongs to Spotlight; Lizard tells you how to free it.
2. **Permissions:** **Accessibility** lets Lizard paste into other apps, move windows and read the selected text.
   Everything else works without it.
3. **Folders:** where notes and the work log live (default `~/Documents/Notes` and `~/Documents/WorkLogs`).
4. **AI:** Apple Intelligence, a local model sized for your Mac, or an opt-in cloud.
5. **GitHub:** sign in with your browser and add pull requests to your menu bar.
6. **Raycast:** shown only if Lizard finds Raycast. Import your extensions and quicklinks.
7. **Try it:** press your shortcut and watch the launcher open.

## Keyboard shortcuts

Every global shortcut can be re-recorded in **Settings › Shortcuts**.

| Global | Action |
|---|---|
| **⌘Space** | Open / close Lizard (your choice in setup; ⌃Space if you kept Spotlight) |
| **⌥⇧A** | Ask AI |
| **⌥⇧V** | Clipboard history |
| **⌥⇧W** | Work Log |
| **⌥⇧N** | New note |
| **⌃⇧S** | Capture a screenshot (area) |
| **⌃⌥ ← / → / ↑ / ↓** | Snap the front window to the left / right / top / bottom half |
| **⌃⌥ ↩** | Maximize the front window |
| **⌃⌥ C** | Center the front window |

| In the launcher | Action |
|---|---|
| **↑ / ↓**, **↩** | Move, open |
| **⇥** | Ask AI about what you typed |
| **⌘K** | Actions for the selected item |
| **⌘1 … ⌘8** | Home tiles (Ask AI, Clipboard, Notes, Screenshots, Work Log, Translate, By Meaning, Kill Process) |
| **Esc** | Go back one screen, then clear the search, then close |

## The launcher

<p align="center"><i>A glass panel with a living gecko, a glow that travels around its edge, and a selection that glides between rows.</i></p>

- **Home ("the den"):** with nothing typed, Lizard shows a greeting, eight quick tiles (⌘1–⌘8), what you use most
  and every command.
- **Ranking:** results come from fuzzy matching (`vsc` → **V**isual **S**tudio **C**ode, matched letters
  highlighted). Things you open often and recently rise to the top.
- **Reopens where you left off:** open a note, switch apps, press ⌘Space, and you're back in that note. Esc goes back
  to the search, with the cursor already in it. You can turn this off in **Settings › General**.
- **Panel size:** compact for search; it grows smoothly for roomy screens (Notes, Screenshots, Clipboard…).
- **Little details:** the gecko wags its tail while you type and flicks its tongue when you summon it. The edge glow
  flares each time Lizard opens. Reduce Motion turns all of this off.

## Features

### Search, quicklinks & calculator

- **Apps:** everything in `/Applications`, `~/Applications`, the system app folders and Finder, kept up to date as you
  install or delete apps. ⌘K offers *Show in Finder*, *Copy Path* and *Quit App*.
- **Quicklinks:** URL templates you open with whatever you type.
  - `gh lizard` searches GitHub, `so swift actors` Stack Overflow, `mdn grid` MDN, `npm zod` npm, and
    `code ~/projects/app` opens a folder in VS Code.
  - Placeholders: `{query}`, `{clipboard}`, `{selection}`. Manage them with **Manage Quicklinks**.
- **Calculator** answers as you type; ↩ copies the result:

  | Type | Get |
  |---|---|
  | `2+3*4`, `(2+3)*4`, `2^10` | `14`, `20`, `1,024` |
  | `15% of 80`, `200 + 10%`, `50 - 20%` | `12`, `220`, `40` |
  | `sqrt(16) + 2pi`, `round(2.5)`, `log(1000)` | functions and constants |
  | `5 km in mi`, `100 f to c`, `2 gb in mb`, `90 min to h` | length, mass, volume, data, time, temperature |

- **Fallbacks:** anything you type can also go to **Ask AI**, **Ask Your Notes**, **Translate** or a quicklink.

### Notes

Plain Markdown files in a folder you choose, so you can edit them anywhere and sync them however you like.

- **Live Markdown editor:** it stays plain text, but looks formatted as you type.
  - Real headings, **bold**, *italic*, links, quotes with a side bar, `inline code` chips.
  - Code blocks draw as rounded panels in a monospaced font with light syntax colours, and each has a **copy button**.
  - Type ```` ``` ```` and press ↩: the closing fence appears and the cursor waits inside.
  - ↩ continues bullet, numbered and checkbox lists; ↩ on an empty item ends the list. ⇥ / ⇧⇥ indent and outdent.
  - Accented characters compose normally (é, ã, ç…).
- **Read mode (⌘E):** a clean rendering where every code block has a **Copy** button.
- **Folders:** real subfolders. Create them from the sidebar, drag notes onto them, nest them.
- **Tags:** `#hashtags` anywhere in the text, or front matter (`tags: [deploy, k8s]`), compatible with Obsidian.
  Browse them in the sidebar; search `#tag`.
- **Pins:** pinned notes stay on top.
- **Snippets:** a note that's just a command or one code block is a *snippet*. It shows the command in the list with
  a copy button, and it appears in the **main launcher search**, where ↩ copies it and ⌘K pastes it.
- **Organize with AI (✨):** the on-device model suggests a folder (preferring ones you already have) and tags. One
  click applies them.
- **Search** matches titles, text, folders and `#tags`. **Search by meaning** covers notes too (see below).

### Work Log

A two-second habit for remembering what you did.

- **⌥⇧W** opens a small box. Type what you just finished and press ↩.
- Each entry is stamped with the time and the app you were in, and appended to a monthly file:
  `- 2026-10-10T14:03:05+02:00 [Xcode] Fixed the flaky login test` in `~/Documents/WorkLogs/2026-10.md`.
- **Log something from earlier:** the *when* row under the text has one-click **1 hour ago**, **This morning**,
  **Yesterday** and **Earlier…**. Earlier shows a day stepper and a time field; from the keyboard, **⌘[ / ⌘]** move a day,
  **⌥↑ / ⌥↓** move 15 minutes and **⌘0** goes back to now. Back-dated lines are slotted into the right month file in time
  order.
- **Summarize Today's Work** and **Weekly Work Summary** turn the log into stand-up notes using the local AI.
- **Performance Review** (launcher command, or *Review…* in the Work Log box): pick *Last month*, *Last 3 months*,
  *Last 6 months*, *This year*, *Last year* or custom dates (⌘1–⌘6), optionally say what to emphasize, and Lizard writes a
  self-review: Summary, Key achievements, Projects, Collaboration & leadership, Growth, Next period. It only uses what
  the log says; long periods are sampled evenly so early months aren't dropped.

### Snippets

Text you type often (replies, signatures, commands), Raycast-style.

- **Create Snippet** / **Search Snippets** from the launcher (↩ pastes into the app you were in, ⌘C copies, ⌘E edits).
  Snippets also appear in the main search.
- **Keywords expand anywhere:** give a snippet a keyword like `;sig` and typing it in any app replaces it with the
  snippet (never in password fields; needs Accessibility; Settings › General to turn off).
- **Raycast's dynamic placeholders:** `{clipboard}` (and `{clipboard offset=1}` from history), `{selection}`, `{cursor}`,
  `{date}`, `{time}`, `{datetime}`, `{day}`, `{uuid}`, custom `format="yyyy-MM-dd"` and `offset="+1d -2h"`,
  `{snippet name="…"}`, and modifiers `| uppercase | lowercase | trim | percent-encode | json-stringify | raw`.
- **Import / Export Snippets** in Raycast's JSON format (both directions), the Raycast step in setup, backups and
  iCloud sync.

### Clipboard history

- **⌥⇧V:** search everything you copied: text, links, files and images, newest first, with pins.
- **↩ pastes** straight into the app you were in (needs Accessibility); ⌘C copies; ⌘P pins.
- **⌘S** summarizes the selected item and **Explain** explains it, both with the local AI.
- **Private:** items marked concealed or transient (how password managers mark secrets) and copies from 1Password,
  Bitwarden, Keychain Access, Passwords and other managers are **never stored**.
- Stored in SQLite with full-text search. Keeps the last 1,000 items or 30 days, plus anything pinned.

### Screenshots

- **⌃⇧S** captures an area using macOS's own crosshair: press Space for a window, Esc to cancel. *Capture Window* and
  *Capture Screen* are in the launcher.
- **Lizard does the rest, on your Mac:**
  1. reads the text in the image (Vision OCR),
  2. names it and picks a category with the on-device AI (rules based on the app and the text are the fallback),
  3. saves it to `~/Pictures/Lizard Screenshots/<Category>/<Month>/2026-10-10 15.00.12 Login crash.png`,
  4. copies it to the clipboard.
- **Categories:** Code, Terminal, Errors, Design, Documents, Chats, Web, Receipts, Meetings, Photos, Other.
- **Gallery:** filter by category, search titles, tags and the **text inside the images**. ↩ copies; ⌘E opens
  Preview to annotate. *Move to* re-files a screenshot; *Copy Text* copies what it recognized; *Explain with AI*.
- The recognized text is indexed for **Search by meaning**, so "that invoice from the hotel" finds the screenshot.

### Search by meaning & Ask Your Notes

<p align="center"><i>“that redis timeout problem” finds the note titled “Incident: checkout requests hanging”, even though neither word appears in it.</i></p>

- **Search by Meaning** looks across notes, the work log, clipboard, AI chats and screenshots.
  - It combines meaning (on-device embeddings) with exact keywords, so paraphrases *and* exact terms like
    `ECONNRESET` both work.
  - The best matches also show under **From your notes** in the main search.
- **Ask Your Notes** (or ⇥ in that screen): ask a question and get an answer written only from your own content, with
  numbered **sources** you can click. If your notes don't cover it, it says so instead of guessing.
- **Models:**
  - Starts with Apple's built-in English model.
  - Download **Qwen3 Embedding** (~350 MB, 100+ languages) in **Settings › AI** for better results in every language.
- **Choose what's indexed:** in Settings › AI, per source. Everything stays on your Mac, the index updates in the
  background, and unchanged items are never re-processed.

### AI chat & AI actions

- **Ask AI** (⇥ from the search, or ⌥⇧A): streaming chat with Markdown and code blocks. Stop a reply any time;
  conversations are saved in **AI Chat History**.
- **One-shot actions:** *Summarize Clipboard*, *Explain Clipboard* (code, errors, commands), *Summarize Today's Work*,
  *Weekly Work Summary*, *Performance Review*. Each opens as a page you can copy or continue as a chat.

### Translate

- On-device translation with Apple's **Translation** framework: private and offline once a language is downloaded.
- The source language is detected for you; pick the target and swap with ⌘S.
- ⌘↩ copies, ⌥↩ pastes into the app you were in.
- Opens with the text you typed or selected. *Translate online with Google* is there only if you ask for it.

### Window management

- ⌃⌥ + arrows for halves, ⌃⌥↩ to maximize, ⌃⌥C to center, all working on the front window anywhere.
- From the launcher (`window …`): quarters, thirds, two-thirds, almost-maximize, **move to next display** and
  **restore** the previous size.
- Needs Accessibility.

### Developer tools

- **Developer Tools:** JSON format, minify and sort keys · JWT decode (header, payload, human-readable exp/iat) ·
  Base64 · URL encode/decode · MD5/SHA-1/SHA-256 · UUID · Unix timestamp ↔ ISO date · camelCase, snake_case,
  kebab-case and Title Case · HTML entities · character/word/line counts. Input defaults to your clipboard.
- **Listening Ports:** who's on :3000? Stop (⌘⌫), force kill (⌥⌘⌫) or open `localhost:<port>`.
- **Kill Process:** every process sorted by CPU or memory, with app icons and live updates. Stop or force kill
  (Lizard asks before force-killing).

## Private AI

Lizard tries engines in this order. **Nothing leaves your Mac unless you turn on "Allow cloud AI".**

| Engine | What it's for | Notes |
|---|---|---|
| **Apple Intelligence** | instant answers, tagging, screenshot and note organization | nothing to download |
| **Local model (MLX)** | chat, summaries, explanations | default **Qwen3 4B** (Qwen3 1.7B on 16 GB Macs). Bigger models in Settings › AI, each with a fit rating for your Mac's memory. Unloads when idle or when memory runs low. |
| **Embeddings** | search by meaning | Apple's English model, or **Qwen3 Embedding 0.6B** (multilingual) |
| **Cloud, opt-in** | heavier questions | **OpenRouter** (Claude, GPT, Gemini, free models) and **OpenCode Zen** (reuses `opencode auth login`), both with browser sign-in; Anthropic and OpenAI keys; Ollama / LM Studio as a local server |

Local models download from Hugging Face only when you click **Download**, with a disk-space check, progress, and an
automatic resume if the connection stalls.

## Extensions

Lizard runs extensions written for Raycast. It implements the public `@raycast/api` and `@raycast/utils` and draws
their screens with native SwiftUI views: lists with detail panes, forms, grids, actions, toasts and **menu-bar
commands**.

- **No store, no gatekeeping.** Paste any GitHub link in **Settings › Extensions**:
  - `github.com/owner/repo`
  - `github.com/owner/repo/tree/main/path/to/extension`
  - `owner/repo/path@v1.2.0` (pinned to a tag)
  - `google-translate` (a bare name installs from Raycast's public repo)

  Lizard downloads only that folder, pinned to its commit, and builds it.
- **Updates:** Lizard checks every few hours and offers **Update**, keeping your preferences and data.
- **External label:** anything Lizard didn't make is marked **External**, and Lizard asks before installing it.
  External extensions are written by their authors, aren't reviewed, and run with your permissions; Lizard isn't
  responsible for what they do.
- **Share:** *Share Extension* creates a `.lizardext` file with the **code only**, none of your data. Friends install it
  with *Install from File…*.
- **Build your own:** `lizardcli ext new my-extension`, then follow **[docs/EXTENSIONS.md](docs/EXTENSIONS.md)** (written
  for people *and* AI agents). `lizardcli ext validate` checks your extension against the guidelines.
  `lizardcli` ships inside Lizard. Homebrew puts it on your PATH; if you installed from the DMG, link it once with `sudo ln -sf /Applications/Lizard.app/Contents/MacOS/lizardcli /usr/local/bin/lizardcli`.
- **Built-in extensions** (original code):

| Extension | What it does |
|---|---|
| **Translate** | Translate text or the selection (no key) |
| **Slack** | Jump to favourite channels and people from copied Slack links (no token) |
| **1Password** | Search items; copy username, password or one-time code via the 1Password CLI (Touch ID) |
| **Apple Notes** | Search and create Apple Notes |
| **Warp** | Open Warp here, new window, launch configurations |
| **Apple Reminders** | Show, complete and add reminders; today's count in the menu bar |
| **Kill Process** | Find and stop processes |

## GitHub in your menu bar

Lizard offers the **GitHub Review Requests** extension by default
([raycast/extensions#29775](https://github.com/raycast/extensions/pull/29775)): the octocat in your menu bar, with the
number of pull requests waiting on you in **orange**. It also has search, an activity inbox and attention tracking.

Sign-in uses the **GitHub CLI**, so you never handle a token:

- If you already use `gh`, Lizard uses your login.
- If not, Lizard downloads GitHub's official CLI into `~/.lizard/gh` and opens GitHub's device sign-in. The code is
  shown in Lizard and already on your clipboard. Approve in the browser and you're done.

## Sync, backup & moving from Raycast

- **iCloud sync** (Settings › Sync & Backup) uses your Apple ID through iCloud Drive; there's no account to create.
  - Quicklinks, settings, shortcuts and your extension list follow you to every Mac with Lizard.
  - Extensions from another Mac are *offered*, never installed silently.
  - Notes and the work log can live in **iCloud Drive › Lizard**. Files are copied, never deleted.
- **Backups:** **Export Backup** writes one `.lizardbackup` file with settings, shortcuts, quicklinks, extensions with
  their preferences and data, and optionally notes, the work log and chats. **Restore Backup** brings it all back.
  Passwords and API keys never go into backups.
- **From Raycast:**
  - Setup (or Settings › Extensions › *Import from Raycast*) lists your installed Raycast extensions; they run in Lizard
    as they are.
  - Raycast encrypts its own data, so quicklinks come over with Raycast's **Export Quicklinks** file
    (`{Query}` placeholders are converted).

## Privacy

| Data | Where it lives | Leaves your Mac? |
|---|---|---|
| Notes, work log | Markdown files in your folders | only if you put them in iCloud Drive |
| Clipboard history | `~/Library/Application Support/Lizard/clipboard.sqlite` | never |
| Screenshots | `~/Pictures/Lizard Screenshots` + an index of recognized text | never |
| Search index | `Application Support/Lizard/knowledge.sqlite` | never |
| AI chats | `Application Support/Lizard/Chats` | only in backups you make |
| API keys | one macOS Keychain item | never (not synced, not backed up) |
| AI requests | Apple Intelligence / MLX on your Mac | only if you enable a cloud AI |

## Troubleshooting

- **I can't see Lizard's (or GitHub's) menu-bar icon.** On MacBooks with a notch and a full menu bar, macOS hides the
  leftmost icons behind the notch.
  - The gecko sits next to the clock. If the bar is full, turn it off in Settings › General to make room for
    extension icons; your launcher shortcut always works.
  - Free space with **⌘-drag** (drag icons out of the menu bar) or in System Settings › Menu Bar.
  - Running the command from the launcher (e.g. *My Pull Requests*) opens its menu at your pointer.
- **Paste, window moves or "selected text" don't work.** Allow Lizard under System Settings › Privacy & Security ›
  **Accessibility** (Setup › Permissions has a button for it).
- **Screenshots are blank or fail.** Allow **Screen Recording** for Lizard in Privacy & Security.
- **⌃Space switches my keyboard layout.** Turn off *Select the previous input source* in System Settings › Keyboard ›
  Keyboard Shortcuts › Input Sources, or record another shortcut.
- **An extension says Node is missing.** `brew install node`.
- **Translate says a language isn't available.** Download it in System Settings › General › Language & Region ›
  Translation Languages.

## For developers

```sh
cd Packages/LizardKit && swift test                                  # Swift unit tests
cd Packages/LizardKit/Sources/ExtensionHost/js && npm test            # extension runtime end-to-end tests
Packages/LizardKit/.build/debug/lizardcli ext run <ext> <command>     # run an extension headless
open Lizard.app --args --show-launcher "query"                       # open the launcher without a hotkey
scripts/make-icons.sh                                                 # re-render icons from the Swift logo code
```

- The app is a SwiftUI/AppKit shell (`App/`) on top of a UI-free Swift package (`Packages/LizardKit`) with modules for
  search, notes, clipboard, dev tools, knowledge, screenshots, AI and the extension host.
- **[AGENTS.md](AGENTS.md)** is the technical guide (architecture, conventions, decisions and pitfalls).
- **[docs/RELEASING.md](docs/RELEASING.md)** covers signing, notarization and the Homebrew release pipeline.
- **[docs/PLAN.md](docs/PLAN.md)** is the roadmap; **[docs/EXTENSIONS.md](docs/EXTENSIONS.md)** is the extension
  contract.
- Much of the foundation (AI providers, MLX hosting, process runner, Keychain handling, GitHub sign-in) comes from
  Cocoon, the same author's app builder.

## Roadmap

- **Natural-language commands:** "kill whatever's on 3000", "new note from clipboard". On-device AI turns them into
  actions and asks before running them.
- **Selection actions:** select text anywhere, then explain, fix grammar, translate, shorten, or draft a reply in place.
- **Clipboard intelligence:** detect JSON, JWTs, stack traces and SQL as you copy, and offer the right action.
- **Snippets with text expansion**, an emoji picker and color tools.
- **Voice:** push-to-talk dictation into the launcher and the work log.
- **Commit messages and PR summaries** from `git diff`, on device.
- **Notarized releases** with automatic updates; OAuth for extensions; an extension preferences editor.

## License

MIT for Lizard's own code. Raycast and GitHub are trademarks of their owners; Lizard isn't affiliated with either.
Extensions you install keep their own licenses.
