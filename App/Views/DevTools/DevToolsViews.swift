import DevTools
import Search
import SwiftUI

/// Text transforms: JSON, JWT, Base64, URL, hashes, cases… Input defaults to the clipboard.
struct DevToolsView: View {
    @Environment(AppModel.self) private var app
    @State private var transform: TextTransform = .jsonPretty
    @State private var input = NSPasteboard.general.string(forType: .string) ?? ""
    @State private var output = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(Brand.moss)
                Text("Developer Tools").font(.headline)
                Spacer()
                Picker("", selection: $transform) {
                    ForEach(TextTransform.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $input).font(.system(.callout, design: .monospaced)).scrollContentBackground(.hidden)
                }
                .padding(12)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output").font(.caption).foregroundStyle(.secondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                        Spacer()
                    } else {
                        ScrollView {
                            Text(output).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
            ActionBar(hints: [("Copy output", "⌘↩")]) {
                Button("Copy output") { app.copyText(output) }.keyboardShortcut(.return, modifiers: .command).disabled(output.isEmpty)
                Button("Paste output") { app.pasteText(output) }.disabled(output.isEmpty)
            }
        }
        .onChange(of: transform) { run() }
        .onChange(of: input) { run() }
        .onAppear(perform: run)
    }

    private func run() {
        do {
            output = try transform.apply(input)
            error = nil
        } catch {
            output = ""
            self.error = error.localizedDescription
        }
    }
}

