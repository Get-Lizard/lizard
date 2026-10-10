import AIEngine
import KeyboardShortcuts
import SwiftUI

/// First-run setup, a paged sheet like Cocoon's: stepper, push transitions, ↩ / Esc shortcuts.
struct SetupView: View {
    @Environment(AppModel.self) private var app
    var onFinish: () -> Void

    private var setup: SetupModel { app.setup }

    var body: some View {
        VStack(spacing: 0) {
            StepperBar(current: setup.page)
                .padding(.top, 18)
                .padding(.bottom, 8)
            ZStack {
                page(setup.page)
                    .id(setup.page)
                    .transition(.asymmetric(
                        insertion: .push(from: setup.forward ? .trailing : .leading),
                        removal: .push(from: setup.forward ? .trailing : .leading)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 640, height: 560)
        .background(Brand.ink.opacity(0.02))
    }

    @ViewBuilder
    private func page(_ page: SetupModel.Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch page {
                case .welcome: WelcomePage()
                case .hotkeys: HotkeysPage()
                case .permissions: PermissionsPage()
                case .folders: FoldersPage()
                case .ai: AIPage()
                case .github: GitHubPage()
                case .raycast: RaycastPage()
                case .done: DonePage()
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var footer: some View {
        HStack {
            if setup.page != .welcome {
                Button("Back") { withAnimation(.smooth(duration: 0.45)) { setup.back() } }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if setup.page == .done {
                Button("Start using Lizard") {
                    setup.finish()
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Brand.moss)
            } else {
                if setup.page != .welcome {
                    Button("Skip setup") {
                        setup.finish()
                        onFinish()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Button(setup.page == .welcome ? "Get started" : "Continue") {
                    withAnimation(.smooth(duration: 0.45)) { setup.next() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Brand.moss)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(.bar)
    }
}

private struct StepperBar: View {
    let current: SetupModel.Page

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupModel.pages, id: \.self) { page in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(page.rawValue <= current.rawValue ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.fill.tertiary))
                        .frame(height: 4)
                    Text(page.title)
                        .font(.caption2)
                        .foregroundStyle(page == current ? .primary : .tertiary)
                }
            }
        }
        .padding(.horizontal, 36)
        .animation(.smooth, value: current)
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            LizardMarkView(size: 120)
                .padding(.top, 24)
            LizardWordmark(size: 40)
            Text("A fast, private launcher for your Mac.\nApps, notes, clipboard, AI and extensions — one shortcut away.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Feature(symbol: "lock.shield", text: "Runs on your Mac")
                Feature(symbol: "bolt", text: "Opens instantly")
                Feature(symbol: "puzzlepiece.extension", text: "Raycast extensions")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private struct Feature: View {
        let symbol: String
        let text: String
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Brand.moss)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 140, height: 70)
            .surface()
        }
    }
}

private struct HotkeysPage: View {
    var body: some View {
        PageHeader(title: "Pick your shortcuts", subtitle: "Click a shortcut and press the keys you want. You can change them any time in Settings.")
        ForEach(HotkeyAction.all) { action in
            HotkeyRecorderRow(action: action)
        }
    }
}

private struct PermissionsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageHeader(title: "One permission", subtitle: "Lizard pastes clipboard items and snippets straight into the app you were using. macOS asks you to allow that under Accessibility.")
        HStack(spacing: 14) {
            Image(systemName: app.setup.accessibilityGranted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 28))
                .foregroundStyle(app.setup.accessibilityGranted ? Brand.moss : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility").font(.headline)
                Text(app.setup.accessibilityGranted ? "Allowed — auto-paste is on." : "Needed for auto-paste. Everything else works without it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !app.setup.accessibilityGranted {
                Button("Allow…") { app.setup.requestAccessibility() }
                    .buttonStyle(.borderedProminent).tint(Brand.moss)
            }
        }
        .padding(14)
        .surface()
        if !app.setup.accessibilityGranted {
            Button("Open Privacy & Security settings") { app.setup.openAccessibilitySettings() }
                .buttonStyle(.link)
        }
        Text("Lizard never records keystrokes. Clipboard history skips passwords copied from password managers.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct FoldersPage: View {
    @Environment(AppModel.self) private var app
    @State private var notes = Preferences.notesFolder
    @State private var workLog = Preferences.workLogFolder

    var body: some View {
        PageHeader(title: "Where your notes live", subtitle: "Notes and work logs are plain Markdown files — open them in any editor, sync them however you like.")
        row(title: "Notes", symbol: "note.text", url: notes) {
            if let url = app.setup.choose(folder: notes, prompt: "Use for Notes") { notes = url; Preferences.notesFolder = url }
        }
        row(title: "Work Log", symbol: "list.bullet.clipboard", url: workLog) {
            if let url = app.setup.choose(folder: workLog, prompt: "Use for Work Log") { workLog = url; Preferences.workLogFolder = url }
        }
    }

    private func row(title: String, symbol: String, url: URL, change: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Brand.moss).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Change…", action: change)
        }
        .padding(12)
        .surface()
    }
}

private struct AIPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PageHeader(title: "Private AI", subtitle: "Summaries, explanations and chat run on this Mac by default. Nothing leaves it unless you connect a cloud AI.")
        AISetupSection()
    }
}

private struct GitHubPage: View {
    var body: some View {
        PageHeader(title: "GitHub in your menu bar", subtitle: "Sign in once with your browser — no tokens. Lizard adds GitHub Review Requests: pull requests waiting on you, right in the menu bar.")
        GitHubConnectSection()
    }
}

private struct RaycastPage: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false

    var body: some View {
        PageHeader(title: "Coming from Raycast?", subtitle: "Lizard found Raycast on this Mac. Bring your extensions along — they run in Lizard as they are — and import your quicklinks.")
        RaycastImportView(onDone: {}).environment(app).frame(minHeight: 330)
    }
}

private struct DonePage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            LizardMarkView(size: 96, summon: app.setup.hotkeyTestPassed)
                .padding(.top, 20)
            Text(app.setup.hotkeyTestPassed ? "That's it — Lizard is ready." : "Try your shortcut now")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleLauncher) {
                Text(app.setup.hotkeyTestPassed ? "Press \(shortcut.description) any time." : "Press \(shortcut.description) — the launcher opens over any app.")
                    .foregroundStyle(.secondary)
                Text(shortcut.description)
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(app.setup.hotkeyTestPassed ? AnyShapeStyle(Brand.moss.opacity(0.2)) : AnyShapeStyle(.fill.tertiary),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .animation(.spring, value: app.setup.hotkeyTestPassed)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
