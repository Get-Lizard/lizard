@testable import ExtensionHost
import Foundation
import Testing

private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeJSON(_ object: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}

@Suite struct GitHubLocationTests {
    @Test(arguments: [
        ("owner/repo", "owner", "repo", "", nil),
        ("https://github.com/owner/repo.git", "owner", "repo", "", nil),
        ("github.com/owner/repo/tree/main/extensions/foo", "owner", "repo", "extensions/foo", "main"),
        ("https://www.github.com/owner/repo/blob/v2/src", "owner", "repo", "src", "v2"),
        ("owner/repo/sub/path@v1.2", "owner", "repo", "sub/path", "v1.2"),
        ("owner/repo@feature/x", "owner", "repo", "", "feature/x"),
        ("  owner/repo/  ", "owner", "repo", "", nil),
    ] as [(String, String, String, String, String?)])
    func parsesPastedLocations(input: String, owner: String, repo: String, path: String, ref: String?) throws {
        let location = try #require(GitHubLocation.parse(input))
        #expect(location.owner == owner)
        #expect(location.repo == repo)
        #expect(location.path == path)
        #expect(location.ref == ref)
    }

    @Test func bareNamesMeanTheRaycastCatalog() {
        #expect(GitHubLocation.parse("Google-Translate") == .raycastCatalog("google-translate"))
        #expect(GitHubLocation.parse("google-translate@main") == nil)
    }

    @Test(arguments: ["", "has space/repo", "owner/repo/../../etc", "..", "owner/./repo", "owner/repo@", "owner/repo@a..b", "owner/re$po"])
    func rejectsUnsafeOrInvalidInput(input: String) {
        #expect(GitHubLocation.parse(input) == nil)
    }

    @Test func displayAndWebURL() {
        let location = GitHubLocation(owner: "o", repo: "r", path: "/a/b/", ref: "dev")
        #expect(location.path == "a/b")
        #expect(location.display == "o/r/a/b@dev")
        #expect(location.webURL.absoluteString == "https://github.com/o/r/tree/dev/a/b")
        #expect(GitHubLocation(owner: "o", repo: "r").webURL.absoluteString == "https://github.com/o/r")
    }
}

@Suite struct ExtensionSourceTests {
    @Test(arguments: [
        ExtensionSource.github(GitHubLocation(owner: "o", repo: "r", path: "p", ref: nil), commit: "abcdef1234"),
        .folder(path: "/tmp/x"), .raycastImport(path: "/r"), .builtIn(path: "/b"),
    ])
    func roundTrips(source: ExtensionSource) throws {
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(ExtensionSource.self, from: data) == source)
    }

    @Test func legacyStoreRecordsDecodeAsGitHub() throws {
        let data = Data(#"{"store":{"name":"translate","commit":"123"}}"#.utf8)
        let source = try JSONDecoder().decode(ExtensionSource.self, from: data)
        #expect(source == .github(.raycastCatalog("translate"), commit: "123"))
        #expect(source.commit == "123")
        #expect(source.github?.path == "extensions/translate")
        #expect(source.description == "raycast/extensions/extensions/translate@main @ 123")
    }

    @Test func badgesAndDescriptions() {
        #expect(!ExtensionSource.builtIn(path: "/b").isExternal)
        #expect(ExtensionSource.folder(path: "/f").isExternal)
        #expect(ExtensionSource.folder(path: "/f").github == nil)
        #expect(ExtensionSource.raycastImport(path: "/r").description == "Imported from Raycast")
        #expect(ExtensionSource.builtIn(path: "/b").description == "Built in")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExtensionSource.self, from: Data("{}".utf8)) }
    }
}

@Suite struct ExtensionValidatorTests {
    @Test func scaffoldPassesValidation() throws {
        let parent = try tempDirectory("scaffold")
        let folder = try ExtensionValidator.scaffold(name: "my-ext", title: "My Ext", author: "me", in: parent)
        try Data([0x89]).write(to: folder.appending(path: "assets/icon.png"))
        let issues = ExtensionValidator.validate(folder)
        #expect(issues.filter { $0.level == .error }.isEmpty, "\(issues)")
        #expect(throws: ExtensionHostError.self) { try ExtensionValidator.scaffold(name: "my-ext", title: "X", author: "me", in: parent) }
    }

