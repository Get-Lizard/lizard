# Lizard

Native macOS 26 launcher (Raycast-style). Read `AGENTS.md` first, and `docs/PLAN.md` for the roadmap.

- Swift 6.2, strict concurrency. State models are `@Observable @MainActor final class`; engines are `actor`s. No Combine / `ObservableObject`.
- All UI-free logic lives in `Packages/LizardKit`; `App/` is SwiftUI/AppKit only.
- Subprocesses go through `ProcessRunner` (never `Process` directly); tool lookup through `ToolEnvironment.shared`.
- Persist with `ResilientFile`; UserDefaults keys are namespaced `Lizard.*`.
- Patterns are ported from Cocoon (`~/projects/magicbuilder`) — check there before inventing.
