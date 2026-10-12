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

@Suite struct UnaskedCodeTests {
    let reply = """
        Donald Trump is a former U.S. president who served from 2017 to 2021.

        ```swift
        import Foundation

        func describeDonaldTrump() -> String {
            return "Donald Trump is a former U.S. president."
        }

        // E
        """

    @Test func plainQuestionDropsTackedOnCode() {
        #expect(ReplyFormatting.tidy(reply, question: "who is donald trump?") == "Donald Trump is a former U.S. president who served from 2017 to 2021.")
    }

    @Test func codeQuestionsKeepCode() {
        for question in ["write a swift function that describes a president", "how do I do this in bash", "regex for emails", "fix this error: nil found"] {
            #expect(ReplyFormatting.tidy(reply, question: question) == reply, "\(question)")
        }
    }

    @Test func codeOnlyRepliesStay() {
        let only = "```bash\nls -la\n```"
        #expect(ReplyFormatting.tidy(only, question: "list files") == only)
    }
}
