import AIEngine
import SwiftUI

/// ⌥⇧W: a small floating field. Type what you just did, press ↩, keep working. The entry is
/// stamped with the time and the app you were in, and appended to this month's Markdown log.
struct WorkLogHUD: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LizardMarkView(size: 20, summon: saved)
                Text("Work Log").font(.headline)
                if let context = app.workLogContextApp {
                    Text("· \(context)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Summarize today") { app.summarizeWorkLog(period: .today) }
                    .buttonStyle(.link).font(.caption)
                Button("This week") { app.summarizeWorkLog(period: .week) }
                    .buttonStyle(.link).font(.caption)
            }
            TextField("What did you just finish?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Text(saved ? "Saved ✓" : "↩ to save · esc to close").font(.caption).foregroundStyle(saved ? Brand.moss : .secondary)
                Spacer()
                Button("Open log") { app.openWorkLogFile() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 520)
        .launcherGlass()
        .onAppear { focused = true; saved = false }
        .onKeyPress(.escape) { app.hideWorkLog(); return .handled }
    }

    private func save() {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        app.appendWorkLog(entry)
        text = ""
        withAnimation(.spring) { saved = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            app.hideWorkLog()
        }
    }
}
