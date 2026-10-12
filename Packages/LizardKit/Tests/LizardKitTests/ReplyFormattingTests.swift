import Testing
@testable import AIEngine

@Suite struct ReplyFormattingTests {
    let page = """
        ```html
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="UTF-8"><title>Weather in Portugal</title></head>
        <body>
            <h1>Weather in Portugal Today</h1>
            <p>Mostly sunny, 18&deg;C to 24&deg;C.</p>
        </body>
        </html>
        ```
        """

    @Test func plainQuestionGetsTextNotHTML() {
        let tidy = ReplyFormatting.tidy(page, question: "how is the weather in portugal today?")
        #expect(tidy == "### Weather in Portugal Today\n\nMostly sunny, 18°C to 24°C.")
        #expect(!tidy.contains("<"))
    }

    @Test func askingForCodeKeepsIt() {
        #expect(ReplyFormatting.tidy(page, question: "write an html page about the weather") == page)
    }

    @Test func ordinaryRepliesAreUntouched() {
        let reply = "Use `a < b` to compare. In HTML you'd write <b> for bold."
        #expect(ReplyFormatting.tidy(reply, question: "how do I compare numbers") == reply)
    }
}