    @Test func reportsEveryProblem() throws {
        let folder = try tempDirectory("invalid")
        try writeJSON([
            "name": "Bad Name", "title": "", "scripts": ["postinstall": "rm -rf /"], "icon": "missing.png",
            "commands": [
                ["name": "dup", "title": "A", "mode": "view", "interval": "5m"],
                ["name": "dup", "title": "", "mode": "weird", "interval": "10x"],
                ["name": "fast", "title": "F", "mode": "menu-bar", "interval": "30s",
                 "preferences": [["name": "p", "type": "dropdown", "title": "P"]]],
            ],
            "preferences": [["name": "q", "type": "color"], ["name": "c", "type": "checkbox"]],
        ], to: folder.appending(path: "package.json"))
        let messages = ExtensionValidator.validate(folder).map(\.description)
        let expected = [
            "✗ \"name\" must be kebab-case", "✗ \"title\" is required", "✗ \"author\" is required", "✗ icon \"missing.png\" not found",
            "! add \"repository\"", "! install scripts are never run", "✗ command \"dup\": only menu-bar and no-view commands can have an interval",
            "✗ duplicate command \"dup\"", "✗ command \"dup\" needs a title", "✗ command \"dup\": mode must be", "✗ command \"dup\": interval like",
            "! command \"fast\": intervals under 1 minute", "✗ preference \"p\": dropdowns need data", "✗ preference \"q\": unknown type",
            "✗ preference \"q\": title is required", "✗ command \"fast\": missing src/fast.tsx", "! add a README.md",
        ]
        for prefix in expected {
            #expect(messages.contains { $0.hasPrefix(prefix) }, "missing: \(prefix)")
        }
        // Checkboxes don't need a title.
        #expect(!messages.contains { $0.contains("preference \"c\"") })
    }

    @Test func missingManifest() throws {
        let issues = ExtensionValidator.validate(try tempDirectory("empty"))
        #expect(issues.count == 1)
        #expect(issues.first?.level == .error)
    }
}

@Suite struct ManifestAndJSONTests {
    @Test(arguments: [("30s", 30.0), ("5m", 300), ("1h", 3600), ("2d", 172_800), ("1s", 10), ("5x", nil), ("m", nil), ("", nil)] as [(String, Double?)])
    func intervals(interval: String, seconds: Double?) {
        let command = ExtensionManifest.Command(
            name: "c", title: "C", subtitle: nil, description: nil, icon: nil, mode: .menuBar, interval: interval, disabledByDefault: nil,
            keywords: nil, preferences: nil, arguments: nil)
        #expect(command.intervalSeconds == seconds)
    }

    @Test func preferencesMergeExtensionAndCommand() throws {
        let json = """
            {"name":"x","title":"X","preferences":[{"name":"token","type":"password","title":"T","required":true}],
             "commands":[{"name":"a","title":"A","mode":"view","preferences":[{"name":"limit","type":"textfield","title":"L","default":10}]}]}
            """
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        #expect(manifest.allPreferences(for: manifest.commands[0]).map(\.name) == ["token", "limit"])
        #expect(manifest.allPreferences(for: nil).map(\.name) == ["token"])
        #expect(manifest.defaultPreferences(for: manifest.commands[0]) == ["limit": .number(10)])
    }

