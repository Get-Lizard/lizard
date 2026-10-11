import Foundation
import Testing
@testable import Search

@Suite struct SnippetTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_791_540_000)  // 2026-10-09 10:00 UTC, a Friday

    @Test func fillsClipboardSelectionAndDates() {
        let result = Snippet.expand(
            "Hi {clipboard}, re: {selection} on {date format=\"yyyy-MM-dd\"} ({day})", clipboard: "Ana", selection: "PAY-412",
            now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(result.text == "Hi Ana, re: PAY-412 on 2026-10-09 (Friday)")
        #expect(result.cursorFromEnd == nil)
    }

    @Test func dateOffsets() {
        let result = Snippet.expand(#"{date format="yyyy-MM-dd" offset="+1w -1d"}"#, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(result.text == "2026-10-15")
    }

    @Test func cursorPositionIsCountedFromTheEnd() {
        let result = Snippet.expand("Dear {cursor},\nThanks!")
        #expect(result.text == "Dear ,\nThanks!")
        #expect(result.cursorFromEnd == 9)
    }

    @Test func unknownPlaceholdersAndBracesStay() {
        #expect(Snippet.expand("{argument name=\"x\"} and { json }").text == "{argument name=\"x\"} and { json }")
    }

    @Test func modifiersChainLikeRaycast() {
        #expect(Snippet.expand("{clipboard | trim | uppercase}", clipboard: "  hi there ").text == "HI THERE")
        #expect(Snippet.expand("q={clipboard | percent-encode}", clipboard: "a b&c").text == "q=a%20b%26c")
        #expect(Snippet.expand("{clipboard | json-stringify}", clipboard: #"say "hi""#).text == #""say \"hi\"""#)
        #expect(Snippet.expand("{clipboard | raw}", clipboard: "x").text == "x")
    }

    @Test func bareOffsetsAndTimeOffsets() {
        let result = Snippet.expand(#"{datetime format="yyyy-MM-dd HH:mm" offset=+1h}"#, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(result.text == "2026-10-09 11:00")
    }

    @Test func includesOtherSnippetsOneLevelDeep() {
        let signature = Snippet(name: "Signature", text: #"Vitor {snippet name="Signature"}"#)
        let result = Snippet.expand(#"Best, {snippet name="signature"}"#, snippets: [signature])
        #expect(result.text == #"Best, Vitor {snippet name="Signature"}"#)
    }

    @Test func clipboardOffsetReadsHistory() {
        let result = Snippet.expand("{clipboard} / {clipboard offset=1}", clipboard: "now") { $0 == 1 ? "before" : nil }
        #expect(result.text == "now / before")
    }

    @Test func uuidIsFresh() {
        let a = Snippet.expand("{uuid}").text, b = Snippet.expand("{uuid}").text
        #expect(a != b && UUID(uuidString: a) != nil)
    }

    @Test func raycastRoundTrip() throws {
        let data = Data(#"[{"name":"Sig","text":"Best,\nVitor","keyword":";sig"},{"name":"Quick","text":"q"},{"name":"Link","link":"https://x"}]"#.utf8)
        let snippets = Snippet.fromRaycastExport(data)
        #expect(snippets.map(\.name) == ["Sig", "Quick"])
        #expect(snippets.first?.keyword == ";sig")
        let again = Snippet.fromRaycastExport(try Snippet.raycastExport(snippets))
        #expect(again.map(\.text) == snippets.map(\.text))
    }

    @Test func keywordMatcherFiresOnCompletionLongestFirst() {
        var matcher = SnippetKeywordMatcher()
        let short = Snippet(name: "a", text: "A", keyword: ";s")
        let long = Snippet(name: "b", text: "B", keyword: ";sig")
        matcher.update([short, long])
        // Expansion is immediate, so a shorter keyword that's a prefix fires first (as in Raycast).
        #expect(matcher.typed("hello ;s")?.id == short.id)
        var fresh = SnippetKeywordMatcher()
        fresh.update([long])
        #expect(fresh.typed("x;si") == nil)
        #expect(fresh.typed("g")?.id == long.id)
        #expect(fresh.typed("g") == nil)  // buffer cleared after a match
        fresh.update([long])
        _ = fresh.typed(";sx")
        fresh.deleteBackward()
        #expect(fresh.typed("ig")?.keyword == ";sig")
    }

    @Test func storeMergeSkipsSameNameOrKeyword() async {
        let store = SnippetStore(url: FileManager.default.temporaryDirectory.appending(path: "sn-\(UUID()).json"))
        #expect(await store.merge([Snippet(name: "Sig", text: "1", keyword: ";sig")]) == 1)
        #expect(await store.merge([Snippet(name: "sig", text: "2"), Snippet(name: "Other", text: "3", keyword: ";sig"), Snippet(name: "New", text: "4")]) == 1)
        #expect(await store.snippets.count == 2)
    }
}
