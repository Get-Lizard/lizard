import Clipboard
import DevTools
import ExtensionHost
import Foundation
import Notes
import Screenshots
import Search
import Testing

@Suite struct SearchTests {
    @Test func acronymMatchesWordStarts() throws {
        let match = try #require(FuzzyMatcher.match("vsc", in: "Visual Studio Code"))
        #expect(match.indices == [0, 7, 14])
    }

    @Test func prefixBeatsScattered() throws {
        let prefix = try #require(FuzzyMatcher.match("term", in: "Terminal"))
        let scattered = try #require(FuzzyMatcher.match("term", in: "Steam Remote"))
        #expect(prefix.score > scattered.score)
    }

    @Test func noMatchWhenLettersMissing() {
        #expect(FuzzyMatcher.match("xyz", in: "Safari") == nil)
    }

    @Test func rankingIsFastForTwoThousandItems() {
        let candidates = (0..<2000).map { SearchCandidate(id: "\($0)", title: "Application Number \($0)") }
        let start = Date()
        _ = SearchEngine.rank(candidates, query: "apn", frecency: { _ in 0 })
        #expect(Date().timeIntervalSince(start) < 0.05)
    }

    @Test func quicklinkEncodesWebQueries() {
        let link = Quicklink(name: "GitHub", template: "https://github.com/search?q={query}")
        #expect(link.resolve(query: "a&b c")?.absoluteString == "https://github.com/search?q=a%26b%20c")
    }

    @Test func quicklinkKeepsPathsRaw() {
        let link = Quicklink(name: "Code", template: "vscode://file/{query}")
        #expect(link.resolve(query: "/tmp/a.swift")?.absoluteString == "vscode://file//tmp/a.swift")
    }

    @Test func frecencyDecays() {
        let url = FileManager.default.temporaryDirectory.appending(path: "frecency-\(UUID()).json")
        let frecency = Frecency(url: url)
        let then = Date(timeIntervalSince1970: 1_000_000)
        frecency.record("a", now: then)
        #expect(abs(frecency.boost(for: "a", now: then.addingTimeInterval(Frecency.halfLife)) - 0.5) < 0.001)
    }
}

@Suite struct NotesTests {
    @Test func workLogRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "worklog-\(UUID())")
        let store = WorkLogStore(root: root)
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try store.append(text: "Fixed the flaky test", app: "Xcode", date: date)
        try store.append(text: "Reviewed PR", app: nil, date: date.addingTimeInterval(60))
        let entries = store.entries(inMonthOf: date)
        #expect(entries.count == 2)
        #expect(entries[0].app == "Xcode")
        #expect(entries[0].text == "Fixed the flaky test")
        #expect(Int(entries[0].date.timeIntervalSince1970) == 1_760_000_000)
    }

    @Test func workLogBackdatedEntryKeepsTimeOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "worklog-\(UUID())")
        let store = WorkLogStore(root: root)
        let morning = Date(timeIntervalSince1970: 1_760_000_000)
        try store.append(text: "first", app: nil, date: morning)
        try store.append(text: "third", app: nil, date: morning.addingTimeInterval(7_200))
        try store.append(text: "second", app: nil, date: morning.addingTimeInterval(3_600))
        #expect(store.entries(inMonthOf: morning).map(\.text) == ["first", "second", "third"])
        let raw = try String(contentsOf: store.file(for: morning), encoding: .utf8)
        #expect(raw.hasPrefix("# Work Log: "))
        #expect(raw.hasSuffix("third\n"))
    }

    @Test func workLogTextFitsLongPeriods() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let entries = (0..<2_000).map { WorkLogEntry(date: start.addingTimeInterval(Double($0) * 3_600), app: "Xcode", text: "Entry \($0) " + String(repeating: "x", count: 40)) }
        let text = WorkLogStore.text(of: entries, limit: 20_000)
        #expect(text.count <= 20_100)
        #expect(text.contains("Entry 0 "))
        #expect(text.hasPrefix("(2000 entries"))
    }

    @Test func tokenizerFindsHeadingsCodeAndFences() {
        let text = "# Title\nsome `code` and **bold**\n```swift\nlet x = 1\n```\n- [x] done\n"
        let kinds = MarkdownTokenizer.tokenize(text).map(\.kind)
        #expect(kinds.contains(.heading(1)))
        #expect(kinds.contains(.inlineCode))
        #expect(kinds.contains(.bold))
        #expect(kinds.contains(.codeBlock))
        #expect(kinds.contains(.taskDone))
    }

    @Test func slugs() {
        #expect(NotesStore.slug("Hello / World: Notes!") == "Hello World Notes")
    }
}

