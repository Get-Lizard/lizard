# Lizard — guide for coding agents

Read this file before changing anything. `docs/PLAN.md` is the roadmap; this file is the map of what exists, why it
is built this way, and what has already bitten us. Keep it current: when you make a decision or hit a pitfall, add it here.

Lizard is a native macOS 26 launcher in the style of Raycast: it opens from a global hotkey and covers app search,
quicklinks, Markdown notes, a work log, clipboard history, developer tools, private AI (Apple Intelligence + local MLX
models, with opt-in clouds) and **Raycast-compatible extensions**, including menu-bar commands. Most of the
architecture is ported from **Cocoon** (`~/projects/magicbuilder`, same author); check Cocoon before inventing a pattern.

---

## 1. Layout

```
project.yml                     XcodeGen spec (Lizard.xcodeproj is generated and git-ignored)
App/                            SwiftUI + AppKit host; LSUIElement accessory app (no Dock icon)
  LizardApp.swift               @main: MenuBarExtra scene + AppDelegate (graceful quit)
  Model/                        @Observable @MainActor state
    AppModel.swift              the hub: engines, windows/panels, hotkeys, search sources, clipboard, work log
    LauncherModel.swift         query, ranked sections, route stack (search → chat/clipboard/notes/extension…)
    LauncherItem.swift          one row type every source maps into; IconCache
    AIService.swift             provider order, MLX model download (stall watchdog), jobs
    ChatSession.swift           one chat: UI items + model messages, streaming, provider fallback, JSON persistence
    AccountsModel.swift         GitHub (gh CLI), OpenRouter (OAuth PKCE), OpenCode Zen sign-ins
    ExtensionsModel.swift       install/uninstall, launch commands, default GitHub integration, menu-bar commands
    ExtensionSession.swift      one running view command: latest tree, toast, search text, form values
    MenuBarCommandController.swift  extension menu-bar command → NSStatusItem + NSMenu, interval refresh
    AppHostServices.swift       native services extensions await (paste, confirm, AI, apps, selected text…)
    SetupModel.swift            first-run pages, Accessibility polling
    Hotkeys.swift               KeyboardShortcuts names/defaults, conflict warnings, `LauncherShortcut` (⌘Space offer) + `SpotlightShortcut` (symbolic hotkey 64 on/off)
    Preferences.swift           folders and toggles in UserDefaults
    ResourceMonitor.swift       memory pressure → trim/unload MLX (from Cocoon)
    KnowledgeService.swift      what gets indexed, background sync, search, AskNotesSession (cited answers)
    Portability.swift           PortableSnapshot, BackupService (.lizardbackup), SyncService (iCloud Drive)
  Views/
    Launcher/                   LauncherPanel (NSPanel), LauncherRootView, SearchView, ResultRow
    AI/                         ChatView (MarkdownUI), AIJobView, ChatHistoryView
    Extensions/                 ExtensionView (List/Detail/Form/Grid renderer), ExtensionImage (icons/colors)
    Clipboard/ Notes/ WorkLog/ DevTools/ Setup/ Settings/ Style/
    Brand/LizardBrand.swift     the gecko: geometry, animatable shapes, LizardMarkView, app icon, pattern
    Intro/SplashView.swift      scripted launch animation
  Assets.xcassets               AppIcon + MenuBarIcon are rendered by scripts/make-icons.sh — don't hand-edit
Packages/LizardKit/             UI-free Swift package (Swift 6.2 tools, macOS 26)
  Sources/LizardCore            ProcessRunner, ToolEnvironment, AppPaths, LogRing, ResilientFile, HardwareProfile, GitHubCLI
  Sources/Search                AppIndexer (actor + FSEvents), FuzzyMatcher, SearchEngine, Frecency, Quicklinks
  Sources/Notes                 NotesStore (folder of .md), WorkLogStore (monthly .md), MarkdownTokenizer
  Sources/Clipboard             ClipboardStore (SQLite + FTS5), PasteboardMonitor/Filter, AutoPaste (CGEvent ⌘V)
  Sources/DevTools              TextTransform (JSON/JWT/Base64/URL/hash/case/time), PortKiller, ProcessList, ProcessKiller
  Sources/AIEngine              AIProvider protocol, Anthropic/OpenAI/OpenAI-compatible clients, SSE, OpenRouter OAuth,
                                OpenCode Zen, Apple Foundation Models (+ AppleFMProvider), ModelCatalog, AIJobs
  Sources/AIEngineMLX           MLXModelHost/MLXProvider/ModelStore + MLXEmbedder (only module that links MLX)
  Sources/Knowledge             semantic index: chunker, embedders, KnowledgeIndex (SQLite vectors + FTS5), AskNotes
  Sources/ExtensionHost         Swift side of the extension runtime (manifest, view tree, runtime, store)
    js/                         the Node runtime: @raycast/api + @raycast/utils shim on react-reconciler
  Sources/lizardcli             headless CLI
  Tests/LizardKitTests          Swift Testing suites
Extensions/                     Lizard's own extensions in Raycast package format (bundled into the app)
scripts/make-icons.sh           renders icons/splash previews from the Swift brand code
docs/PLAN.md                    roadmap + additions requested during implementation
docs/brand/                     rendered app icon and splash previews
```

