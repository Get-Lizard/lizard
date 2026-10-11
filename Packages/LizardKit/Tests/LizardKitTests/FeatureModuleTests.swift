import Clipboard
@testable import DevTools
import Foundation
@testable import Knowledge
import LizardCore
@testable import Notes
@testable import Screenshots
@testable import Search
import Synchronization
import Testing

private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct QuicklinkTests {
    @Test func placeholdersAreFilledOnce() {
        let link = Quicklink(name: "Search", template: "https://x.test/?q={query}&c={clipboard}&s={selection}")
        #expect(link.needsQuery)
        let url = link.resolve(query: "{clipboard}", clipboard: "secret")
        // The typed "{clipboard}" stays literal text; only the template's own placeholder is replaced.
        #expect(url?.absoluteString == "https://x.test/?q=%7Bclipboard%7D&c=secret&s=%7Bclipboard%7D")
        #expect(link.resolve(query: "q", selection: "sel")?.absoluteString == "https://x.test/?q=q&c=&s=sel")
    }

    @Test func unknownBracesAreKept() {
        let link = Quicklink(name: "Raw", template: "myapp://open?json={\"a\":1}&q={query}")
        #expect(link.resolve(query: "x").map { $0.absoluteString.removingPercentEncoding ?? "" } == "myapp://open?json={\"a\":1}&q=x")
    }

    @Test func filePathsAndTilde() {
        let link = Quicklink(name: "Folder", template: "~/Projects/{query}")
        #expect(!Quicklink(name: "n", template: "https://a.b").needsQuery)
        let url = link.resolve(query: "lizard")
        #expect(url?.isFileURL == true)
        #expect(url?.path == FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/lizard").path)
    }

    @Test func raycastExportConversion() throws {
        let json = """
            [{"name":"GH","link":"https://github.com/search?q={Query}"},
             {"name":"Clip","link":"https://x.test/{Clipboard Text}/{Selected Text}"},
             {"name":"Arg","link":"https://y.test/{argument name=\\"term\\" default=\\"x\\"}"},
             {"name":"App","link":"raycast://extensions"},
             {"link":"https://no-name.test"}]
            """
        let links = Quicklink.fromRaycastExport(Data(json.utf8))
        #expect(links.map(\.template) == [
            "https://github.com/search?q={query}", "https://x.test/{clipboard}/{selection}", "https://y.test/{query}", "raycast://extensions",
        ])
        #expect(links.last?.symbol == "arrow.up.forward.app")
        #expect(Quicklink.fromRaycastExport(Data("{}".utf8)).isEmpty)
        #expect(!Quicklink.defaults.isEmpty)
    }

    @Test func storePersistsAndMerges() async throws {
        let url = try tempDirectory("quicklinks").appending(path: "quicklinks.json")
        let store = QuicklinkStore(url: url)
        #expect(await store.links == Quicklink.defaults)
        let changes = Mutex(0)
        await store.setOnChange { changes.withLock { $0 += 1 } }
        var link = Quicklink(name: "Docs", template: "https://docs.test/{query}", keyword: "d")
        await store.save(link)
        link.name = "Docs!"
        await store.save(link)
        #expect(await store.links.filter { $0.id == link.id }.map(\.name) == ["Docs!"])
        let added = await store.merge([Quicklink(name: "dup", template: link.template), Quicklink(name: "new", template: "https://n.test")])
        #expect(added == 1)
        await store.delete(link.id)
        #expect(await store.links.contains { $0.id == link.id } == false)
        #expect(changes.withLock { $0 } == 4)
        // A fresh store reads what was saved.
        #expect(await QuicklinkStore(url: url).links.map(\.name).contains("new"))
        await store.replaceAll([])
        #expect(await QuicklinkStore(url: url).links.isEmpty)
    }
}

@Suite struct SearchRankingTests {
    @Test func emptyQueryShowsOnlyUsedItems() {
        let candidates = [SearchCandidate(id: "a", title: "Alpha"), SearchCandidate(id: "b", title: "Beta"), SearchCandidate(id: "c", title: "Gamma", weight: 0.5)]
        let ranked = SearchEngine.rank(candidates, query: "  ", frecency: { $0 == "b" ? 2 : 0 })
        #expect(ranked.map(\.id) == ["b", "c"])
    }

