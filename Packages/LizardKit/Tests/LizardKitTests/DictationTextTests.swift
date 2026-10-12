import Testing
@testable import AIEngine

@Suite struct DictationTextTests {
    @Test func volatileReplacedFinalKept() {
        var text = DictationText()
        text.update("Open", isFinal: false)
        text.update("Open the", isFinal: false)
        #expect(text.current == "Open the")
        text.update("Open the notes.", isFinal: true)
        text.update("And then", isFinal: false)
        #expect(text.current == "Open the notes. And then")
    }

    @Test func removesFillers() {
        #expect(DictationText.clean("Um, I think, uh, we should ship it") == "I think, we should ship it")
        #expect(DictationText.clean("so umm the build is green") == "so the build is green")
        #expect(DictationText.clean("Hummus and Umbria stay") == "Hummus and Umbria stay")
    }

    @Test func searchDropsFinalPeriod() {
        #expect(DictationText.forSearch("Open Safari.") == "Open Safari")
        #expect(DictationText.forSearch("15% of 80") == "15% of 80")
    }

    @Test func joinsOntoExistingText() {
        #expect(DictationText.insertion("Thanks a lot.", after: "Hi Ana,") == " thanks a lot.")
        #expect(DictationText.insertion("Thanks a lot.", after: "Done. ") == "Thanks a lot.")
        #expect(DictationText.insertion("Hello", after: "") == "Hello")
        #expect(DictationText.insertion("I agree", after: "ok") == " I agree")
    }
}
