import ExtensionHost
import MarkdownUI
import SwiftUI

/// Renders a running extension command natively: List, Detail, Form or Grid, with its
/// action panel on ↩ / ⌘K, search bar, toasts and navigation.
struct ExtensionView: View {
    @Environment(AppModel.self) private var app
    let session: ExtensionSession
    @State private var showActions = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let failure = session.failure, session.root == nil {
                    ScrollView {
                        Text(failure).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let root = session.root {
                    content(root)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .popover(isPresented: $showActions, arrowEdge: .bottom) {
            ExtensionActionsMenu(actions: currentActions, assets: session.installed.assetsDirectory) { action in
                showActions = false
                perform(action)
            }
        }
        .onKeyPress(characters: ["k"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            showActions.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            if session.pop() { return .handled }
            app.launcher.pop()
            session.stop()
            return .handled
        }
        .onDisappear { if !app.launcher.isShowing(session) { session.stop() } }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if !session.pop() {
                    app.launcher.pop()
                    session.stop()
                }
            } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.borderless)
            if let root = session.root, ["List", "Grid"].contains(root.type) {
                TextField(root.string("searchBarPlaceholder") ?? "Search \(session.command.title)…", text: Binding(
                    get: { session.searchText },
                    set: { value in
                        session.searchText = value
                        session.invoke(root.callback("onSearchTextChange"), [.string(value)])
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit { performPrimary() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onAppear { searchFocused = true }
                if let dropdown = root.slot("searchBarAccessory") {
                    ExtensionDropdown(node: dropdown, session: session)
                }
            } else {
                ExtensionImage(value: .string(session.installed.manifest.icon ?? ""), assets: session.installed.assetsDirectory, size: 20)
                Text(session.root?.string("navigationTitle") ?? session.command.title).font(.headline)
                Spacer()
            }
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let toast = session.toast {
                Image(systemName: toast.style == "FAILURE" ? "xmark.octagon.fill" : toast.style == "ANIMATED" ? "circle.dotted" : "checkmark.circle.fill")
                    .foregroundStyle(toast.style == "FAILURE" ? .red : toast.style == "ANIMATED" ? .secondary : Brand.moss)
                Text(toast.title).font(.caption.weight(.semibold))
                if let message = toast.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let title = toast.actionTitle {
                    Button(title) { session.invoke(toast.actionCallback) }.buttonStyle(.link).font(.caption)
                }
            } else {
                ExtensionImage(value: .string(session.installed.manifest.icon ?? ""), assets: session.installed.assetsDirectory, size: 14)
                Text(session.installed.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let primary = currentActions.first {
                Text(primary.string("title") ?? "").font(.caption).foregroundStyle(.secondary)
                KeyCap(text: "↩")
            }
            Text("Actions").font(.caption).foregroundStyle(.secondary)
            KeyCap(text: "⌘K")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
    }

    private var isLoading: Bool { session.root?.bool("isLoading") == true }

    // MARK: Content

    @ViewBuilder
    private func content(_ root: ViewNode) -> some View {
        switch root.type {
        case "List": ExtensionListView(root: root, session: session, perform: perform)
        case "Grid": ExtensionGridView(root: root, session: session, perform: perform)
        case "Detail": ExtensionDetailView(node: root, assets: session.installed.assetsDirectory)
        case "Form": ExtensionFormView(root: root, session: session)
        default:
            Text("“\(root.type)” isn't supported yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    /// Actions for the selected item, else the root's.
    private var currentActions: [ViewNode] {
        guard let root = session.root else { return [] }
        if let selected = selectedItem(in: root), let panel = selected.slot("actions") {
            return panel.flattenedActions
        }
        if root.type == "List" || root.type == "Grid", let empty = root.first("List.EmptyView") ?? root.first("Grid.EmptyView"), visibleItems(in: root).isEmpty {
            return empty.slot("actions")?.flattenedActions ?? []
        }
        return root.slot("actions")?.flattenedActions ?? []
    }

    private func performPrimary() {
        if let first = currentActions.first { perform(first) }
    }

    func perform(_ action: ViewNode) {
        if action.string("kind") == "submitForm" {
            session.invoke(action.callback("onSubmit"), [.object(session.formValues)])
        } else {
            session.invoke(action.callback("onAction"))
        }
    }

    private func items(in root: ViewNode) -> [ViewNode] {
        var result: [ViewNode] = []
        func walk(_ nodes: [ViewNode]) {
            for node in nodes {
                if node.type == "List.Item" || node.type == "Grid.Item" { result.append(node) }
                else if node.type.hasSuffix(".Section") { walk(node.content) }
            }
        }
        walk(root.content)
        return result
    }

    private func visibleItems(in root: ViewNode) -> [ViewNode] {
        ExtensionListView.filter(items(in: root), root: root, query: session.searchText)
    }

    private func selectedItem(in root: ViewNode) -> ViewNode? {
        let visible = visibleItems(in: root)
        return visible.first { $0.id == session.selectedID } ?? visible.first
    }

    private func moveSelection(_ delta: Int) {
        guard let root = session.root else { return }
        let visible = visibleItems(in: root)
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == session.selectedID } ?? 0
        let next = visible[max(0, min(visible.count - 1, index + delta))]
        session.selectedID = next.id
        session.invoke(root.callback("onSelectionChange"), [next["id"] ?? .null])
    }
}

// MARK: - List

struct ExtensionListView: View {
    let root: ViewNode
    let session: ExtensionSession
    let perform: (ViewNode) -> Void

    /// Raycast filters by title/keywords locally unless the extension handles search itself.
    static func filter(_ items: [ViewNode], root: ViewNode, query: String) -> [ViewNode] {
        // Raycast: `filtering` defaults to on, unless the extension handles onSearchTextChange.
        let filtering = root.bool("filtering") ?? (root["filtering"]?.object != nil || root.callback("onSearchTextChange") == nil)
        guard !query.isEmpty, filtering else { return items }
        let needle = query.lowercased()
        return items.filter { item in
            let haystack = ([item.string("title"), item["title"]?["value"]?.string, item.string("subtitle")] + (item["keywords"]?.array?.map(\.string) ?? []))
                .compactMap { $0?.lowercased() }
            return haystack.contains { $0.contains(needle) }
        }
    }

    private var showsDetail: Bool { root.bool("isShowingDetail") == true }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let sections = grouped()
                        if sections.allSatisfy({ $0.items.isEmpty }) {
                            emptyView
                        }
                        ForEach(sections, id: \.id) { section in
                            if let title = section.title, !section.items.isEmpty {
                                HStack {
                                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if let subtitle = section.subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
                                }
                                .padding(.horizontal, 10).padding(.top, 8)
                            }
                            ForEach(section.items) { item in
                                ExtensionListRow(item: item, assets: session.installed.assetsDirectory, selected: item.id == selectedID, compact: showsDetail)
                                    .id(item.id)
                                    .onTapGesture(count: 2) { if let action = item.slot("actions")?.flattenedActions.first { perform(action) } }
                                    .onTapGesture {
                                        session.selectedID = item.id
                                        session.invoke(root.callback("onSelectionChange"), [item["id"] ?? .null])
                                    }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: session.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .frame(width: showsDetail ? 300 : nil)
            if showsDetail {
                Divider()
                if let selected = selectedItem, let detail = selected.slot("detail") {
                    ExtensionDetailView(node: detail, assets: session.installed.assetsDirectory)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var selectedID: Int? { selectedItem?.id }

    private var selectedItem: ViewNode? {
        let visible = grouped().flatMap(\.items)
        return visible.first { $0.id == session.selectedID } ?? visible.first
    }

    private struct Section {
        let id: Int
        let title: String?
        let subtitle: String?
        let items: [ViewNode]
    }

    private func grouped() -> [Section] {
        var sections: [Section] = []
        var loose: [ViewNode] = []
        for node in root.content {
            switch node.type {
            case "List.Section":
                let items = Self.filter(node.content.filter { $0.type == "List.Item" }, root: root, query: session.searchText)
                sections.append(Section(id: node.id, title: node.string("title"), subtitle: node.string("subtitle"), items: items))
            case "List.Item":
                loose.append(node)
            default:
                break
            }
        }
        if !loose.isEmpty {
            sections.insert(Section(id: -1, title: nil, subtitle: nil, items: Self.filter(loose, root: root, query: session.searchText)), at: 0)
        }
        return sections
    }

    @ViewBuilder
    private var emptyView: some View {
        if let empty = root.first("List.EmptyView") {
            VStack(spacing: 8) {
                ExtensionImage(value: empty["icon"], assets: session.installed.assetsDirectory, size: 40)
                Text(empty.string("title") ?? "No results").font(.headline)
                if let description = empty.string("description") { Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else if root.bool("isLoading") != true {
            Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
        }
    }
}

struct ExtensionListRow: View {
    let item: ViewNode
    let assets: URL
    let selected: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ExtensionImage(value: item["icon"], assets: assets, size: 20)
            Text(item.string("title") ?? item["title"]?["value"]?.string ?? "").lineLimit(1)
            if !compact, let subtitle = item.string("subtitle") ?? item["subtitle"]?["value"]?.string {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !compact {
                ForEach(Array((item["accessories"]?.array ?? []).enumerated()), id: \.offset) { _, accessory in
                    AccessoryView(accessory: accessory, assets: assets)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
        .selectableRow(selected)
    }
}

struct AccessoryView: View {
    let accessory: HostJSON
    let assets: URL

    var body: some View {
        HStack(spacing: 4) {
            if let icon = accessory["icon"] { ExtensionImage(value: icon, assets: assets, size: 14) }
            if let tag = accessory["tag"] {
                let text = tag.string ?? tag["value"]?.string ?? ""
                let color = tag["color"].flatMap(ExtensionColor.color) ?? .secondary
                Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(color).background(color.opacity(0.15), in: Capsule())
            } else if let text = accessory["text"] {
                Text(text.string ?? text["value"]?.string ?? "").font(.caption)
                    .foregroundStyle(text["color"].flatMap(ExtensionColor.color) ?? .secondary)
            } else if let date = accessory["date"] {
                let value = date["$date"]?.string ?? date["value"]?["$date"]?.string
                if let value, let parsed = ISO8601DateFormatter.withFractions.date(from: value) {
                    Text(parsed, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help(accessory["tooltip"]?.string ?? "")
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Grid

struct ExtensionGridView: View {
    let root: ViewNode
    let session: ExtensionSession
    let perform: (ViewNode) -> Void

    var body: some View {
        let columns = Int(root["columns"]?.number ?? 5)
        let items = ExtensionListView.filter(gridItems, root: root, query: session.searchText)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(1, columns)), spacing: 10) {
                ForEach(items) { item in
                    VStack(spacing: 6) {
                        ExtensionImage(value: item["content"], assets: session.installed.assetsDirectory, size: 64)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(item.id == (session.selectedID ?? items.first?.id) ? Brand.moss : .clear, lineWidth: 2))
                        if let title = item.string("title") { Text(title).font(.caption).lineLimit(1) }
                    }
                    .onTapGesture { session.selectedID = item.id }
                    .onTapGesture(count: 2) { if let action = item.slot("actions")?.flattenedActions.first { perform(action) } }
                }
            }
            .padding(12)
        }
    }

    private var gridItems: [ViewNode] {
        root.content.flatMap { node in node.type == "Grid.Section" ? node.content.filter { $0.type == "Grid.Item" } : node.type == "Grid.Item" ? [node] : [] }
    }
}

// MARK: - Detail

struct ExtensionDetailView: View {
    let node: ViewNode
    let assets: URL

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let markdown = node.string("markdown"), !markdown.isEmpty {
                ScrollView {
                    Markdown(markdown).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let metadata = node.slot("metadata") {
                if node.string("markdown")?.isEmpty == false { Divider() }
                ScrollView {
                    MetadataView(node: metadata, assets: assets).padding(14)
                }
                .frame(width: node.string("markdown")?.isEmpty == false ? 240 : nil)
                .frame(maxWidth: node.string("markdown")?.isEmpty == false ? 240 : .infinity, alignment: .leading)
            }
        }
    }
}

struct MetadataView: View {
    let node: ViewNode
    let assets: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(node.content) { item in
                switch item.type {
                case "Metadata.Label":
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.string("title") ?? "").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if let icon = item["icon"] { ExtensionImage(value: icon, assets: assets, size: 14) }
                            Text(item.string("text") ?? item["text"]?["value"]?.string ?? "").font(.callout).textSelection(.enabled)
                        }
                    }
                case "Metadata.Link":
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.string("title") ?? "").font(.caption).foregroundStyle(.secondary)
                        if let target = item.string("target"), let url = URL(string: target) {
                            Link(item.string("text") ?? target, destination: url).font(.callout)
                        }
                    }
                case "Metadata.TagList":
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.string("title") ?? "").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(item.content) { tag in
                                let color = tag["color"].flatMap(ExtensionColor.color) ?? .secondary
                                Text(tag.string("text") ?? "").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .foregroundStyle(color).background(color.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                case "Metadata.Separator":
                    Divider()
                default:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Form

struct ExtensionFormView: View {
    let root: ViewNode
    let session: ExtensionSession

    var body: some View {
        Form {
            ForEach(root.content) { field in
                ExtensionFormField(field: field, session: session)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct ExtensionFormField: View {
    let field: ViewNode
    let session: ExtensionSession

    private var id: String { field.string("id") ?? "\(field.id)" }

    private var value: HostJSON? {
        field["value"].flatMap { $0.isNull ? nil : $0 } ?? session.formValues[id] ?? field["defaultValue"]
    }

    private func set(_ newValue: HostJSON) {
        session.formValues[id] = newValue
        session.invoke(field.callback("onChange"), [newValue])
    }

    var body: some View {
        Group {
            switch field.type {
            case "Form.TextField":
                TextField(field.string("title") ?? "", text: textBinding, prompt: field.string("placeholder").map(Text.init))
            case "Form.PasswordField":
                SecureField(field.string("title") ?? "", text: textBinding, prompt: field.string("placeholder").map(Text.init))
            case "Form.TextArea":
                LabeledContent(field.string("title") ?? "") {
                    TextEditor(text: textBinding).frame(minHeight: 80).font(.body)
                }
            case "Form.Checkbox":
                Toggle(field.string("label") ?? field.string("title") ?? "", isOn: Binding(
                    get: { value?.bool ?? false }, set: { set(.bool($0)) }))
            case "Form.Dropdown":
                Picker(field.string("title") ?? "", selection: Binding(
                    get: { value?.string ?? dropdownItems.first?.string("value") ?? "" }, set: { set(.string($0)) })) {
                    ForEach(dropdownItems) { item in
                        Text(item.string("title") ?? "").tag(item.string("value") ?? "")
                    }
                }
            case "Form.DatePicker":
                DatePicker(field.string("title") ?? "", selection: Binding(
                    get: { value?["$date"]?.string.flatMap { ISO8601DateFormatter.withFractions.date(from: $0) } ?? .now },
                    set: { set(.object(["$date": .string(ISO8601DateFormatter.withFractions.string(from: $0))])) }))
            case "Form.Description":
                LabeledContent(field.string("title") ?? "") { Text(field.string("text") ?? "").foregroundStyle(.secondary) }
            case "Form.Separator":
                Divider()
            case "Form.TagPicker":
                LabeledContent(field.string("title") ?? "") {
                    Text(field.content.compactMap { $0.string("title") }.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .help(field.string("info") ?? "")
        .overlay(alignment: .bottomTrailing) {
            if let error = field.string("error") { Text(error).font(.caption2).foregroundStyle(.red) }
        }
        .onAppear {
            if session.formValues[id] == nil, let initial = field["defaultValue"] ?? field["value"], !initial.isNull {
                session.formValues[id] = initial
            }
            if field.type == "Form.Dropdown", session.formValues[id] == nil, let first = dropdownItems.first?["value"] {
                session.formValues[id] = first
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { value?.string ?? "" }, set: { set(.string($0)) })
    }

    private var dropdownItems: [ViewNode] {
        field.content.flatMap { $0.type == "Form.Dropdown.Section" ? $0.content : [$0] }.filter { $0.type == "Form.Dropdown.Item" }
    }
}

// MARK: - Dropdown & actions

struct ExtensionDropdown: View {
    let node: ViewNode
    let session: ExtensionSession
    @State private var selection: String = ""

    var body: some View {
        Picker(node.string("tooltip") ?? "", selection: Binding(
            get: { node.string("value") ?? (selection.isEmpty ? (node.string("defaultValue") ?? items.first?.string("value") ?? "") : selection) },
            set: { value in
                selection = value
                session.invoke(node.callback("onChange"), [.string(value)])
            })) {
            ForEach(items) { item in Text(item.string("title") ?? "").tag(item.string("value") ?? "") }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private var items: [ViewNode] {
        node.content.flatMap { $0.type == "List.Dropdown.Section" ? $0.content : [$0] }.filter { $0.type == "List.Dropdown.Item" }
    }
}

struct ExtensionActionsMenu: View {
    let actions: [ViewNode]
    let assets: URL
    let run: (ViewNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if actions.isEmpty { Text("No actions").foregroundStyle(.secondary).padding(8) }
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if action.type == "ActionPanel.Submenu" {
                    Menu {
                        ForEach(action.flattenedActions) { inner in
                            Button(inner.string("title") ?? "") { run(inner) }
                        }
                    } label: {
                        Label(action.string("title") ?? "", systemImage: "chevron.right")
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                } else {
                    Button { run(action) } label: {
                        HStack {
                            ExtensionImage(value: action["icon"], assets: assets, size: 16)
                            Text(action.string("title") ?? "")
                                .foregroundStyle(action.string("style") == "destructive" ? .red : .primary)
                            Spacer()
                            if index == 0 { KeyCap(text: "↩") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 260)
    }
}