Module dependencies point one way: `LizardCore` ← feature modules ← `App`. `AIEngine` has no dependencies.
`AIEngineMLX` is separate so the CLI and tests don't need Metal and the app doesn't initialise MLX until a local
model is used.

## 2. Build, test, run

```sh
# Swift package: build + unit tests (21 tests)
cd Packages/LizardKit && swift build && swift test

# Extension runtime: build the shim and run its end-to-end tests (spawns real Node hosts)
cd Packages/LizardKit/Sources/ExtensionHost/js && npm install && npm run build && npm test

# App
xcodegen generate
xcodebuild -project Lizard.xcodeproj -scheme Lizard -configuration Release \
  -derivedDataPath DerivedData -destination 'platform=macOS,arch=arm64' -skipMacroValidation build
open DerivedData/Build/Products/Release/Lizard.app
```

- Use **Release** for anything involving local models: MLX is very slow in Debug.
- Each machine needs `xcodebuild -downloadComponent MetalToolchain` once.
- A post-build script runs `npm run build` in `ExtensionHost/js` and copies `dist/` to `Lizard.app/Contents/Resources/ExtensionShim`.
- `Extensions/` is copied as a folder resource to `Lizard.app/Contents/Resources/Extensions`.
- Signing: `Apple Development`, team `6H728M7XQK`, so Keychain "Always Allow" and the Accessibility grant survive rebuilds.
  Without that certificate: `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`.
- Brand assets: edit `App/Views/Brand/LizardBrand.swift`, then run `scripts/make-icons.sh`.

### Testing without the UI

You can't send keystrokes to the app from a terminal session (osascript lacks assistive access). Use these instead:

| Tool | What it does |
|---|---|
| `Lizard.app --args --show-launcher [query]` | opens the launcher (optionally with a query) and skips the splash |
| `--args --show-settings` / `--show-clipboard` | opens Settings / clipboard history |
| `screencapture -x out.png` | screenshot to check the UI |
| `lizardcli ext install <store-name or /path>` | install + build an extension exactly as the app does |
| `lizardcli ext list` | installed extensions |
| `lizardcli ext run <ext> <command> [pref=value …]` | run a command headless; prints the first settled view tree as JSON |
| `lizardcli transform <name> <text>` | run a DevTools transform |
| `lizardcli gh-status` / `gh-install` / `apple-ai` | GitHub CLI state, managed gh download, Apple Intelligence probe |

`lizardcli` is at `Packages/LizardKit/.build/debug/lizardcli` after `swift build`.

Status items on macOS 26 are windows owned by **Control Center**, not the app. To check whether one exists, list
layer-25 windows with `CGWindowListCopyWindowInfo`; items with `onscreen = false` are hidden (usually behind the notch).

