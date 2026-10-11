import AIEngine
import Notes
import SwiftUI

/// Pick a period, see what the work log holds for it, then let the AI write a self-review.
struct PerformanceReviewView: View {
    @Environment(AppModel.self) private var app

    enum Period: String, CaseIterable, Identifiable {
        case month = "Last month", quarter = "Last 3 months", half = "Last 6 months", year = "This year", lastYear = "Last year", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var period: Period = .quarter
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -3, to: .now)!
    @State private var customEnd = Date.now
    @State private var focus = ""
    @FocusState private var focusField: Bool
    /// Loaded off the main thread whenever the period changes (a year spans 13 files).
    @State private var entries: [WorkLogEntry] = []

    /// Changes only when the chosen period does (not every second, as `range.end` would).
    private var periodKey: String { "\(period.rawValue)|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)" }

    var body: some View {
        let range = self.range
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "medal").foregroundStyle(Brand.moss)
                Text("Performance Review").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Period").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(Array(Period.allCases.enumerated()), id: \.element) { index, option in
                                Button { withAnimation(.snappy) { period = option } } label: {
                                    Text(option.rawValue)
                                        .font(.callout)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(period == option ? Brand.moss.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
                                        .foregroundStyle(period == option ? Brand.moss : .primary)
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                .help("⌘\(index + 1)")
                            }
                        }
                        if period == .custom {
                            HStack(spacing: 8) {
                                Text("From").foregroundStyle(.secondary)
                                DatePicker("", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                                    .datePickerStyle(.field).labelsHidden().fixedSize()
                                Text("to").foregroundStyle(.secondary)
                                DatePicker("", selection: $customEnd, in: customStart...Date.now, displayedComponents: .date)
                                    .datePickerStyle(.field).labelsHidden().fixedSize()
                            }
                            .font(.callout)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Anything to emphasize? (optional)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("e.g. technical leadership, the payments migration, promotion to senior", text: $focus)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusField)
                            .onSubmit { write(entries, range: range) }
                    }

                    summary(entries, range: range)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ActionBar(hints: [("Write review", "↩"), ("Back", "esc")]) {
                Button("Write review") { write(entries, range: range) }
                    .buttonStyle(.borderedProminent).tint(Brand.moss).controlSize(.small)
                    .disabled(entries.isEmpty)
            }
        }
        .onAppear { focusField = true }
        .task(id: periodKey) {
            let store = app.workLog
            let span = range
            entries = await Task.detached(priority: .userInitiated) { store.entries(from: span.start, to: span.end) }.value
        }
    }

    @ViewBuilder
    private func summary(_ entries: [WorkLogEntry], range: (start: Date, end: Date)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")").font(.title3.weight(.semibold))
                Text(Self.label(range)).foregroundStyle(.secondary)
                Spacer()
                if !entries.isEmpty {
                    let days = Set(entries.map { Calendar.current.startOfDay(for: $0.date) }).count
                    Text("\(days) days logged").font(.caption).foregroundStyle(.secondary)
                }
            }
            if entries.isEmpty {
                Text("Nothing logged in this period. Press ⌥⇧W any time to add a line, or back-date one with ⌘[.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.suffix(6).reversed().enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Text(entry.text).font(.callout).lineLimit(1)
                    }
                }
                if entries.count > 6 {
                    Text("and \(entries.count - 6) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .surface()
    }

    private var range: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date.now
        let startOfToday = calendar.startOfDay(for: now)
        switch period {
        case .month: return (calendar.date(byAdding: .month, value: -1, to: startOfToday)!, now)
        case .quarter: return (calendar.date(byAdding: .month, value: -3, to: startOfToday)!, now)
        case .half: return (calendar.date(byAdding: .month, value: -6, to: startOfToday)!, now)
        case .year: return (calendar.date(from: calendar.dateComponents([.year], from: now))!, now)
        case .lastYear:
            let thisYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return (calendar.date(byAdding: .year, value: -1, to: thisYear)!, thisYear.addingTimeInterval(-1))
        case .custom:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))!.addingTimeInterval(-1)
            return (calendar.startOfDay(for: customStart), min(end, now))
        }
    }

    static func label(_ range: (start: Date, end: Date)) -> String {
        let sameYear = Calendar.current.isDate(range.start, equalTo: range.end, toGranularity: .year)
        let start = range.start.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
        return "\(start) to \(range.end.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private func write(_ entries: [WorkLogEntry], range: (start: Date, end: Date)) {
        guard !entries.isEmpty else { return }
        let job = AIJob.performanceReview(
            entries: WorkLogStore.text(of: entries, limit: 24_000),
            period: Self.label(range),
            focus: focus.trimmingCharacters(in: .whitespacesAndNewlines))
        app.launcher.push(.aiJob(job))
    }
}
