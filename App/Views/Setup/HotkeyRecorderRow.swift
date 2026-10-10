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