    @Test func hostJSONDecodingAndAccessors() throws {
        let value = try JSONDecoder().decode(HostJSON.self, from: Data(#"{"n":3,"f":1.5,"b":true,"s":"x","a":[null],"cb":{"$callback":"4.onAction"}}"#.utf8))
        #expect(value["n"] == .number(3))
        #expect(value["n"]?.string == "3")
        #expect(value["f"]?.string == "1.5")
        #expect(value["b"]?.string == "true")
        #expect(value["b"]?.bool == true)
        #expect(value["n"]?.number == 3)
        #expect(value["a"]?.array == [.null])
        #expect(value["a"]?.array?.first?.isNull == true)
        #expect(value["cb"]?.callbackID == "4.onAction")
        #expect(value["s"]?.object == nil)
        #expect(value.object?.count == 6)
        #expect(HostJSON.null.string == nil)
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(HostJSON.self, from: encoded) == value)
    }

    @Test func hostJSONNumberStringsNeverTrap() {
        #expect(HostJSON.number(1e300).string == "1e+300")
        #expect(HostJSON.number(.infinity).string == "inf")
        #expect(HostJSON.number(-7).string == "-7")
    }

    @Test func hostJSONFromFoundationKeepsNumbersAndBools() throws {
        // JSONSerialization hands back NSNumbers; 0 and 1 must stay numbers, not become booleans.
        let object = try JSONSerialization.jsonObject(with: Data(#"{"one":1,"zero":0,"yes":true,"pi":3.14,"list":[1,"a"],"nil":null}"#.utf8))
        let value = HostJSON(any: object)
        #expect(value["one"] == .number(1))
        #expect(value["zero"] == .number(0))
        #expect(value["yes"] == .bool(true))
        #expect(value["pi"] == .number(3.14))
        #expect(value["list"] == .array([.number(1), .string("a")]))
        #expect(value["nil"] == .null)
        #expect(HostJSON(any: 5) == .number(5))
        #expect(HostJSON(any: false) == .bool(false))
        #expect(HostJSON(any: Optional<Any>.none) == .null)
        #expect(HostJSON(any: Date(timeIntervalSince1970: 0)).string != nil)
        let back = try #require(value.anyValue as? [String: Any])
        #expect(back["one"] as? Double == 1)
    }

    @Test func viewNodeHelpers() throws {
        let json = """
            {"id":1,"type":"List","children":[
              {"id":2,"type":"List.Section","props":{"title":"S"},"children":[{"id":3,"type":"List.Item","props":{"title":"A","on":true}}]},
              {"id":4,"type":"slot:searchBarAccessory","children":[{"id":5,"type":"List.Dropdown"}]},
              {"id":6,"type":"ActionPanel","children":[
                {"id":7,"type":"ActionPanel.Section","children":[{"id":8,"type":"Action"},{"id":9,"type":"ActionPanel.Submenu"}]},
                {"id":10,"type":"Other"}]},
              {"id":11,"type":"Text","text":"hello"}]}
            """
        let node = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        #expect(node.children(ofType: "List.Section").count == 1)
        #expect(node.content.map(\.id) == [2, 6, 11])
        #expect(node.slot("searchBarAccessory")?.type == "List.Dropdown")
        #expect(node.slot("missing") == nil)
        let item = try #require(node.first("List.Item"))
        #expect(item.string("title") == "A")
        #expect(item.bool("on") == true)
        #expect(item["title"] == .string("A"))
        #expect(item.props.count == 2)
        #expect(node.first("Nope") == nil)
        #expect(node.first("ActionPanel")?.flattenedActions.map(\.id) == [8, 9])
        #expect(node.first("Text")?.text == "hello")
        let built = ViewNode(id: 1, type: "Detail", props: ["markdown": .string("# hi")])
        #expect(built.children.isEmpty && built.text == nil)
    }

    @Test func splitLinesKeepsPartialTail() {
        var buffer = Data("a\n\nb\nc".utf8)
        let lines = ExtensionRuntime.splitLines(&buffer)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "", "b"])
        #expect(String(decoding: buffer, as: UTF8.self) == "c")
    }

    @Test func errorMessagesArePlain() {
        #expect(ExtensionHostError.nodeMissing.errorDescription?.contains("Node.js") == true)
        #expect(ExtensionHostError.notInstalled("x").errorDescription?.contains("“x”") == true)
        #expect(GitHubAPI.encode("main:extensions/foo bar") == "main%3Aextensions%2Ffoo%20bar")
    }
}

@Suite struct ExtensionStoreTests {
    /// Writes an installed extension folder by hand (no Node/npm needed).
    private func install(_ name: String, in root: URL, preferences: [[String: Any]] = [], source: ExtensionSource? = nil) throws {
        let directory = root.appending(path: name)
        try writeJSON([
            "name": name, "title": name.uppercased(), "icon": "icon.png",
            "preferences": preferences,
            "commands": [["name": "main", "title": "Main", "mode": "view"]],
        ], to: directory.appending(path: "package/package.json"))
        try FileManager.default.createDirectory(at: directory.appending(path: "package/assets"), withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appending(path: "package/assets/icon.png"))
        if let source { try JSONEncoder().encode(source).write(to: directory.appending(path: "source.json")) }
    }