    @Test func keywordsAndFrecencyAndLimit() {
        let candidates = [
            SearchCandidate(id: "code", title: "Visual Studio Code", keywords: ["vscode"]),
            SearchCandidate(id: "xcode", title: "Xcode"),
            SearchCandidate(id: "other", title: "Calendar"),
        ]
        let ranked = SearchEngine.rank(candidates, query: "vscode", frecency: { _ in 0 })
        #expect(ranked.first?.id == "code")
        #expect(ranked.first?.highlights.isEmpty == true)  // matched through a keyword
        let boosted = SearchEngine.rank(candidates, query: "code", frecency: { $0 == "code" ? 50 : 0 })
        #expect(boosted.first?.id == "code")
        #expect(SearchEngine.rank(candidates, query: "code", frecency: { _ in 0 }, limit: 1).count == 1)
        #expect(SearchEngine.rank(candidates, query: "zzz", frecency: { _ in 0 }).isEmpty)
    }

    @Test func frecencyPersistsAndAccumulates() {
        let url = FileManager.default.temporaryDirectory.appending(path: "frecency-\(UUID()).json")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let frecency = Frecency(url: url)
        frecency.record("x", now: now)
        frecency.record("x", now: now)
        #expect(frecency.boost(for: "x", now: now) == 2)
        #expect(frecency.boost(for: "never", now: now) == 0)
        #expect(Frecency(url: url).boost(for: "x", now: now) == 2)
    }

    @Test func appIndexerFindsBundles() async throws {
        let root = try tempDirectory("apps")
        for path in ["Alpha.app", "Utilities/Beta.app", "Deep/Deeper/Gamma.app"] {
            try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        let indexer = AppIndexer(roots: [root, root.appending(path: "missing")])
        let apps = await indexer.refresh()
        let names = Set(apps.map(\.name))
        #expect(names.isSuperset(of: ["Alpha", "Beta"]))
        #expect(!names.contains("Gamma"))  // deeper than two levels
        #expect(apps.allSatisfy { $0.id == $0.path.path })
    }
}

@Suite struct TextTransformMoreTests {
    @Test(arguments: [
        (TextTransform.jsonSortKeys, #"{"b":1,"a":[1,2]}"#, "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}"),
        (.jsonMinify, "\"just a string\"", "\"just a string\""),
        (.urlEncode, "a b&c=d/e", "a%20b%26c%3Dd%2Fe"),
        (.urlDecode, "a+b%26c", "a b&c"),
        (.md5, "abc", "900150983cd24fb0d6963f7d28e17f72"),
        (.sha1, "abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (.sha256, "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (.kebabCase, "HTTPServerError", "http-server-error"),
        (.titleCase, "hello_WORLD again", "Hello World Again"),
        (.camelCase, "Version2Beta", "version2Beta"),
        (.upperCase, "ß", "SS"),
        (.lowerCase, "ÀB", "àb"),
        (.htmlEncode, "<a href=\"x\">'&'</a>", "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;"),
        (.htmlDecode, "&amp;lt; &lt;b&gt; &quot;&#39;&apos;&nbsp;", "&lt; <b> \"'' "),
        (.count, "one two\nthree", "13 characters · 3 words · 2 lines · 13 bytes"),
        (.count, "", "0 characters · 0 words · 0 lines · 0 bytes"),
        (.base64Decode, "bGl6YXJk", "lizard"),
        (.base64Decode, "_-8", "\u{FFFD}"),
    ] as [(TextTransform, String, String)])
    func transforms(transform: TextTransform, input: String, output: String) throws {
        if transform == .base64Decode, output == "\u{FFFD}" {
            // URL-safe alphabet + missing padding are accepted; invalid UTF-8 is an error.
            #expect(throws: TransformError.self) { try transform.apply(input) }
            return
        }
        #expect(try transform.apply(input) == output)
    }

    @Test func timestampsBothWays() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try TextTransform.timestamp.apply("", now: now).hasPrefix("1700000000\n2023-11-14T22:13:20Z"))
        #expect(try TextTransform.timestamp.apply("2023-11-14T22:13:20Z") == "1700000000\n1700000000000 ms")
        #expect(try TextTransform.timestamp.apply("2023-11-14T22:13:20.500Z") == "1700000000\n1700000000500 ms")
        #expect(throws: TransformError.self) { try TextTransform.timestamp.apply("yesterday") }
    }