## 3. Conventions

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`. UI state is `@Observable @MainActor final class`;
  engines are `actor`s; value types are `Sendable`. No Combine, no `ObservableObject`.
- Subprocesses go through `ProcessRunner` (merged output, streaming lines, timeout, cancellation).
  The one exception is `ExtensionRuntime`, which needs a live stdin and uses `Process` directly.
- Find tools through `ToolEnvironment.shared.which` (it covers Homebrew, nvm/volta/bun Node and `~/.lizard/gh/bin`).
  GUI apps start with a minimal PATH.
- Persistence: `ResilientFile` (atomic + `.bak`) for JSON; UserDefaults keys are `Lizard.*`; secrets in the single
  Keychain item (`Keychain.set/get/cachedValue`, service `io.lizard.app`). Never read the Keychain in a view body.
- Errors: per-module `enum …Error: Error, LocalizedError` with plain-language messages.
- Tests: Swift Testing (`@Suite`, `@Test`, `#expect`). Parsers, matchers, transforms and stores need tests.
- New launcher features: add a `LauncherModel.Route` case, a view, and a `command(…)` entry in
  `AppModel.builtInCommands()`. Rows are `LauncherItem`s; `perform` returns `true` to keep the panel open.
- **Originality:** built-in extensions and the shim are written from scratch against Raycast's *public* API.
  Never copy code from `raycast/extensions` or Raycast's packages into this repo. Third-party store extensions are
  downloaded at runtime and never vendored.

## 4. Key decisions

1. **Not sandboxed.** CGEvent auto-paste, Accessibility, `lsof`/`kill`, Node subprocesses and indexing all fight the sandbox.
2. **Local-first AI.** Provider order comes from `ProviderSettings.activeOrder`: the main provider, then the other local
   engine (Apple ↔ MLX), then clouds — and clouds **only when `cloudEnabled`** (off by default). MLX is offered only once
   its model is downloaded, so a chat never silently triggers a multi-GB download.
3. **Default local model:** `mlx-community/Qwen3-4B-4bit`, or `Qwen3-1.7B-4bit` on Macs with 16 GB or less
   (`ModelCatalog.launcherDefault`). Jobs pass `thinking: false`; `AIJobRunner.cleaned` strips stray `<think>` blocks.
   `mlx-swift` 0.31.4 / `mlx-swift-lm` 3.31.4 are pinned **exact** (newer needs Swift tools 6.3).
4. **Apple Intelligence** (`AppleFMProvider`) is a streaming provider with no tools and a ~3k prompt budget. History is
   folded into one prompt. `AppleIntelligence.triage` / `workTags` use `@Generable` guided generation.
5. **Cloud sign-ins follow Cocoon:** OpenRouter = OAuth PKCE with a localhost callback. OpenCode Zen has no third-party
   OAuth, so Lizard reuses `opencode auth login` (`~/.local/share/opencode/auth.json`), then a pasted key, then
   `OPENCODE_API_KEY`. Endpoint `https://opencode.ai/zen/v1` (OpenAI-compatible).