    @Test func listsLoadsAndUninstalls() async throws {
        let root = try tempDirectory("extensions")
        try install("beta", in: root, source: .builtIn(path: "/b"))
        try install("alpha", in: root)
        try FileManager.default.createDirectory(at: root.appending(path: "broken"), withIntermediateDirectories: true)
        let store = ExtensionStore(root: root)
        let installed = await store.installed()
        #expect(installed.map(\.name) == ["alpha", "beta"])
        #expect(installed[0].source.description.hasSuffix("/alpha/package"))  // no source.json: the folder itself
        #expect(installed[0].isExternal)
        #expect(!installed[1].isExternal)
        #expect(installed[0].iconURL?.lastPathComponent == "icon.png")
        #expect(installed[0].bundle(for: "main").lastPathComponent == "main.js")
        #expect(installed[0].commands.count == 1 && installed[0].title == "ALPHA")
        #expect(await store.extensionNamed("../alpha") == nil)
        try await store.uninstall("alpha")
        #expect(await store.extensionNamed("alpha") == nil)
        try await store.uninstall("alpha")  // already gone: no error
        await #expect(throws: ExtensionHostError.self) { try await store.uninstall("..") }
    }

    @Test func preferencesMergeAndRequiredChecks() async throws {
        let root = try tempDirectory("prefs")
        try install("gh", in: root, preferences: [
            ["name": "token", "type": "password", "title": "Token", "required": true],
            ["name": "host", "type": "textfield", "title": "Host", "default": "github.com"],
            ["name": "verbose", "type": "checkbox", "label": "Verbose"],
        ])
        let store = ExtensionStore(root: root)
        let item = try #require(await store.extensionNamed("gh"))
        let command = item.commands[0]
        #expect(await store.missingRequiredPreferences(for: item, command: command).map(\.name) == ["token"])
        try await store.setPreferences("gh", values: ["token": .string("abc"), "stray": .string("x"), "host": .string("ghe.local")])
        let values = await store.preferences(for: item, command: command)
        #expect(values["token"] == .string("abc"))
        #expect(values["host"] == .string("ghe.local"))
        #expect(values["verbose"] == .bool(false))
        #expect(values["stray"] == nil)  // not declared by the manifest
        #expect(await store.missingRequiredPreferences(for: item, command: command).isEmpty)
        try await store.setPreferences("gh", values: ["token": HostJSON?.none])
        #expect(await store.savedPreferences("gh")["token"] == nil)
        try await store.setPreferences("gh", values: ["token": .string("")])
        #expect(await store.missingRequiredPreferences(for: item, command: command).map(\.name) == ["token"])
    }

    @Test(arguments: [("google-translate", true), ("My_Ext.v2", true), ("..", false), (".", false), ("", false), ("../evil", false), ("a/b", false)])
    func extensionNamesMustStayInsideTheStore(name: String, safe: Bool) {
        #expect(ExtensionStore.isSafeName(name) == safe)
    }

    @Test func refusesManifestsThatEscapeTheStore() async throws {
        let root = try tempDirectory("escape")
        let store = ExtensionStore(root: root.appending(path: "Extensions"))
        let evil = root.appending(path: "evil")
        try writeJSON(["name": "../victim", "title": "Evil", "commands": []], to: evil.appending(path: "package.json"))
        await #expect(throws: ExtensionHostError.self) { try await store.install(evil.path) }
        await #expect(throws: ExtensionHostError.self) { try await store.importFromRaycast(evil) }
        try writeJSON(["name": "ok", "title": "Evil", "commands": [["name": "../../x", "title": "X", "mode": "view"]]], to: evil.appending(path: "package.json"))
        await #expect(throws: ExtensionHostError.self) { try await store.importFromRaycast(evil) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "victim").path))
    }

    @Test func importsCompiledRaycastBundles() async throws {
        let root = try tempDirectory("raycast")
        let raycast = root.appending(path: "raycast-ext")
        try writeJSON(["name": "kill-process", "title": "Kill", "commands": [["name": "index", "title": "Kill", "mode": "view"]]],
                      to: raycast.appending(path: "package.json"))
        try Data("module.exports = {}".utf8).write(to: raycast.appending(path: "index.js"))
        let store = ExtensionStore(root: root.appending(path: "Extensions"))
        let item = try await store.importFromRaycast(raycast)
        #expect(item.source == .raycastImport(path: raycast.path))
        #expect(FileManager.default.fileExists(atPath: item.bundle(for: "index").path))
    }

    @Test func invalidInstallRequestsExplainThemselves() async throws {
        let store = ExtensionStore(root: try tempDirectory("bad-request"))
        await #expect(throws: ExtensionHostError.self) { try await store.install("not a repo") }
        await #expect(throws: ExtensionHostError.self) { try await store.update("missing") }
        await #expect(throws: ExtensionHostError.self) { try await store.exportPackage("missing", to: FileManager.default.temporaryDirectory) }
    }
}