    @Test func jwtErrorsAndMetadata() throws {
        #expect(throws: TransformError.self) { try TextTransform.jwtDecode.apply("not-a-jwt") }
        let decoded = try TextTransform.jwtDecode.apply("Bearer eyJhbGciOiJub25lIn0.eyJpYXQiOjB9")
        #expect(decoded.contains("Issued: 1970-01-01T00:00:00Z"))
        #expect(decoded.hasSuffix("Signature not verified."))
        let uuid = try TextTransform.uuid.apply("")
        #expect(UUID(uuidString: uuid) != nil)
        #expect(!TextTransform.uuid.needsInput)
        #expect(TextTransform.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty && $0.id == $0.rawValue })
        #expect(TransformError.invalid("x").errorDescription == "x")
    }

    @Test func wordSplitting() {
        #expect(TextTransform.words("someHTTPValue_with-mixed Words2go") == ["some", "HTTP", "Value", "with", "mixed", "Words2go"])
        #expect(TextTransform.words("") == [])
        #expect(TextTransform.words("ABC") == ["ABC"])
    }
}

@Suite struct ProcessParsingTests {
    @Test func psSkipsMalformedLinesAndKeepsSpaces() {
        let output = """
              1     0   0.0   1024 root /sbin/launchd
            garbage line
              2     1   1.5   2048 vitor /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper
            """
        let parsed = ProcessList.parse(output)
        #expect(parsed.map(\.pid) == [1, 2])
        #expect(parsed[1].name == "Google Chrome Helper")
        #expect(parsed[1].isApp)
        #expect(!parsed[0].isApp)
        #expect(parsed[0].appBundle == nil)
        #expect(parsed[0].id == 1)
    }

    @Test func lsofDedupesAndSkipsNonPorts() {
        let output = "p10\ncnode\nLme\nf1\nn*:8080\nf2\nn[::]:8080\nf3\nn*:*\np20\ncruby\nf4\nn127.0.0.1:3000\n\n"
        let parsed = PortKiller.parse(output)
        #expect(parsed.map(\.port) == [3000, 8080])
        #expect(parsed[1].address == "*")
        #expect(parsed[0].user == "")  // the user resets for each process
        #expect(parsed[1].id == "10:8080")
    }

    @Test func killingProcesses() async throws {
        let process = try ProcessRunnerHelper.sleeper()
        try ProcessKiller.kill(pid: process.processIdentifier)
        for _ in 0..<40 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!process.isRunning)
        #expect(throws: ProcessKillError.noSuchProcess(process.processIdentifier)) { try ProcessKiller.kill(pid: process.processIdentifier) }
        #expect(throws: ProcessKillError.notPermitted(1)) { try ProcessKiller.kill(pid: 1) }
        #expect(ProcessKillError.failed(1, 5).errorDescription?.contains("error 5") == true)
    }
}

enum ProcessRunnerHelper {
    static func sleeper() throws -> RunningProcess {
        try ProcessRunner.launch("/bin/sleep", ["30"], onLine: { _ in })
    }
}

@Suite struct NoteMetadataMoreTests {
    @Test func yamlListTagsAndEmptyFrontMatter() {
        let list = NoteMetadata.parse("---\ntitle: Deploy\ntags:\n  - Ops\n  - \"#k8s\"\npinned: yes\n---\nBody")
        #expect(list.tags == ["ops", "k8s"])
        #expect(list.pinned)
        #expect(list.body == "Body")
        let empty = NoteMetadata.parse("---\n---\n# Title\nText")
        #expect(empty.body == "# Title\nText")
        // A rule that isn't front matter stays in the body.
        #expect(NoteMetadata.parse("---\nNot front matter").body == "---\nNot front matter")
        // "----" doesn't close the block.
        #expect(NoteMetadata.parse("---\ntags: [a]\n----\nstill header\n---\nbody").body == "body")
    }