6. **GitHub = GitHub CLI only** (`LizardCore/GitHubCLI.swift`, ported from Cocoon's `GitHubLogin`):
   - a signed-in user `gh` is used as-is;
   - otherwise the official release (`gh_*_macOS_arm64.zip`) is downloaded to `~/.lizard/gh` (no spaces in the path),
     and `gh auth login --web` runs with `GH_CONFIG_DIR=Application Support/Lizard/gh-config`. Lizard parses the one-time
     code (`\b[A-Z0-9]{4}-[A-Z0-9]{4}\b`) and the device URL, shows the code and opens the browser;
   - unlike Cocoon, the config folder is **kept**, so extensions can run `gh` / `gh auth token`; extension processes get
     `GH_CONFIG_DIR` + PATH via `GitHubCLI.environment(managed:)`.
7. **Default GitHub integration** = the author's `github-review-requests` from the Raycast store (raycast/extensions
   PR #29775). Lizard presets `authMethod=gh` and `ghPath=<resolved gh>` and enables its `actionablePullRequests`
   menu-bar command (`ExtensionsModel.installGitHubDefault`).
8. **Launcher hotkey: Setup offers ⌘Space** (the user's choice) and turns off Spotlight's symbolic hotkey 64 via `defaults write com.apple.symbolichotkeys` + `activateSettings -u`; it re-enables it only if Lizard disabled it (`Lizard.SpotlightShortcutDisabled`). The KeyboardShortcuts default stays ⌃Space so skipping setup never fights Spotlight. It collides with "Select previous input source" when 2+ keyboard input
   sources are enabled; `HotkeyConflicts` warns. Other defaults: ⌥⇧W work log, ⌥⇧V clipboard, ⌥⇧A AI, ⌥⇧N note.
9. **Storage:** notes are plain `.md` files in `~/Documents/Notes`; the work log is `~/Documents/WorkLogs/YYYY-MM.md` with
   lines like `- 2026-10-10T14:03:05+02:00 [Xcode] text`; clipboard history is SQLite FTS5; chats are JSON in
   `Application Support/Lizard/Chats`. No SwiftData/Core Data.
10. **Clipboard privacy:** skip `org.nspasteboard.ConcealedType`/`TransientType`/`AutoGeneratedType` and password-manager
    bundle IDs (`PasteboardFilter`). Lizard's own writes are excluded with `markOwnWrite()`.

## 5. The extension system

**Goal:** run unmodified Raycast extensions (store and local) and render them natively.

```
Swift (ExtensionRuntime) ──stdin NDJSON──▶ node host.js ──require──▶ build/<command>.js (the extension)
        ▲                                     │  react-reconciler → plain JSON view tree
        └────────────stdout NDJSON────────────┘
```

- **Shim** (`ExtensionHost/js/src`):
  - `host.js` patches `Module._load` so `react`, `react/jsx-runtime`, `@raycast/api` and `@raycast/utils` resolve to the
    shim's own instances (exactly one React). It also owns the navigation stack (`Action.Push`, `useNavigation`) and
    routes `console.*` to stderr — **stdout is protocol only**.
  - `renderer.js` is a React 18 reconciler (`react@18.3.1`, `react-reconciler@0.29.2`). Functions in props serialize to
    `{"$callback": "<nodeId>.<prop>"}`.
  - `api.js` holds components and services. Element-valued props (`actions`, `detail`, `metadata`,
    `searchBarAccessory`) become `slot:<name>` children. Every `Action.*` variant is an `Action` node whose `onAction`
    runs in JS; `Action.SubmitForm` has `kind: "submitForm"` and receives the form values from Swift. `Icon.X` → `"icon:X"`,
    `Color.X` → `"color:x"`. Clipboard/open/trash/AppleScript use macOS CLIs from JS. LocalStorage and Cache are JSON
    files in the command's support folder.
  - `utils.js` implements `@raycast/utils` (usePromise, useCachedPromise, useCachedState, useFetch, useExec,
    useLocalStorage, useForm, runAppleScript, showFailureToast, getFavicon, withCache, useFrecencySorting, useAI).
  - `build-extension.js` bundles each command `src/<name>.{tsx,ts,jsx,js}` with esbuild (CJS, node20), leaving react
    and @raycast/* external.
- **Protocol:**
  - host → app: `ready`, `render {tree, depth}`, `notify {method, params}` (toast.show/hide, hud, closeMainWindow,
    popToRoot, updateCommandMetadata, openPreferences, clipboard.copied), `request {id, method, params}`, `done`, `error`.
  - app → host: `launch {bundle, command, extension, preferences, launchType, …}`, `event {callback, args}`, `pop`,
    `response {id, result|error}`.
  - Requests the app answers (`AppHostServices`): clipboard.paste, confirmAlert, ai.ask, applications,
    frontmostApplication, selectedText, launchCommand.
- **Swift side:** `ExtensionManifest` (Raycast package.json, `intervalSeconds`), `ViewNode` (+ `slot()`,
  `flattenedActions`, `first()`), `ExtensionRuntime` (one Node process per running command), `ExtensionStore`.
- **Installing:** `ExtensionStore.install` takes a folder or a store name. Store installs fetch **one folder** from
  raycast/extensions through the git tree API (`git/trees/<sha>%3Aextensions%2F<name>?recursive=1`, colon/slash
  URL-encoded) plus raw.githubusercontent.com, pinned to the current `main` SHA. The request carries the `gh` token
  when available. Never clone the repo — it's enormous; a sparse clone took more than 5 minutes.
  Then `npm install --omit=dev --ignore-scripts` (only when there are dependencies) and the shim builder.
  Layout: `Application Support/Lizard/Extensions/<name>/{package,build,support,preferences.json,source.json}`.
- **Rendering:** `ExtensionView` handles List (sections, accessories, detail pane, dropdown), Detail (MarkdownUI +
  metadata), Form, Grid, ⌘K actions and toasts. `filtering` defaults to on unless the extension handles
  `onSearchTextChange` (Raycast semantics).
- **Menu-bar commands:** `MenuBarCommandController` → `NSStatusItem` + `NSMenu`. It re-runs the command on the manifest
  `interval` (launchType `background`) and when the menu opens. The previous Node process stays alive until the new
  one renders, so callbacks always reach a live process. Enabled commands are stored in `Lizard.EnabledMenuBarCommands`.
- **Not supported yet:** OAuth (`OAuth.PKCEClient` throws a clear error), background no-view intervals, editing
  extension preferences in Settings (the store has `setPreferences`; the UI doesn't), Action.PickDate/CreateQuicklink,
  `Grid` inset/fit options, React 19-only APIs.

**Built-in extensions** (`Extensions/lizard-*`, original code): Translate (Google web endpoint, no key),
Slack (deep links from copied links, no token), 1Password (`op` CLI + desktop-app integration), Apple Notes (JXA),
Warp (URL schemes + launch configurations), Apple Reminders (JXA + menu-bar count), Kill Process.
Icons are generated SF-Symbol tiles; no third-party logos.

Verified: the shim's 4 end-to-end tests; `github-review-requests` installed from the store (~7 s) with its menu bar
rendering live PRs through `gh`; Kill Process, Warp, Slack and Reminders rendered headless.

## 5b. Extension sources, updates, sharing (no store)

Lizard deliberately has **no store**: any GitHub repo folder is an extension source. The guideline for authors
(and for agents asked to build an extension) is `docs/EXTENSIONS.md`; `lizardcli ext new|validate` enforce it
(`ExtensionValidator`).

- `ExtensionSource` = `.github(GitHubLocation, commit)` | `.folder` | `.raycastImport` | `.builtIn`.
  `GitHubLocation.parse` accepts github.com URLs (`/tree/<ref>/<path>`), `owner/repo[/path][@ref]`, and a bare name
  as shorthand for `raycast/extensions/extensions/<name>`. Old `store(name:commit:)` records decode as GitHub.
- Installs pin to the **newest commit touching the folder** (`GitHubAPI.latestCommit(touching:)`), the same value
  update checks compare against — pinning the repo HEAD made every install look outdated.
- `ExtensionsModel` checks for updates 60 s after launch and every 6 h; HUD on new ones; Settings shows **Update**.
- Every non-built-in extension is **External**: badge in Settings and `confirmExternalInstall` (responsibility notice)
  before installing from GitHub, a file, Raycast or another Mac.
- Share = `.lizardext` (zip of the package, **no data**: no preferences, no support folder, no node_modules).
- Raycast import (`ExtensionStore.raycastExtensions/importFromRaycast`): Raycast keeps each installed extension's
  compiled `<command>.js` bundles in `~/.config/raycast/extensions/<uuid or name>/`; they run on our host as-is.
  Raycast's data and quicklinks live in an encrypted SQLite DB, so quicklinks come from Raycast's *Export Quicklinks*
  JSON (`Quicklink.fromRaycastExport`, `{Query}` → `{query}`). The setup shows a Raycast page only when it finds some.

## 5c. Knowledge (semantic search + Ask your notes)

- Embeddings: `MLXEmbedder` (Qwen3-Embedding-0.6B 4-bit DWQ via `MLXEmbedders`, multilingual, ~350 MB, opt-in
  download) else `AppleSentenceEmbedder` (`NLEmbedding.sentenceEmbedding(.english)`). Tested: Apple's
  `NLContextualEmbedding` mean-pooled is useless for retrieval (everything scores ~0.75). Changing embedder
  re-embeds everything (`meta.embedder`).
- Qwen3-Embedding needs an instruction prefix on **queries only**, an EOS token appended, right padding, and
  last-token pooling with the mask. Embedding shares `MLXModelHost`'s generation slot (MLX isn't safe concurrently).
- `KnowledgeIndex`: documents/chunks/FTS5 in `Application Support/Lizard/knowledge.sqlite`; vectors scanned in memory
  with `vDSP_dotpr`; hybrid ranking = reciprocal-rank fusion (vector weight 1.0, BM25 0.8, k = 60), max 2 passages
  per document. Unchanged documents (content hash) are never re-embedded.
- Sources: notes (files), work log (one document per day, last year), clipboard (last 500 text items), chats.
- `AskNotes`: numbered sources + cite-with-[n] prompt; `relevant()` drops passages under 80% of the best similarity;
  if a small model answers with bare citations ("[1] [2]" — Apple's model did), retry once without the citation rule.

## 5d. Sync & backup

- iCloud sync uses **iCloud Drive** (`~/Library/Mobile Documents/com~apple~CloudDocs/Lizard`) — no entitlements,
  provisioning or server. Each Mac writes `Sync/<deviceID>.json` (`PortableSnapshot`); others read them every 2 min:
  quicklinks = newest list wins, settings from the newest snapshot, missing extensions are *offered*, never
  auto-installed. Evicted `.icloud` placeholders are re-downloaded with `startDownloadingUbiquitousItem`.
- Notes/work log sync by moving the folders into iCloud Drive (`SyncService.moveNotes`, copy-only, never deletes).
- CloudKit / `NSUbiquitousKeyValueStore` would need an iCloud entitlement + provisioning profile; not used.
- `.lizardbackup` (zip): snapshot.json, per-extension preferences (password preferences excluded) + support data,
  packages that can't be re-downloaded, optional notes/work log/chats. Keychain secrets and clipboard never leave.

## 5e. Notes v2, screenshots, calculator, windows, translate, look

- **Notes** (`Notes/NoteMetadata.swift`): optional front matter (`tags: [a, b]`, `pinned: true`, Obsidian-compatible)
  plus inline `#tags` outside code. A **snippet** = one code block with ≤2 prose lines, or a single `$ cmd` line;
  snippet notes appear in root search (↩ copies). Folders are real subfolders. Read mode uses MarkdownUI with
  `.markdownBlockStyle(\.codeBlock)` → `CopyableCodeBlock`. AI organize = `AppleIntelligence.organizeNote`.
- **Screenshots** (`Screenshots` module + `ScreenshotService`): macOS's own `screencapture -i` UI (needs Screen
  Recording permission; Esc = no file = cancelled), Vision OCR, `AppleIntelligence.labelScreenshot` else
  `ScreenshotLabel.heuristic`, filed at `~/Pictures/Lizard Screenshots/<Category>/<yyyy-MM>/…png`, index in
  `Application Support/Lizard/screenshots.json`, OCR text indexed by Knowledge (`.screenshot` source).
- **Calculator** (`DevTools/Calculator.swift`): own recursive-descent parser (never `NSExpression`, it raises on bad
  input); calculator mode only when an operator/function/`of` is present; units via table.
- **Window management** (`WindowManager.swift`): AX position/size (top-left origin vs AppKit bottom-left — convert
  with the primary screen height); set size → position → size because apps clamp. Global ⌃⌥ shortcuts act on the
  frontmost app; launcher commands act on `previousApp`.
- **Translate** (`TranslateView`): Apple Translation via `.translationTask` (Swift 6 needs
  `nonisolated(unsafe) let session` inside the closure); `NLLanguageRecognizer` for source; Google only on request.
- **Look:** `BioluminescentRim` (rotating angular-gradient edge, flares on summon), `DenHeader` home (greeting + tiles,
  ⌘1–⌘8), gliding selection via `matchedGeometryEffect`, gecko wags while typing, and the panel resizes to
  `Metrics.workspaceSize` for roomy routes (`LauncherModel.isWorkspace`) keeping its top edge fixed.

## 6. Known pitfalls (each of these happened)

- **NSPanel typing:** the non-activating panel must override `canBecomeKey` → `true`.
- **Panel hides when a popover opens:** popovers (⌘K) and alerts take key status. `onResignKey` hides the panel only when
  `NSApp.keyWindow == nil`, i.e. focus left Lizard.
- **Accessory apps can't come forward:** `NSApp.activate()` is ignored without a user click; windows opened behind the
  front app. Use `AppModel.bringToFront` (`activate(ignoringOtherApps:)` + `orderFrontRegardless`).
- **Status items invisible:** on notched MacBooks with full menu bars, macOS hides the *leftmost* items behind the
  notch, and each new item is added to the left. So Lizard's own icon is a manual `NSStatusItem` (`LizardStatusItem`,
  not a SwiftUI `MenuBarExtra`) created **after** extension items; if an extension item is still hidden
  (`window.occlusionState` lacks `.visible`), Lizard hides its own icon once to make room. Saved positions
  (`NSStatusItem Preferred Position lizard.*`) from older builds are cleared once (`Lizard.StatusItemOrderV2`).
- **Focus:** when the panel reopens, `FloatingPanelController.focusTypingField()` restores the last text field or picks
  the topmost editable one (retried after layout) — SwiftUI `.onAppear` focus doesn't fire again on re-show.
- **Settings scene:** SwiftUI's `Settings` scene can't be opened reliably from AppKit code in an accessory app, so Lizard
  uses its own `NSWindow` (`AppModel.openSettings`).
- **KeyboardShortcuts:** to show a global shortcut on a menu button use `.globalKeyboardShortcut(.name)`, not `.keyboardShortcut`.
- **ImageRenderer doesn't run `.task`:** views rendered for assets (splash preview) must take their final state in `init`
  (`SplashView(preview: true)`).
- **Path booleans:** merging stroked outlines with `addPath` + `normalized` left holes; use `Path.union` / `.subtracting`
  (macOS 14+). See `LizardGeometry.silhouette`.
- **Empty-query suggestions:** ranking all candidates by `weight` listed every app; suggestions are frecency-only now.
- **Glass readability:** pure `.glassEffect` over busy windows is hard to read; the launcher adds a 72% window-colour
  backing (`launcherGlass()`).
- **`gh` without a TTY:** `gh auth login --web` with stdin at `/dev/null` still prints
  `! One-time code (XXXX-XXXX) copied to clipboard` and the device URL; that's what Lizard parses.
- **SwiftPM:** a target with no sources breaks every build ("target … is empty").
- **Shell:** BSD `sed` has no `\|` alternation — use Python for regex edits. There's no `timeout` command on macOS.
- **Testing:** UI can't be driven from the terminal (no assistive access); use the `--show-*` flags + `screencapture`.
- The screen during screenshots is the user's real desktop; don't describe unrelated personal content.
- The user may be using the app while you test: relaunching it (`pkill` + `open --args …`) interrupts them, and a
  debug launch with `-Lizard.NotesFolder …` points *their* session at test data. Prefer unit tests and the CLI.
- `open` right after `pkill` fails with LSOpen error -600 while the old process exits; wait with `pgrep` first.
- `screencapture` output is black when the Mac's screen is locked/asleep — not a rendering bug.
- Spawned helper agents in this project produced nothing for 20+ minutes and had to be stopped; check their output
  early rather than waiting on them.

## 7. Status

Done (phases 0–7 of `docs/PLAN.md`): brand + splash, setup with hotkey recording, launcher, search and quicklinks,
notes, work log, clipboard, dev tools (transforms, ports, kill process), AI chat and jobs, accounts, extension host,
built-in extensions, menu-bar commands, and the GitHub default integration.

Not verified end-to-end yet: MLX model download and chat in the app, auto-paste with Accessibility granted,
OpenRouter/OpenCode sign-in, hotkeys pressed by a person. Not built: notarized release (Developer ID + hardened
runtime + Sparkle; bundled Node would need `com.apple.security.cs.allow-jit`), extension preference editor, extension
OAuth, the local-AI ideas in README › Roadmap.