@Suite struct ClipboardTests {
    @Test func skipsPasswordManagerCopies() {
        #expect(!PasteboardFilter.shouldStore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceApp: nil))
        #expect(!PasteboardFilter.shouldStore(types: ["public.utf8-plain-text"], sourceApp: "com.1password.1password"))
        #expect(PasteboardFilter.shouldStore(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Safari"))
    }

    @Test func storeDedupesSearchesAndPrunes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ClipboardStore(databaseURL: dir.appending(path: "db.sqlite"), imagesDirectory: dir, retention: .init(maxItems: 3))
        let first = try await store.insert(kind: .text, text: "hello world", sourceApp: nil)
        let again = try await store.insert(kind: .text, text: "hello world", sourceApp: nil)
        #expect(first == again)
        for index in 0..<5 { try await store.insert(kind: .text, text: "item \(index)", sourceApp: nil) }
        #expect(try await store.count() == 3)
        #expect(try await store.search("item 4").first?.text == "item 4")
    }
}

@Suite struct DevToolsTests {
    @Test func json() throws {
        #expect(try TextTransform.jsonMinify.apply("{ \"a\" : 1 }") == "{\"a\":1}")
        #expect(throws: TransformError.self) { try TextTransform.jsonPretty.apply("{nope") }
    }

    @Test func jwt() throws {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMiLCJleHAiOjE3MDAwMDAwMDB9.sig"
        let decoded = try TextTransform.jwtDecode.apply(token)
        #expect(decoded.contains("\"sub\" : \"123\""))
        #expect(decoded.contains("Expires: 2023-11-14"))
    }

    @Test func cases() throws {
        #expect(try TextTransform.snakeCase.apply("someHTTPValue") == "some_http_value")
        #expect(try TextTransform.camelCase.apply("hello_big world") == "helloBigWorld")
    }

    @Test func base64AndTimestamp() throws {
        #expect(try TextTransform.base64Decode.apply(TextTransform.base64Encode.apply("lizard")) == "lizard")
        #expect(try TextTransform.timestamp.apply("1700000000000").hasPrefix("2023-11-14T22:13:20Z"))
    }

    @Test func lsofParser() {
        let output = "p123\ncnode\nLvitor\nf21\nn*:3000\nf22\nn127.0.0.1:9229\np456\ncpostgres\nLvitor\nf5\nn[::1]:5432\n"
        let parsed = PortKiller.parse(output)
        #expect(parsed.map(\.port) == [3000, 5432, 9229])
        #expect(parsed.first?.command == "node")
    }

    @Test func psParser() {
        let parsed = ProcessList.parse("  101     1  12.5  20480 vitor /Applications/Xcode.app/Contents/MacOS/Xcode\n")
        #expect(parsed.first?.name == "Xcode")
        #expect(parsed.first?.memoryBytes == Int64(20480 * 1024))
        #expect(parsed.first?.appBundle == "/Applications/Xcode.app")
    }
}

@Suite struct ExtensionHostTests {
    @Test func manifestIntervalsAndDefaults() throws {
        let json = """
            {"name":"x","title":"X","commands":[{"name":"m","title":"M","mode":"menu-bar","interval":"5m"}],
             "preferences":[{"name":"flag","type":"checkbox","title":"F"},{"name":"host","type":"textfield","title":"H","default":"github.com"}]}
            """
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        #expect(manifest.commands[0].mode == .menuBar)
        #expect(manifest.commands[0].intervalSeconds == 300)
        let defaults = manifest.defaultPreferences(for: manifest.commands[0])
        #expect(defaults["flag"] == .bool(false))
        #expect(defaults["host"] == .string("github.com"))
    }

    @Test func viewTreeDecodesSlotsAndCallbacks() throws {
        let json = """
            [{"id":1,"type":"List","props":{},"children":[{"id":2,"type":"List.Item","props":{"title":"A"},"children":[
              {"id":3,"type":"slot:actions","props":{},"children":[{"id":4,"type":"ActionPanel","props":{},"children":[
                {"id":5,"type":"Action","props":{"title":"Go","onAction":{"$callback":"5.onAction"}},"children":[]}]}]}]}]}]
            """
        let tree = try JSONDecoder().decode([ViewNode].self, from: Data(json.utf8))
        let item = try #require(tree.first?.first("List.Item"))
        let actions = try #require(item.slot("actions")).flattenedActions
        #expect(actions.first?.callback("onAction") == "5.onAction")
    }

    @Test func splitsLines() {
        var buffer = Data("{\"a\":1}\n{\"b\"".utf8)
        #expect(ExtensionRuntime.splitLines(&buffer).count == 1)
        #expect(String(decoding: buffer, as: UTF8.self) == "{\"b\"")
    }
}