    @Test func updatingRewritesListTagsCleanly() {
        let text = "---\ntitle: T\ntags:\n  - old\n  - stale\n---\n# T\nUses #inline"
        let updated = NoteMetadata.updating(text, tags: ["new", "inline"], pinned: false)
        #expect(updated == "---\ntitle: T\ntags: [new]\n---\n\n# T\nUses #inline\n")
        #expect(NoteMetadata.parse(updated).tags == ["new", "inline"])
        // Removing every front matter key drops the block entirely.
        #expect(NoteMetadata.updating("---\ntags: [a]\n---\nBody", tags: []) == "Body\n")
    }

    @Test func codeAndTags() {
        let text = "Intro #Idea and `#notatag` and https://x.test/#frag\n```\n#nope\n```\n#Done/sub"
        let metadata = NoteMetadata.parse(text)
        #expect(metadata.tags == ["idea", "done/sub"])
        #expect(metadata.codeBlocks == [NoteMetadata.CodeBlock(language: nil, code: "#nope")])
        // One code block and a single prose line (the "#Done/sub" tag line reads as a heading): a snippet.
        #expect(metadata.snippet == "#nope")
        #expect(NoteMetadata.parse("> brew services restart postgresql").snippet == "brew services restart postgresql")
    }
}

@Suite struct MarkdownTokenizerMoreTests {
    @Test func lineKinds() {
        func kinds(_ line: String) -> [MarkdownTokenizer.Kind] { MarkdownTokenizer.tokenize(line).map(\.kind) }
        #expect(kinds("### H3") == [.heading(3)])
        #expect(kinds("#nospace") == [])
        #expect(kinds("####### seven") == [])
        #expect(kinds("***") == [.rule])
        #expect(kinds("> quote") == [.blockquote])
        #expect(kinds("12. item") == [.listMarker])
        #expect(kinds("* [X] done") == [.listMarker, .taskDone, .taskDone])
        #expect(kinds("- [ ] todo") == [.listMarker, .taskOpen])
        #expect(kinds("see [docs](https://x.test) or https://y.test") == [.link, .link])
        #expect(kinds("an *italic* word") == [.italic])
        #expect(kinds("`**not bold**`") == [.inlineCode])
    }

    @Test func rangesAreUTF16() throws {
        let tokens = MarkdownTokenizer.tokenize("🦎 `code`")
        let code = try #require(tokens.first { $0.kind == .inlineCode })
        #expect(code.range == NSRange(location: 3, length: 6))
    }

    @Test func fencesAndPartialRetokenizing() {
        let text = "a\n```\ncode\n```\nb **bold**\n"
        #expect(MarkdownTokenizer.fenceState(text, upTo: 6))
        #expect(!MarkdownTokenizer.fenceState(text, upTo: 15))
        let ns = text as NSString
        let codeLine = ns.range(of: "code")
        #expect(MarkdownTokenizer.tokenize(text, in: codeLine, startsInFence: true).map(\.kind) == [.codeBlock])
        let boldLine = ns.range(of: "b **bold**")
        #expect(MarkdownTokenizer.tokenize(text, in: boldLine, startsInFence: false).map(\.kind) == [.bold])
    }
}

