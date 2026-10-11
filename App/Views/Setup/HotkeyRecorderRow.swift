import KeyboardShortcuts
import SwiftUI

/// One shortcut row: what it does, a recorder, and a warning when the combo collides with macOS.
struct HotkeyRecorderRow: View {
    let action: HotkeyAction
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.moss)
                    .frame(width: 28, height: 28)
                    .background(Brand.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.body.weight(.medium))
                    Text(action.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder(for: action.name) { shortcut in
                    warning = HotkeyConflicts.warning(for: shortcut)
                    if action.name == .toggleLauncher {
                        LauncherShortcut.hasChosen = true
                        Task { await SpotlightShortcut.sync(launcher: shortcut) }
                    }
                }
            }
            if let warning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Link("Open", destination: HotkeyConflicts.keyboardShortcutsSettings).font(.caption)
                }
                .padding(.leading, 40)
            }
        }
        .padding(10)
        .surface()
        .onAppear { warning = HotkeyConflicts.warning(for: KeyboardShortcuts.getShortcut(for: action.name)) }
    }
}

/// "Open Lizard with": ⌘Space (recommended, replaces Spotlight's shortcut), ⌃Space, or any
/// shortcut you record. In Setup, ⌘Space shows as chosen until you pick something else.
struct LauncherShortcutPicker: View {
    /// Setup preselects ⌘Space and applies it on Continue; Settings shows the live value.
    var preselectCommandSpace = false
    @State private var current = LauncherShortcut.current
    @State private var showRecorder = false
    @State private var spotlightOn = SpotlightShortcut.isEnabled

    private enum Choice { case commandSpace, controlSpace, other }

    private var choice: Choice {
        if preselectCommandSpace, !LauncherShortcut.hasChosen { return .commandSpace }
        if showRecorder { return .other }
        if LauncherShortcut.same(current, LauncherShortcut.commandSpace) { return .commandSpace }
        if LauncherShortcut.same(current, LauncherShortcut.controlSpace) { return .controlSpace }
        return .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                option(.commandSpace, keys: ["⌘", "Space"], title: "Recommended", detail: "Replaces Spotlight's shortcut") {
                    choose(LauncherShortcut.commandSpace)
                }
                option(.controlSpace, keys: ["⌃", "Space"], title: "Keep Spotlight", detail: "Spotlight stays on ⌘Space") {
                    choose(LauncherShortcut.controlSpace)
                }
                option(.other, keys: ["…"], title: "Your own", detail: "Record any shortcut") {
                    showRecorder = true
                }
            }
            if choice == .other {
                HStack {
                    Text("Press the keys you want:").font(.callout).foregroundStyle(.secondary)
                    KeyboardShortcuts.Recorder(for: .toggleLauncher) { shortcut in
                        // The recorder also reports the existing value; only a real change counts as a choice.
                        guard !LauncherShortcut.same(shortcut, current) else { return }
                        current = shortcut
                        LauncherShortcut.hasChosen = true
                        Task { await SpotlightShortcut.sync(launcher: shortcut); spotlightOn = SpotlightShortcut.isEnabled }
                    }
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { current = LauncherShortcut.current; spotlightOn = SpotlightShortcut.isEnabled }
    }

    private var note: String {
        switch choice {
        case .commandSpace:
            spotlightOn && !LauncherShortcut.hasChosen
                ? "Lizard will turn off Spotlight's ⌘Space shortcut. Spotlight still opens from the menu bar, and choosing another shortcut here gives ⌘Space back to it."
                : "Spotlight's ⌘Space shortcut is off. Choose another shortcut here any time and Lizard gives ⌘Space back to Spotlight."
        case .controlSpace:
            "⌃Space can also switch keyboard input sources if you use more than one language."
        case .other:
            "Any combination works. ⌘Space is handed back to Spotlight if Lizard had taken it."
        }
    }

    private func choose(_ shortcut: KeyboardShortcuts.Shortcut) {
        showRecorder = false
        current = shortcut
        Task {
            await LauncherShortcut.use(shortcut)
            spotlightOn = SpotlightShortcut.isEnabled
        }
    }

    private func option(_ value: Choice, keys: [String], title: String, detail: String, action: @escaping () -> Void) -> some View {
        let selected = choice == value
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? Brand.moss.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Brand.moss : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
