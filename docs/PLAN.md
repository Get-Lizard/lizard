# Lizard — native macOS launcher (revised plan, aligned with Cocoon)

## Context
The original blueprint describes a Raycast-style launcher (NSPanel shell, app search, quicklinks, markdown notes, work log, clipboard history, local LLM, Raycast extension host). Its tech choices were generic (llama.cpp/Ollama, Llama 3.2/Qwen 2.5, SwiftData, MPS). This revision rebases the plan on the stack, conventions and AI architecture already proven in `~/projects/magicbuilder` (Cocoon), so we reuse code instead of reinventing it, and adds: animated splash, first-run setup with hotkey recording, and a minimalist animated lizard logo.

Started as an empty, greenfield repo.

---

## 1. Tech stack (copied from Cocoon)
| Area | Choice | Cocoon reference |
|---|---|---|
| OS / toolchain | macOS 26.0 min, Xcode 26.2, Swift 6.2, `swiftLanguageModes: [.v6]`, `SWIFT_STRICT_CONCURRENCY: complete`, Apple Silicon only | `project.yml`, `Packages/CocoonKit/Package.swift` |
| Project gen | XcodeGen `project.yml` (xcodeproj generated, git-ignored) + one local SPM package `Packages/LizardKit` | `project.yml` |
| UI | SwiftUI + AppKit where needed (NSPanel, NSTextView, NSStatusItem); Liquid Glass materials | `App/` |
| State | `@Observable @MainActor final class` models, `@Environment(Model.self)`; no Combine / ObservableObject | AGENTS.md Conventions |
| Background work | `actor`s for engines (indexer, clipboard store, model host); `Synchronization.Mutex` / `@unchecked Sendable` lock classes only where needed | `MLXModelHost`, `LogRing` |
| Processes | All subprocesses via a copied `ProcessRunner` (port killer, `lsof`, Node host) — never raw `Process` | `CocoonCore/ProcessRunner.swift`, `ToolEnvironment.swift` |
| Settings | Codable settings struct in UserDefaults (namespaced `Lizard.*` keys — fix Cocoon's mixed naming); `@AppStorage` for UI prefs | `AIEngine/ProviderSettings.swift` |
| Secrets | Single-item Keychain JSON blob, in-memory cache, prefetched off-main | `enum Keychain` in `ProviderSettings.swift` |
| Files | `AppPaths` helper (`~/Library/Application Support/Lizard/…`), atomic `ResilientFile` writes with `.bak` | `CocoonCore/AppPaths.swift`, `Workspace/ResilientFile.swift` |
| Logging | `LogRing` + `os.Logger` (Cocoon lacks OSLog — add it here) | `CocoonCore/AppPaths.swift:44` |
| Crash/diagnostics | `CrashGuard` (MetricKit + running.lock) | `App/Model/CrashGuard.swift` |
| Tests | Swift Testing (`@Suite/@Test/#expect`) in the package; parsers/transformers must have tests | `Packages/CocoonKit/Tests` |
| Signing | Non-sandboxed, Apple Development identity (team `6H728M7XQK`) so Keychain/Accessibility grants survive rebuilds; later Developer ID + hardened runtime + notarytool + Sparkle | `project.yml`, AGENTS.md 18ai |
| Headless modes | `--llm-smoke-test`, `--index-bench` launch flags + `lizardcli` for testing engines without UI | `App/Model/SmokeTest.swift`, `cocooncli` |
| Agent docs | `CLAUDE.md` + `AGENTS.md` (decisions/pitfalls/conventions), vendor `swiftui-expert-skill` | magicbuilder root |

Why non-sandboxed: CGEvent auto-paste, Accessibility, `lsof`/kill, Node subprocess, global indexing all fight the sandbox.

## 2. Repository layout
```
project.yml
App/
  LizardApp.swift            @main, AppDelegate (accessory app, LSUIElement)
  Model/  AppModel, SetupModel, LauncherModel, ResourceMonitor, CrashGuard
  Views/  Splash/, Setup/, Launcher/, Notes/, WorkLog/, Clipboard/, AI/, Settings/, Brand/, Style/
  Resources/ AppIcon.icon (Icon Composer), Assets
Packages/LizardKit/
  Sources/LizardCore     ProcessRunner, ToolEnvironment, AppPaths, LogRing, ResilientFile, HardwareProfile, Hotkeys
  Sources/Search         AppIndexer (actor), FuzzyMatcher, Quicklinks
  Sources/Notes          NotesStore (~/Documents/Notes/*.md), WorkLogStore, MarkdownTokenizer
  Sources/Clipboard      PasteboardMonitor, ClipboardStore (SQLite FTS5), AutoPaste
  Sources/DevTools       PortKiller, JSON/JWT/Base64/URL transformers
  Sources/AIEngine       copied from Cocoon (no deps)
  Sources/AIEngineMLX    copied from Cocoon (MLX only here; lazily used)
  Sources/ExtensionHost  (phase 2) Node runtime manager, JSON-RPC bridge, view-tree models; js/ = @raycast/api shim + react-reconciler (TS, esbuild)
  Sources/lizardcli
  Tests/...
```
Dependency direction: `LizardCore` ← feature modules ← `App`. `AIEngine` dependency-free; `AIEngineMLX` separate so CLI/tests don't need Metal and the base app stays small until a model is used.

## 3. AI layer (replaces "Option A Ollama / Option B llama.cpp")
Port Cocoon's three-tier design:
1. **Apple Foundation Models** (`AIEngine/AppleIntelligence.swift`) — instant on-device, zero download. Use for launcher-bar intent triage (`@Generable` enum: openApp / quicklink / note / ask), work-log tagging, one-line summaries. Prewarm `LanguageModelSession` when the panel opens.
2. **Local MLX** via `mlx-swift-lm` 3.31.4 / `mlx-swift` 0.31.4 (pinned exact, same as Cocoon) — replaces llama.cpp/GGUF. Copy `MLXProvider.swift` (`MLXModelHost` actor: one model, FIFO generation slot, idle unload, `MLXErrorTrap`, `waitUntilIdle` before quit), `ModelStore.swift` (HF cache, download progress/`DiskDownloadMeter`), `ModelCatalog.swift` + `HardwareProfile` (fit by `recommendedMaxWorkingSetSize`). Default model for summaries: **`mlx-community/Qwen3-4B-4bit`** (~2.5 GB) with `Qwen3-1.7B-4bit` for ≤16 GB Macs; `enable_thinking: false` for speed. Drop `PromptCacheBox` initially (short prompts). Keep `ResourceMonitor` memory-pressure trim/unload.
3. **Optional cloud / external** — copy `ChatTypes.swift` (`AIProvider`, `ChatEvent`), `SSE.swift`, `AnthropicProvider.swift`, `OpenAICompatibleProvider.swift` (also covers Ollama/LM Studio at `localhost:11434/v1`), `OpenAIResponsesProvider.swift`, `ProviderSettings.swift`, `ModelDirectory.swift`, optional `OpenRouterAuth.swift`. Off by default to honor "zero cloud"; user opts in in Settings.

Jobs pattern: port `MacHelper`/`HelperJob` (timeout-raced task group, validated output) for: "Summarize clipboard item", "Summarize today's work log", "Weekly brag doc", "Explain selection".

**AI Chat** (Raycast "Ask AI"): `Tab` from the launcher opens a chat view in the same panel. Reuse Cocoon's `ChatItem` (UI) vs `[ChatMessage]` (model history) split and scroll-anchoring from `App/Views/ChatPane.swift`; add **swift-markdown-ui** for code blocks (Cocoon only renders inline markdown). Stop button → task cancellation → `onTermination`. Persist chats as JSON in `Application Support/Lizard/Chats/` via `ResilientFile`. Model switcher reused from `ChatPane.swift` `ModelSwitcher`.

## 4. Splash, setup, hotkeys, logo
Reuse Cocoon's patterns: `App/Views/Intro/IntroViews.swift` (`IntroGate`, `SplashView.play()`), `App/Views/Brand/CocoonBrand.swift` (`CocoonGeometry` + animatable `CocoonBodyShape`, `Brand` color enum, `CocoonPattern`), `App/Views/SetupView.swift` + `App/Model/SetupModel.swift` (paged `Page` enum, `StepperBar`, `RateMeter`/`FractionETA`), `App/Views/Style/MagicStyle.swift`. Cocoon has **no** global hotkeys, Accessibility onboarding, Liquid Glass or Icon Composer icon — those are new here.

**Logo — "Lizard" mark** (`App/Views/Brand/LizardBrand.swift`, mirrors `CocoonBrand.swift`):
- Minimalist geometric gecko seen from above: S-curve spine (head → body → tail curling into a spiral), four short bent legs, single dot eye, cut out with even-odd fill like Cocoon's butterfly.
- `LizardGeometry` builds the `Path` on a 1024 design grid with `transform(in:)` scaling (copy of `CocoonGeometry` approach) — same path feeds 16pt menu-bar template, in-app mark and app icon.
- `LizardShape: Shape` exposes animatable params via `animatableData` (`AnimatablePair` of `tailCurl` and `legPhase`) — same trick as `CocoonBodyShape.flap`.
- `enum Brand`: ink `#0E1210`, moss `#3DDC84`→ teal `#14B8A6` gradient, sand `#F4F1EA`; `Color(hex:)` copied from `WizardModel.swift:182`.
- Views: `LizardMark`, `LizardAppIcon` (squircle r = size·0.225, gradient, highlight), `LizardWordmark` (SF semibold, tight tracking), `LizardLockup`, `LizardPattern` (TimelineView + Canvas of tiny lizards scurrying, paused on Reduce Motion / inactive window).
- Animations: **draw-on** (`trim` stroke nose→tail, then fill), **tail curl/uncurl** idle, **blink** (eye scaleY), **tongue flick** when the launcher is summoned, **tail wag** as the AI "thinking" indicator.
- Assets: `docs/brand/lizard-mark.svg`, `lizard-mark-white.svg`, `lizard-app-icon-1024.png`; app icon as Icon Composer `AppIcon.icon` (Liquid Glass layers) with an `.appiconset` fallback generated by a small `scripts/make-icons.sh` (rsvg/sips) instead of Cocoon's hand exports.

**Splash** (`App/Views/Intro/`, `IntroGate` pattern): async scripted `play()` — mark draws on (0.6s) → lizard "lands" with spring + 2 tail flicks → blink → wordmark + tagline rise → exit `.opacity + .scale(1.08)`. ~2.5s first launch, ~1s afterwards (launcher apps must feel instant; only shown on launch, never on hotkey summon); any key skips; Reduce Motion jumps to final frame; `preview` flag for SwiftUI previews.

**Setup flow** (`SetupModel` `@Observable @MainActor`, paged sheet with `StepperBar` like Cocoon; keys `Lizard.SetupCompleted`, `Lizard.SetupStep`; reopen from Settings / `⇧⌘,`):
1. Welcome.
2. **Hotkeys** — recorder rows for: Toggle launcher (default **`⌃Space`**; note macOS binds ⌃Space to "Select previous input source" — setup detects multiple keyboard input sources and warns / links to Keyboard Shortcuts settings; warn on `⌘Space` Spotlight conflict too), Work Log HUD (`⌥⇧W`), Clipboard history (`⌥⇧V`), Ask AI (`⌥⇧A`), New note (`⌥⇧N`). Use **sindresorhus/KeyboardShortcuts** (Carbon `RegisterEventHotKey` under the hood, built-in `Recorder` view, conflict detection, UserDefaults persistence) wrapped in `LizardCore/Hotkeys.swift`.
3. **Permissions** — Accessibility (needed for CGEvent auto-paste; `AXIsProcessTrustedWithOptions` + poll until granted), Documents folder access for notes, optional Full Disk not required.
4. **Folders** — Notes and Work Log directories (default `~/Documents/Notes`, `~/Documents/WorkLogs`), picker to change.
5. **AI** — choose: Apple Intelligence only / + local MLX model (catalog `simplePicks()` sized to the Mac, download with progress, stall watchdog, resume ×3 — ported from `SetupModel.downloadModel()`) / + cloud key. Skippable.
6. Done — "Press ⌃Space" live test that detects the hotkey firing.
Hotkeys re-editable later in Settings → Shortcuts (same recorder rows).

## 5. Feature phases (corrected)
1. **Shell + app search** — `NSPanel` subclass with `.nonactivatingPanel`, `.floating`, `canBecomeKey = true` (required, otherwise no typing), `hidesOnDeactivate`, hosting SwiftUI via `NSHostingView`; app runs as `LSUIElement`. Remember frontmost app (`NSWorkspace.frontmostApplication`) on show. `AppIndexer` actor: `NSMetadataQuery` (kMDItemContentType == application) + FSEvents for live updates, icons cached lazily. Fuzzy matcher with frecency ranking (store launch counts). Quicklinks with `{query}` / `{clipboard}` / `{selection}` placeholders, percent-encoded.
2. **Raycast extension host (full support, built early)** — real Raycast extensions are React apps, so stdout `showHUD` messages aren't enough:
   - **Runtime:** bundled Node (signed binary in `Contents/Resources/node`, resolved via `ToolEnvironment`) launched through `ProcessRunner`; one long-lived host process, one isolated context per command.
   - **`@raycast/api` shim** (`ExtensionHost/js/`, TypeScript, built with esbuild into the app bundle): custom **`react-reconciler`** renderer that turns `<List>`, `<List.Item>`, `<Detail>`, `<Form>`, `<Grid>`, `<ActionPanel>`, `<Action.*>` into a serialized view tree; plus `showToast`, `showHUD`, `Clipboard`, `LocalStorage` (backed by a SQLite file per extension), `environment`, `getPreferenceValues`, `open`, `closeMainWindow`, `useNavigation` (push/pop), `@raycast/utils` (`useFetch`, `usePromise`, `useCachedState`).
   - **IPC:** newline-delimited JSON-RPC over stdin/stdout — host→Swift: `render(tree diff)`, `toast`, `hud`, `clipboard.copy`; Swift→host: `event(actionId / searchText / formSubmit / selection)`, `preferences`. Swift side is an `ExtensionHost` actor + `@Observable ExtensionViewModel` that maps the tree onto the native launcher list/detail/form views (same components the native features use).
   - **Install:** fetch extension source from the `raycast/extensions` GitHub repo (per-extension folder), `npm ci --omit=dev` with bundled npm, build with esbuild aliasing `@raycast/api` → shim; manifest (`package.json` commands/preferences) registered as launcher commands.
   - **Compatibility target v1:** `view` + `no-view` commands, List/Detail/Form/ActionPanel, preferences, LocalStorage, Clipboard, toasts; menu-bar commands and OAuth (`OAuth.PKCEClient`) in a follow-up. Maintain a compatibility test list of ~10 popular extensions (e.g. GitHub, Brew, Kill Process, Color Picker, Jira) run headless via `lizardcli ext run <name>`.
   - Security: extensions run with the user's privileges; show manifest + permissions before install, pin to commit SHA.
3. **Notes + Work Log** — `NSTextView` wrapper with incremental markdown highlighting (only re-tokenize edited paragraph); files on disk, external-edit detection via `DispatchSource` file watcher; search via in-memory index rebuilt on change. Work Log HUD appends `- 2026-10-10T14:03 [Xcode] text` to `WorkLogs/YYYY-MM.md`.
4. **Clipboard** — 250ms `changeCount` poll; **skip `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`** (password managers) and user-ignored apps; store text/images/files in SQLite (FTS5 via system `libsqlite3` or GRDB) with size cap and retention; auto-paste = hide panel → activate previous app → `CGEvent` ⌘V (needs Accessibility).
5. **AI** — section 3 (AI chat can also be exposed to extensions via `AI.ask` in the shim, routed to the local/Apple provider).
6. **Dev tools** — port killer (`lsof -iTCP -sTCP:LISTEN -nP` via ProcessRunner, confirm before kill), JSON pretty/minify, JWT decode, Base64, URL encode, UUID, timestamp convert.
7. **Polish** — Settings window, menu-bar item, launch at login (`SMAppService.mainApp`), release script (Developer ID, hardened runtime, notarytool, DMG, Sparkle; bundled Node must be signed with hardened-runtime JIT entitlement `com.apple.security.cs.allow-jit`).

Phase 0 (before 1): brand + splash + setup + hotkeys (section 4), since every later phase hangs off the hotkey and panel.

## Realistic budgets (replace original claims)
- Idle RAM < 40 MB without MLX loaded (MLX framework not initialized until first local generation).
- Panel show < 50 ms from hotkey; keystroke → results < 16 ms for ≤ 2k apps.
- Local model RAM ≈ `downloadGB × 1.15 + 1.5` GB (Cocoon formula); idle-unload after 120s.

## Verification
- `cd Packages/LizardKit && swift build && swift test` (fuzzy matcher, quicklink templating, markdown tokenizer, clipboard filters, JWT/JSON transformers, work log formatting).
- `xcodegen generate && xcodebuild -scheme Lizard -configuration Release -destination 'platform=macOS,arch=arm64' -skipMacroValidation build` (Release: MLX is very slow in Debug; run `xcodebuild -downloadComponent MetalToolchain` once).
- Shim: `cd Packages/LizardKit/Sources/ExtensionHost/js && npm test` (reconciler snapshot tests of view trees); `lizardcli ext run <extension> <command>` prints the rendered tree for the compatibility list.
- `Lizard.app --llm-smoke-test` streams a summary from Apple FM and the chosen MLX model.
- Manual: reset `Lizard.SetupCompleted` → splash + setup run; record hotkeys, verify each fires while VS Code is focused and that typing in the panel doesn't steal focus; copy from 1Password → not stored; auto-paste into TextEdit; Reduce Motion on → splash shows static mark.

---

## Additions (2026-10-10, from the user during implementation)
- **Extensions stay Raycast-compatible**, including **menu-bar commands** (`MenuBarExtra` rendered as native `NSStatusItem` + `NSMenu`, e.g. GitHub icon with a count) and background `interval` refreshes for menu-bar / no-view commands.
- **Default GitHub integration:** pre-offer the user's merged `github-review-requests` extension (raycast/extensions PR #29775): search, menu-bar "My Pull Requests" (5m), attention, activity inbox, watcher. Auth is **GitHub CLI only**: Lizard uses the user's signed-in `gh`, or downloads the official `gh` into `~/.lizard/gh` and runs its browser device-code sign-in (`LizardCore/GitHubCLI.swift`, ported from Cocoon's `GitHubLogin`). Extension preferences preset to `authMethod=gh`, `ghPath=<that gh>`.
- **Cloud AI sign-ins the Cocoon way:** OpenRouter OAuth PKCE in the browser (`AIEngine/OpenRouterAuth.swift`); **OpenCode Zen** provider (`AIEngine/OpenCodeZen.swift`, OpenAI-compatible `https://opencode.ai/zen/v1`) that reuses an existing `opencode auth login` and falls back to the opencode.ai sign-in page or a pasted key (Zen has no third-party OAuth).
- **Built-in extensions, original code** (`Extensions/`, Raycast package format, nothing copied from raycast/extensions): Translate, Slack (deep links, no tokens), 1Password (`op` CLI), Apple Notes, Warp, Apple Reminders (incl. menu-bar), Kill Process.
- **Native Kill Process** in DevTools (`ps` snapshot, CPU/memory sort, SIGTERM/SIGKILL) alongside the port killer.