@Suite struct NotesStoreMoreTests {
    @Test func createRenameSearchDelete() async throws {
        let root = try tempDirectory("notes")
        let store = NotesStore(root: root)
        let first = try await store.create(title: "  ")
        #expect(first.lastPathComponent == "Untitled.md")
        let second = try await store.create(title: "")
        #expect(second.lastPathComponent == "Untitled-2.md")
        try await store.save("# Kubernetes\n\nRestart the pods with kubectl.", to: first)
        let renamed = try await store.rename(first, to: "K8s: Restart?")
        #expect(renamed.lastPathComponent == "K8s Restart.md")
        #expect(try await store.rename(renamed, to: "K8s Restart") == renamed)
        let hits = await store.search("KUBECTL pods")
        #expect(hits.map(\.title) == ["Kubernetes"])
        #expect(hits.first?.preview == "Restart the pods with kubectl.")
        #expect(await store.search("").count == 2)
        try await store.setPinned(true, for: second)
        #expect(await store.list().first?.url.lastPathComponent == second.lastPathComponent)
        try await store.delete(renamed)
        #expect(await store.list().count == 1)
    }

    @Test func foldersStayInsideTheRoot() async throws {
        let parent = try tempDirectory("roots")
        let store = NotesStore(root: parent.appending(path: "Notes"))
        // A sibling folder whose name starts with the root's name isn't a subfolder.
        #expect(await store.folder(of: parent.appending(path: "NotesArchive/a.md")) == "")
        #expect(await store.folder(of: parent.appending(path: "Notes/a.md")) == "")
        #expect(await store.folder(of: parent.appending(path: "Notes/Work/Infra/a.md")) == "Work/Infra")
        let folder = try await store.createFolder("Infra!", in: "Work")
        #expect(folder == "Work/Infra")
        let note = try await store.create(title: "Plan", folder: folder)
        let renamedFolder = try await store.renameFolder(folder, to: "Platform")
        #expect(renamedFolder == "Work/Platform")
        #expect(await store.folders() == ["Work", "Work/Platform"])
        let moved = parent.appending(path: "Notes/Work/Platform/\(note.lastPathComponent)")
        let back = try await store.move(moved, toFolder: "")
        #expect(await store.folder(of: back) == "")
        let other = try await store.create(title: "Plan", folder: "Work")
        let clash = try await store.move(other, toFolder: "")
        #expect(clash.lastPathComponent == "Plan-2.md")
        #expect(try await store.move(clash, toFolder: "") == clash)
        try await store.deleteFolder("Work")
        try await store.deleteFolder("")  // the root is never deleted
        #expect(await store.folders().isEmpty)
    }

    @Test func titlesPreviewsAndSlugs() {
        let url = URL(filePath: "/tmp/fallback.md")
        #expect(NotesStore.title(of: "\n\n# Real\nbody", fallback: url) == "Real")
        #expect(NotesStore.title(of: "no heading", fallback: url) == "fallback")
        #expect(NotesStore.preview(of: "# H\n\n  first line  \nsecond") == "first line")
        #expect(NotesStore.slug("///") == "Untitled")
        #expect(NotesStore.slug(String(repeating: "a", count: 200)).count == 80)
    }

    @Test func changeStreamFiresOnNewFiles() async throws {
        let root = try tempDirectory("watch")
        let store = NotesStore(root: root)
        let stream = await store.changes()
        let received = Task {
            for await _ in stream { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await store.create(title: "New")
        let fired = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await received.value }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            received.cancel()
            return first
        }
        #expect(fired)
    }
}

@Suite struct WorkLogMoreTests {
    @Test func parsesLines() throws {
        let entry = try #require(WorkLogStore.parse(line: "  - 2026-10-10T14:03:05Z [Xcode] Fixed [the] bug  "))
        #expect(entry.app == "Xcode")
        #expect(entry.text == "Fixed [the] bug")
        #expect(entry.date == ISO8601DateFormatter().date(from: "2026-10-10T14:03:05Z"))
        #expect(WorkLogStore.parse(line: "- 2026-10-10T14:03:05Z plain")?.app == nil)
        #expect(WorkLogStore.parse(line: "# Work Log: October 2026") == nil)
        #expect(WorkLogStore.parse(line: "- not-a-date text") == nil)
        #expect(WorkLogStore.parse(line: "- 2026-10-10T14:03:05Z") == nil)
    }

    @Test func rangesSpanMonthsAndDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = WorkLogStore(root: try tempDirectory("worklog"), calendar: calendar)
        let base = Date(timeIntervalSince1970: 1_759_276_800)  // 2025-10-01 00:00 UTC
        try store.append(text: "september", app: nil, date: base.addingTimeInterval(-3_600))
        try store.append(text: "multi\nline", app: "Notes", date: base.addingTimeInterval(3_600))
        try store.append(text: "next day", app: nil, date: base.addingTimeInterval(90_000))
        let all = store.entries(from: base.addingTimeInterval(-86_400), to: base.addingTimeInterval(172_800))
        #expect(all.map(\.text) == ["september", "multi line", "next day"])
        #expect(store.entries(onDayOf: base.addingTimeInterval(7_200)).map(\.text) == ["multi line"])
        #expect(store.file(for: base).lastPathComponent == "2025-10.md")
        #expect(WorkLogStore.text(of: []).isEmpty)
        #expect(WorkLogStore.text(of: all, limit: 10_000) == WorkLogStore.text(of: all))
    }
}

@Suite struct ClipboardMoreTests {
    private func makeStore(maxItems: Int = 100, maxAge: TimeInterval = 3_600) throws -> (ClipboardStore, URL) {
        let directory = try tempDirectory("clip")
        let store = try ClipboardStore(
            databaseURL: directory.appending(path: "db.sqlite"), imagesDirectory: directory.appending(path: "images"),
            retention: .init(maxItems: maxItems, maxAge: maxAge))
        return (store, directory)
    }

    @Test func pinnedItemsSurvivePruningAndClear() async throws {
        let (store, _) = try makeStore(maxItems: 2)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let keep = try await store.insert(kind: .url, text: "https://keep.test", sourceApp: "com.apple.Safari", date: now)
        try await store.setPinned(keep, true)
        for index in 0..<4 { try await store.insert(kind: .text, text: "n\(index)", sourceApp: nil, date: now.addingTimeInterval(Double(index + 1))) }
        let recent = try await store.recent()
        #expect(recent.first?.id == keep)
        #expect(recent.first?.pinned == true)
        #expect(recent.first?.kind == .url)
        #expect(recent.map(\.text) == ["https://keep.test", "n3", "n2"])
        try await store.clear()
        #expect(try await store.recent().map(\.id) == [keep])
        try await store.clear(keepPinned: false)
        #expect(try await store.count() == 0)
    }

    @Test func expiresByAgeAndDeletesImages() async throws {
        let (store, directory) = try makeStore(maxAge: 60)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let image = try await store.insertImage(png: Data([0x89, 0x50]), description: "Screenshot", sourceApp: nil, date: now)
        let item = try #require(try await store.recent().first)
        let path = try #require(item.imagePath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(item.byteSize == 2)
        try await store.insert(kind: .text, text: "old", sourceApp: nil, date: now.addingTimeInterval(-600))
        try await store.prune(now: now)
        #expect(try await store.recent().map(\.text) == ["Screenshot"])
        try await store.delete(image)
        #expect(!FileManager.default.fileExists(atPath: path))
        try await store.prune(now: now.addingTimeInterval(1_000))
        #expect(try await store.count() == 0)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "images").path))
    }

    @Test func searchHandlesQuotesAndPrefixes() async throws {
        let (store, _) = try makeStore()
        try await store.insert(kind: .text, text: "say \"hello\" to kubernetes", sourceApp: nil)
        try await store.insert(kind: .text, text: "Café crème", sourceApp: nil)
        #expect(try await store.search("kube").count == 1)
        #expect(try await store.search("\"hello").count == 1)
        #expect(try await store.search("cafe").count == 1)  // diacritics folded
        #expect(try await store.search("   ").count == 2)
        #expect(ClipboardStore.hash(kind: .text, text: "a", data: nil) != ClipboardStore.hash(kind: .url, text: "a", data: nil))
    }

    @Test func filterEdgeCases() {
        #expect(!PasteboardFilter.shouldStore(types: [], sourceApp: nil))
        #expect(PasteboardFilter.shouldStore(types: ["public.png"], sourceApp: "com.1password.1password", ignoredApps: []))
        #expect(!PasteboardFilter.shouldStore(types: ["public.utf8-plain-text"], sourceApp: "com.custom.vault", ignoredApps: ["com.custom.vault"]))
        #expect(ClipboardError.sqlite("x").errorDescription == "Clipboard history database: x")
    }
}