/// Who's listening on which port; kill with ⌘⌫.
struct PortsView: View {
    @Environment(AppModel.self) private var app
    @State private var processes: [ListeningProcess] = []
    @State private var selection: ListeningProcess.ID?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header(title: "Listening Ports", symbol: "network") { Task { await load() } }
            Divider()
            Table(processes, selection: $selection) {
                TableColumn("Port") { Text(String($0.port)).monospacedDigit() }.width(70)
                TableColumn("Process", value: \.command)
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(70)
                TableColumn("Address", value: \.address).width(120)
                TableColumn("User", value: \.user).width(90)
            }
            .contextMenu(forSelectionType: ListeningProcess.ID.self) { ids in
                Button("Stop") { kill(ids, force: false) }
                Button("Force Kill", role: .destructive) { kill(ids, force: true) }
                Button("Open http://localhost:…") { if let process = processes.first(where: { ids.contains($0.id) }) { NSWorkspace.shared.open(URL(string: "http://localhost:\(process.port)")!) } }
            }
            ActionBar(hints: [("Stop", "⌘⌫"), ("Force", "⌥⌘⌫")]) {
                Text(message ?? "\(processes.count) listening").font(.caption).foregroundStyle(.secondary)
                Button("") { if let selection { kill([selection], force: false) } }.keyboardShortcut(.delete, modifiers: .command).opacity(0)
                Button("") { if let selection { kill([selection], force: true) } }.keyboardShortcut(.delete, modifiers: [.command, .option]).opacity(0)
            }
        }
        .task { await load() }
    }

    private func header(title: String, symbol: String, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Image(systemName: symbol).foregroundStyle(Brand.moss)
            Text(title).font(.headline)
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private func load() async {
        processes = (try? await PortKiller.listeningProcesses()) ?? []
    }

    private func kill(_ ids: Set<ListeningProcess.ID>, force: Bool) {
        for process in processes where ids.contains(process.id) {
            do {
                try PortKiller.kill(process, force: force)
                message = "Stopped \(process.command) on :\(process.port)"
            } catch {
                message = error.localizedDescription
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await load()
        }
    }
}

/// Every process by CPU or memory; stop or force-kill.
struct ProcessesView: View {
    @Environment(AppModel.self) private var app
    @State private var processes: [RunningProcessInfo] = []
    @State private var query = ""
    @State private var selection: RunningProcessInfo.ID?
    @State private var byMemory = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "xmark.octagon").foregroundStyle(Brand.moss)
                TextField("Search processes…", text: $query).textFieldStyle(.plain).font(.system(size: 17))
                Picker("", selection: $byMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            Table(filtered, selection: $selection) {
                TableColumn("Name") { process in
                    HStack(spacing: 6) {
                        if let bundle = process.appBundle {
                            Image(nsImage: IconCache.icon(for: URL(filePath: bundle))).resizable().frame(width: 16, height: 16)
                        }
                        Text(process.name)
                    }
                }
                TableColumn("CPU") { Text(String(format: "%.1f%%", $0.cpu)).monospacedDigit() }.width(70)
                TableColumn("Memory") { Text(ByteCountFormatter.string(fromByteCount: $0.memoryBytes, countStyle: .memory)).monospacedDigit() }.width(90)
                TableColumn("PID") { Text(String($0.pid)).monospacedDigit() }.width(70)
                TableColumn("User", value: \.user).width(90)
            }
            .contextMenu(forSelectionType: RunningProcessInfo.ID.self) { ids in
                Button("Stop") { kill(ids, force: false) }
                Button("Force Kill", role: .destructive) { kill(ids, force: true) }
                Button("Copy PID") { if let pid = ids.first { app.copyText(String(pid)) } }
            }
            ActionBar(hints: [("Stop", "⌘⌫"), ("Force", "⌥⌘⌫"), ("Refresh", "⌘R")]) {
                Text(message ?? "\(processes.count) processes").font(.caption).foregroundStyle(.secondary)
                Button("") { if let selection { kill([selection], force: false) } }.keyboardShortcut(.delete, modifiers: .command).opacity(0)
                Button("") { if let selection { kill([selection], force: true) } }.keyboardShortcut(.delete, modifiers: [.command, .option]).opacity(0)
                Button("") { Task { await load() } }.keyboardShortcut("r", modifiers: .command).opacity(0)
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var filtered: [RunningProcessInfo] {
        let sorted = processes.sorted { byMemory ? $0.memoryBytes > $1.memoryBytes : $0.cpu > $1.cpu }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
    }

    private func load() async {
        processes = (try? await ProcessList.snapshot()) ?? []
    }

    private func kill(_ ids: Set<RunningProcessInfo.ID>, force: Bool) {
        for pid in ids {
            let name = processes.first { $0.pid == pid }?.name ?? String(pid)
            if force {
                let alert = NSAlert()
                alert.messageText = "Force kill \(name)?"
                alert.informativeText = "Unsaved work in it will be lost."
                alert.addButton(withTitle: "Force Kill").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { continue }
            }
            do {
                try ProcessKiller.kill(pid: pid, force: force)
                message = "\(force ? "Killed" : "Stopped") \(name)"
            } catch {
                message = error.localizedDescription
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await load()
        }
    }
}

/// Create, edit and delete quicklinks.
struct QuicklinksView: View {
    @Environment(AppModel.self) private var app
    @State private var links: [Quicklink] = []
    @State private var editing: Quicklink?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "link").foregroundStyle(Brand.moss)
                Text("Quicklinks").font(.headline)
                Spacer()
                Button("New Quicklink") { editing = Quicklink(name: "", template: "https://") }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            if let editing {
                QuicklinkEditor(link: editing) { saved in
                    Task {
                        if let saved { await app.quicklinks.save(saved) }
                        self.editing = nil
                        await load()
                    }
                }
            } else {
                List(links) { link in
                    HStack {
                        Image(systemName: link.symbol).foregroundStyle(Brand.moss).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(link.name)
                            Text(link.template).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let keyword = link.keyword { KeyCap(text: keyword) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = link }
                    .contextMenu {
                        Button("Edit") { editing = link }
                        Button("Delete", role: .destructive) { Task { await app.quicklinks.delete(link.id); await load() } }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
    }

    private func load() async {
        links = await app.quicklinks.links
        app.launcher.refresh()
    }
}

private struct QuicklinkEditor: View {
    @State var link: Quicklink
    let done: (Quicklink?) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $link.name)
            TextField("URL", text: $link.template, prompt: Text("https://example.com/search?q={query}"))
            TextField("Keyword", text: Binding(get: { link.keyword ?? "" }, set: { link.keyword = $0.isEmpty ? nil : $0 }))
            Text("Use {query} for what you type, {clipboard} for the clipboard, {selection} for selected text.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                Button("Save") { done(link) }.buttonStyle(.borderedProminent).tint(Brand.moss)
                    .disabled(link.name.isEmpty || link.template.isEmpty)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
