import AIEngine
import AppKit
import SwiftUI

/// ⌥⇧W: a small floating field. Type what you just finished, press ⌘↩ or Save. The entry is
/// stamped with the time and the app you were in, and appended to this month's Markdown log.
/// The "when" row back-dates an entry: one click for the common cases, a day stepper and time
/// field for anything else. Everything is inline (a popover would take focus and close the HUD).
struct WorkLogHUD: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var saved = false
    /// nil = now.
    @State private var when: Date?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LizardMarkView(size: 20, summon: saved)
                Text("Work Log").font(.headline)
                if when == nil, let context = app.workLogContextApp {
                    Text("· \(context)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Summarize today") { app.summarizeWorkLog(period: .today) }
                    .buttonStyle(.link).font(.caption)
                Button("This week") { app.summarizeWorkLog(period: .week) }
                    .buttonStyle(.link).font(.caption)
                Button("Review…") { app.openPerformanceReview() }
                    .buttonStyle(.link).font(.caption)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(height: Self.editorHeight(for: text))
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        save()
                        return .handled
                    }
                if text.isEmpty {
                    Text(when == nil ? "What did you just finish?" : "What did you do then?")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: text) { _, text in
                app.resizeWorkLog(toHeight: Self.panelHeight(for: text))
            }
            whenRow
            HStack {
                Text(footer).font(.caption).foregroundStyle(saved ? Brand.moss : .secondary).lineLimit(1)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.moss)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Open log") { app.openWorkLogFile() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 560)
        .launcherGlass()
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            editorFocused = true
            saved = false
            when = CommandLine.arguments.contains("--worklog-earlier") ? Self.rounded(.now.addingTimeInterval(-26 * 3_600)) : nil
        }
        .onKeyPress(.escape) { app.hideWorkLog(); return .handled }
        .background {
            // Keyboard: ⌘[ / ⌘] move a day, ⌥↑ / ⌥↓ move 15 minutes, ⌘0 back to now.
            Group {
                Button("") { shift(days: -1) }.keyboardShortcut("[", modifiers: .command)
                Button("") { shift(days: 1) }.keyboardShortcut("]", modifiers: .command)
                Button("") { shift(minutes: -15) }.keyboardShortcut(.upArrow, modifiers: .option)
                Button("") { shift(minutes: 15) }.keyboardShortcut(.downArrow, modifiers: .option)
                Button("") { withAnimation(.snappy) { when = nil } }.keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0)
        }
    }

    // MARK: When

    @ViewBuilder
    private var whenRow: some View {
        HStack(spacing: 6) {
            Image(systemName: when == nil ? "clock" : "clock.arrow.circlepath")
                .foregroundStyle(when == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.moss))
                .frame(width: 18)
            if let date = when {
                Button { shift(days: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("Previous day (⌘[)")
                DatePicker("", selection: dateBinding(date), in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                Button { shift(days: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("Next day (⌘])")
                    .disabled(Calendar.current.isDateInToday(date))
                Text(dayName(date)).font(.callout).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                DatePicker("", selection: dateBinding(date), in: ...Date.now, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                Spacer()
                Button("Now") { withAnimation(.snappy) { when = nil } }.buttonStyle(.link).font(.callout)
            } else {
                chip("Now", selected: true) {}
                chip("1 hour ago") { pick(Self.rounded(.now.addingTimeInterval(-3_600))) }
                if let morning = Self.today(hour: 9, minute: 30), morning < .now {
                    chip("This morning") { pick(morning) }
                }
                chip("Yesterday") { pick(Self.rounded(Calendar.current.date(byAdding: .day, value: -1, to: .now)!)) }
                chip("Earlier…") { pick(Self.rounded(.now)) }
                Spacer()
            }
        }
        .controlSize(.small)
        .frame(height: 24)
    }

    private func chip(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? Brand.moss.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(selected ? Brand.moss : .primary)
        }
        .buttonStyle(.plain)
    }

    private func pick(_ date: Date) {
        withAnimation(.snappy) { when = min(date, .now) }
        editorFocused = true
    }

    private func shift(days: Int = 0, minutes: Int = 0) {
        let base = when ?? Self.rounded(.now)
        var date = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        date = date.addingTimeInterval(Double(minutes) * 60)
        pick(date)
    }

    private func dateBinding(_ current: Date) -> Binding<Date> {
        Binding(get: { when ?? current }, set: { when = min($0, .now) })
    }

    private func dayName(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private var footer: String {
        if saved { return "Saved ✓" }
        guard let when else { return "⌘↩ save · ↩ new line · esc close · ⌘[ earlier day" }
        return "⌘↩ save at \(when.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(when.formatted(date: .omitted, time: .shortened)) · ↩ new line · ⌥↑↓ 15 min · ⌘0 now"
    }

    /// Down to the quarter hour, so picked times look like times people write.
    static func rounded(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 900).rounded(.down) * 900)
    }

    static func today(hour: Int, minute: Int) -> Date? {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)
    }

    /// Estimate wrapped lines at the field's fixed width so the panel grows with the input.
    private static func panelHeight(for text: String) -> CGFloat {
        let lines = lineCount(for: text)
        return 168 + CGFloat(lines - 1) * lineHeight
    }

    private static func editorHeight(for text: String) -> CGFloat {
        34 + CGFloat(lineCount(for: text) - 1) * lineHeight
    }

    private static var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 17)
        return font.ascender - font.descender + font.leading
    }

    private static func lineCount(for text: String) -> Int {
        let font = NSFont.systemFont(ofSize: 17)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 518, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let wrappedLines = Int((bounds.height / lineHeight).rounded(.up))
        let explicitLines = text.components(separatedBy: "\n").count
        return min(14, max(1, max(wrappedLines, explicitLines)))
    }

    // MARK: Save

    private func save() {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        app.appendWorkLog(entry, date: when)
        text = ""
        withAnimation(.spring) { saved = true }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            app.hideWorkLog()
        }
    }
}