@Suite struct KnowledgeHelperTests {
    private func hit(_ text: String, score: Double, title: String = "T") -> KnowledgeHit {
        KnowledgeHit(documentKey: "note:\(text)", source: .note, title: title, location: nil, modified: Date(timeIntervalSince1970: 0), ordinal: 0,
                     text: text, heading: nil, score: score, similarity: score)
    }

    @Test func budgetsAndSelection() {
        #expect(AskNotes.contextBudget(promptTokens: 500) == 2_000)
        #expect(AskNotes.contextBudget(promptTokens: 4_000) == 8_400)
        #expect(AskNotes.contextBudget(promptTokens: 200_000) == 24_000)
        let hits = [hit(String(repeating: "a", count: 100), score: 3), hit(String(repeating: "b", count: 100), score: 2)]
        #expect(AskNotes.select(hits, budget: 150).count == 1)
        #expect(AskNotes.select(hits, budget: 10).count == 1)  // always at least one passage
        #expect(AskNotes.select(hits, budget: 1_000).count == 2)
        #expect(AskNotes.relevant([hit("a", score: 0), hit("b", score: 0)]).count == 2)
    }

    @Test func citationVariants() {
        #expect(AskNotes.citations(in: "A [2]. B [1, 3][2] C [x] [0] [") == [2, 1, 3])
        #expect(AskNotes.isOnlyCitations(" [1], [2]. "))
        #expect(!AskNotes.isOnlyCitations("Yes [1]"))
        let prompt = AskNotes.prompt(question: "Why?", sources: [hit("text", score: 1, title: "Doc")])
        #expect(prompt.contains("[1] Notes › Doc"))
        #expect(prompt.hasSuffix("Question: Why?"))
    }

    @Test func chunkingLongContent() {
        let longLine = String(repeating: "x", count: 2_500)
        let chunks = TextChunker.chunks(for: "# Logs\n" + longLine, targetCharacters: 1_000, overlap: 0)
        #expect(chunks.map(\.text.count) == [1_000, 1_000, 500])
        #expect(chunks.allSatisfy { $0.heading == "Logs" })
        #expect(chunks.map(\.ordinal) == [0, 1, 2])
        #expect(TextChunker.chunks(for: "   ").isEmpty)
        #expect(TextChunker.chunks(for: "# Short\nnote").first?.heading == "Short")
        #expect(TextChunker.split("a\nb\nc", size: 3) == ["a\nb", "c"])
        let fenced = "# Code\n" + String(repeating: "prose. ", count: 100) + "\n\n```\n# not a heading\n\nstill code\n```\n" + String(repeating: "more. ", count: 100)
        #expect(TextChunker.chunks(for: fenced, targetCharacters: 400).allSatisfy { $0.heading == "Code" })
    }

    @Test func vectorsSentencesAndDocuments() {
        #expect(VectorMath.normalized([3, 4], dimension: 2) == [0.6, 0.8])
        #expect(VectorMath.normalized([], dimension: 3) == [0, 0, 0])
        #expect(VectorMath.normalized([0, 0], dimension: 2) == [0, 0])
        let a: [Float] = [1, 2, 3]
        #expect(a.withUnsafeBufferPointer { VectorMath.dot($0, [1, 1]) } == 3)
        let sentences = KnowledgeIndex.sentences(in: "This first sentence is long enough. Short. And a second one that is long!\n```\nskip\n- list item here")
        #expect(sentences == ["This first sentence is long enough.", "Short. And a second one that is long!", "- list item here"])
        let document = KnowledgeDocument(id: "a.md", source: .note, title: "A", text: "x", modified: .now)
        #expect(document.key == "note:a.md")
        #expect(document.contentHash.count == 32)
        #expect(document.contentHash != KnowledgeDocument(id: "a.md", source: .note, title: "A", text: "y", modified: .now).contentHash)
        #expect(KnowledgeSource.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty && $0.id == $0.rawValue })
    }
}

