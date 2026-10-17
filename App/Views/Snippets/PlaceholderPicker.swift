import SwiftUI

/// The snippet editor's placeholder list (Raycast's "+" menu), opened by + or by typing `{`.
/// Type to filter, ↑↓ to move, ↩ to insert, esc to close.
struct PlaceholderPicker: View {
    struct Item: Identifiable, Hashable {
        /// Stands in for `{argument name="…"}`, whose name the editor picks.
        static let argumentToken = "{argument}"

        var title: String
        var symbol: String
        var token: String
        var example: String?
        var section: String?

        var id: String { token }
    }

    let items: [Item]
    let choose: (Item) -> Void
    @State private var filter = ""
    @State private var selectedID: String?
    @FocusState private var focused: Bool

    private static let modifiersHint = "Add modifiers with |  uppercase, lowercase, trim, percent-encode, json-stringify"

    var body: some View {
        let shown = filtered
        let selected = shown.first { $0.id == selectedID } ?? shown.first
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search placeholders…", text: $filter)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .onSubmit { if let selected { choose(selected) } }
                .onKeyPress(.downArrow) { move(1, in: shown); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: shown); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            if item.section != nil, index == 0 || shown[index - 1].section != item.section {
                                if index > 0 { Divider().padding(.vertical, 4) }
                                Text(item.section ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 3)
                            }
                            row(item, selected: item.id == selected?.id).id(item.id)
                        }
                        if shown.isEmpty {
                            Text("No placeholder matches “\(filter)”. Esc keeps the {.").foregroundStyle(.secondary).padding(10)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .frame(height: 330)
            Divider()
            Text(Self.modifiersHint).font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 340)
        .onAppear { focused = true }
        .onChange(of: filter) { selectedID = nil }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(item.title).lineLimit(1)
                Spacer(minLength: 8)
                if let example = item.example { Text(example).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .selectableRow(selected)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selectedID = item.id } }
    }

    private var filtered: [Item] {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(text) || $0.token.lowercased().contains(text) || ($0.section?.lowercased().contains(text) ?? false) }
    }

    private func move(_ delta: Int, in shown: [Item]) {
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selectedID } ?? 0
        selectedID = shown[max(0, min(shown.count - 1, index + delta))].id
    }
}