@Suite struct CalculatorTests {
    @Test func arithmetic() {
        #expect(Calculator.evaluate("2+3*4")?.value == 14)
        #expect(Calculator.evaluate("(2+3)*4")?.value == 20)
        #expect(Calculator.evaluate("2^10")?.value == 1024)
        #expect(Calculator.evaluate("-3 + 5")?.value == 2)
        #expect(Calculator.evaluate("1,234 * 2")?.value == 2468)
        #expect(Calculator.evaluate("sqrt(16) + 2pi")!.value - (4 + 2 * .pi) < 1e-9)
    }

    @Test func percentages() {
        #expect(Calculator.evaluate("15% of 80")?.value == 12)
        #expect(Calculator.evaluate("200 + 10%")?.value == 220)
        #expect(Calculator.evaluate("50 - 20%")?.value == 40)
    }

    @Test func units() {
        #expect(abs(Calculator.evaluate("5 km in mi")!.value - 3.10686) < 0.0001)
        #expect(abs(Calculator.evaluate("100 f to c")!.value - 37.7778) < 0.001)
        #expect(Calculator.evaluate("2 gb in mb")?.value == 2000)
        #expect(Calculator.evaluate("5 km in kg") == nil)
    }

    @Test func ignoresNonMath() {
        #expect(Calculator.evaluate("safari") == nil)
        #expect(Calculator.evaluate("42") == nil)
        #expect(Calculator.evaluate("2 +") == nil)
        #expect(Calculator.evaluate("open (") == nil)
    }
}

@Suite struct ScreenshotTests {
    @Test func heuristicsFileByAppAndText() {
        #expect(ScreenshotLabel.heuristic(text: "TypeError: undefined is not a function", app: "Chrome", bundleID: "com.google.Chrome").category == .error)
        #expect(ScreenshotLabel.heuristic(text: "func main() {}", app: "Xcode", bundleID: "com.apple.dt.Xcode").category == .code)
        #expect(ScreenshotLabel.heuristic(text: "hey are you there", app: "Slack", bundleID: "com.tinyspeck.slackmacgap").category == .chat)
        #expect(ScreenshotLabel.heuristic(text: "", app: "Photos", bundleID: "com.apple.Photos").category == .photo)
    }

    @Test func filesIntoCategoryAndMonthFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "shots-\(UUID())")
        let library = ScreenshotLibrary(root: root, indexURL: root.appending(path: "index.json"))
        let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: temp)
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let item = try await library.add(
            captured: temp, date: date, app: "Xcode", bundleID: nil, label: ScreenshotLabel(category: .code, title: "Login view: crash", tags: ["ios"]),
            text: "fatal error in LoginView", size: CGSize(width: 10, height: 10))
        #expect(item.path.contains("/Code/2025-10/"))
        #expect(item.path.hasSuffix("Login view- crash.png"))
        #expect(await library.search("loginview").count == 1)
        let moved = try await library.recategorize(item.id, to: .error)
        #expect(moved?.path.contains("/Errors/") == true)
    }
}

@Suite struct NotesV2Tests {
    @Test func frontMatterAndInlineTags() {
        let text = "---\ntags: [deploy, \"k8s\"]\npinned: true\n---\n# Rollout\nUse #helm here.\n```sh\n# not a #tag\nkubectl rollout status\n```\n"
        let metadata = NoteMetadata.parse(text)
        #expect(metadata.tags == ["deploy", "k8s", "helm"])
        #expect(metadata.pinned)
        #expect(metadata.codeBlocks.first?.code == "# not a #tag\nkubectl rollout status")
    }

    @Test func snippetDetection() {
        #expect(NoteMetadata.parse("# Restart docker\n```sh\nsudo killall Docker\n```").snippet == "sudo killall Docker")
        #expect(NoteMetadata.parse("$ git reset --hard origin/main").snippet == "git reset --hard origin/main")
        #expect(NoteMetadata.parse("# Ideas\nA long paragraph about things.\nAnother line.\nMore.").snippet == nil)
    }

    @Test func updatingFrontMatterKeepsBody() {
        let updated = NoteMetadata.updating("# Title\nBody #inline", tags: ["inline", "work"], pinned: true)
        #expect(updated.hasPrefix("---\ntags: [work]\npinned: true\n---\n\n# Title"))
        let unpinned = NoteMetadata.updating(updated, pinned: false)
        #expect(!unpinned.contains("pinned"))
    }

    @Test func foldersAndMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID())")
        let store = NotesStore(root: root)
        let folder = try await store.createFolder("Work Stuff")
        let note = try await store.create(title: "Deploy", folder: folder)
        #expect(await store.folder(of: note) == "Work Stuff")
        let moved = try await store.move(note, toFolder: "Archive")
        #expect(await store.folder(of: moved) == "Archive")
        try await store.setTags(["ops"], for: moved)
        let listed = await store.list()
        #expect(listed.first?.tags == ["ops"])
        #expect(await store.folders().contains("Work Stuff"))
        #expect(await store.search("#ops").count == 1)
    }
}