@Suite struct ScreenshotMoreTests {
    private func capture(_ directory: URL) throws -> URL {
        let file = directory.appending(path: "\(UUID()).png")
        try Data([0x89]).write(to: file)
        return file
    }

    @Test func sameSecondCapturesDontOverwriteEachOther() async throws {
        let root = try tempDirectory("shots")
        let library = ScreenshotLibrary(root: root, indexURL: root.appending(path: "index.json"))
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let label = ScreenshotLabel(category: .web, title: "Safari", tags: [])
        let first = try await library.add(captured: try capture(root), date: date, app: "Safari", bundleID: nil, label: label, text: "", size: .zero)
        let second = try await library.add(captured: try capture(root), date: date, app: "Safari", bundleID: nil, label: label, text: "", size: .zero)
        #expect(first.path != second.path)
        #expect(second.path.hasSuffix("Safari 2.png"))
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        // Re-filing under the same category is a no-op rather than an error.
        #expect(try await library.recategorize(first.id, to: .web)?.path == first.path)
        #expect(try await library.recategorize(UUID(), to: .web) == nil)
        #expect(await library.search("", category: .web).count == 2)
        #expect(await library.search("safari", category: .code).isEmpty)
        try await library.delete(first.id)
        #expect(await library.items.count == 1)
        // The index reloads, dropping entries whose files are gone.
        try FileManager.default.removeItem(atPath: second.path)
        #expect(await ScreenshotLibrary(root: root, indexURL: root.appending(path: "index.json")).items.isEmpty)
    }

    @Test func destinationsAreSanitised() async throws {
        let root = try tempDirectory("dest")
        let library = ScreenshotLibrary(root: root, indexURL: root.appending(path: "index.json"))
        let url = await library.destination(for: .receipt, title: "a/b:c?" + String(repeating: "z", count: 100), date: Date(timeIntervalSince1970: 0))
        #expect(url.deletingLastPathComponent().lastPathComponent.count == 7)  // yyyy-MM
        #expect(url.path.contains("/Receipts/"))
        #expect(!url.lastPathComponent.contains("/") && !url.lastPathComponent.contains(":"))
        #expect(await library.destination(for: .other, title: "", date: .now).lastPathComponent.hasSuffix(".png"))
    }

    @Test(arguments: [
        ("", "Terminal", "com.apple.Terminal", ScreenshotCategory.terminal),
        ("frame", "Figma", "com.figma.Desktop", .design),
        ("standup", "Zoom", "us.zoom.xos", .meeting),
        ("Subtotal 12.00 VAT", "Preview", "com.apple.Preview", .receipt),
        ("Welcome to the site", "Arc", "company.thebrowser.browser.arc", .web),
        (String(repeating: "word ", count: 200), "Finder", "com.apple.finder", .document),
        ("some medium length text here", "Finder", "com.apple.finder", .other),
    ] as [(String, String, String, ScreenshotCategory)])
    func heuristicCategories(text: String, app: String, bundle: String, category: ScreenshotCategory) {
        let label = ScreenshotLabel.heuristic(text: text, app: app, bundleID: bundle)
        #expect(label.category == category)
        #expect(label.tags == [app.lowercased()])
        #expect(label.title.count <= 48)
        #expect(!category.title.isEmpty && !category.symbol.isEmpty)
    }
}

@Suite struct QuicklinkMergeTests {
    @Test func skipsSameNameAndSameURLAndReportsOnlyNewOnes() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ql-\(UUID()).json")
        let store = QuicklinkStore(url: url)
        let before = await store.links.count
        let first = await store.merge([Quicklink(name: "Search Google", template: "https://google.com/search?q={query}"),
                                       Quicklink(name: "Calendly", template: "https://calendly.com/me")])
        #expect(first == 1)  // "Search Google" is already a built-in
        let again = await store.merge([Quicklink(name: "calendly", template: "https://calendly.com/other")])
        #expect(again == 0)
        #expect(await store.links.count == before + 1)
    }
}
