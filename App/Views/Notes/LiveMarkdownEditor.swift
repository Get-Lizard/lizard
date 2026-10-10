import AppKit
import Notes
import SwiftUI

extension NSAttributedString.Key {
    /// Marks every character of one fenced code block (value: the block's index) — drawn as one panel.
    static let lizardCodeBlock = NSAttributedString.Key("lizardCodeBlock")
    /// Marks block-quote lines — drawn with a bar on the left.
    static let lizardQuote = NSAttributedString.Key("lizardQuote")
}

/// Live Markdown editing: the text stays plain Markdown on disk, but looks formatted while you
/// type — code blocks as rounded panels with a copy button, real headings, bold/italic, quotes,
/// and list/fence auto-completion. TextKit 1 so the layout manager can draw block backgrounds.
struct LiveMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onCopy: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 22, height: 18)
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(Brand.moss)
        textView.typingAttributes = MarkdownStyler.base
        textView.coordinator = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = textView

        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.restyle()
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged), name: NSView.frameDidChangeNotification, object: textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        context.coordinator.restyle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownEditor
        weak var textView: NSTextView?
        private var copyButtons: [NSButton] = []
        private var blocks: [(range: NSRange, code: String)] = []

        init(_ parent: LiveMarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // Don't touch attributes mid-composition (´ ~ ^ dead keys, Japanese/Chinese input).
            if textView.hasMarkedText() { return }
            restyle()
        }

        @objc func frameChanged() { placeCopyButtons() }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRanges
            blocks = MarkdownStyler.style(storage)
            textView.selectedRanges = selection
            textView.typingAttributes = MarkdownStyler.base
            DispatchQueue.main.async { self.placeCopyButtons() }
        }

        /// One small copy button at the top-right of every code block.
        private func placeCopyButtons() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            while copyButtons.count < blocks.count {
                let button = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self, action: #selector(copyBlock(_:)))
                button.isBordered = false
                button.contentTintColor = .secondaryLabelColor
                button.toolTip = "Copy code"
                textView.addSubview(button)
                copyButtons.append(button)
            }
            for (index, button) in copyButtons.enumerated() {
                guard index < blocks.count else { button.isHidden = true; continue }
                let glyphs = layoutManager.glyphRange(forCharacterRange: blocks[index].range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                let width = container.size.width
                button.frame = NSRect(x: textView.textContainerOrigin.x + width - 26, y: textView.textContainerOrigin.y + rect.minY + 3, width: 20, height: 18)
                button.tag = index
                button.isHidden = false
            }
        }

        @objc private func copyBlock(_ sender: NSButton) {
            guard sender.tag < blocks.count else { return }
            parent.onCopy(blocks[sender.tag].code)
            sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            sender.contentTintColor = NSColor(Brand.moss)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
                sender.contentTintColor = .secondaryLabelColor
            }
        }

        // MARK: Typing helpers

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return MarkdownTyping.newline(in: textView)
            case #selector(NSResponder.insertTab(_:)): return MarkdownTyping.indent(in: textView, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)): return MarkdownTyping.indent(in: textView, outdent: true)
            default: return false
            }
        }
    }
}

final class MarkdownTextView: NSTextView {
    weak var coordinator: LiveMarkdownEditor.Coordinator?
}

/// Draws code blocks as rounded panels spanning the text width, and a bar beside quotes.
final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var drawn = Set<Int>()
        storage.enumerateAttribute(.lizardCodeBlock, in: characters) { value, _, _ in
            guard let block = value as? Int, drawn.insert(block).inserted else { return }
            // The whole block, even when only part of it is on screen.
            var full = NSRange()
            _ = storage.attribute(.lizardCodeBlock, at: max(characters.location, 0), longestEffectiveRange: &full, in: NSRange(location: 0, length: storage.length))
            var blockRange = full
            storage.enumerateAttribute(.lizardCodeBlock, in: NSRange(location: 0, length: storage.length)) { other, range, _ in
                if (other as? Int) == block { blockRange = range }
            }
            let glyphs = glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x = 0
            rect.size.width = container.size.width
            rect = rect.insetBy(dx: -8, dy: -4).offsetBy(dx: origin.x, dy: origin.y)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor(Brand.moss).withAlphaComponent(0.28).setStroke()
            path.lineWidth = 0.6
            path.stroke()
        }
        storage.enumerateAttribute(.lizardQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            NSColor(Brand.moss).withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x - 10, y: rect.minY + origin.y, width: 3, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// Applies the live styles to the whole document (notes are small; this takes ~1 ms).
@MainActor
enum MarkdownStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        return style
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "case", "switch",
        "const", "function", "def", "async", "await", "try", "catch", "throw", "public", "private", "static", "new", "in",
        "from", "export", "default", "true", "false", "nil", "null", "None", "self", "this", "sudo", "echo", "cd", "export",
    ]

    /// Styles `storage`; returns the code blocks (character range of the whole block, inner code).
    static func style(_ storage: NSTextStorage) -> [(range: NSRange, code: String)] {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        var blocks: [(range: NSRange, code: String)] = []
        var openFence: (start: Int, contentStart: Int)?
        var position = 0
        while position < text.length {
            let lineRange = text.lineRange(for: NSRange(location: position, length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                // Fence line: small, dim.
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor], range: lineRange)
                if let open = openFence {
                    let blockRange = NSRange(location: open.start, length: NSMaxRange(lineRange) - open.start)
                    let code = text.substring(with: NSRange(location: open.contentStart, length: lineRange.location - open.contentStart))
                    storage.addAttribute(.lizardCodeBlock, value: blocks.count, range: blockRange)
                    blocks.append((blockRange, code.trimmingCharacters(in: .newlines)))
                    openFence = nil
                } else {
                    openFence = (lineRange.location, NSMaxRange(lineRange))
                }
            } else if openFence != nil {
                storage.addAttributes([.font: codeFont, .foregroundColor: NSColor.labelColor], range: lineRange)
                highlightCode(line, at: lineRange.location, in: storage)
            } else {
                styleProse(line, at: lineRange.location, in: storage)
            }
            position = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        // An unclosed fence (still typing) styles to the end as code.
        if let open = openFence {
            let range = NSRange(location: open.start, length: text.length - open.start)
            storage.addAttribute(.lizardCodeBlock, value: blocks.count, range: range)
            blocks.append((range, text.substring(from: open.contentStart)))
        }
        storage.endEditing()
        return blocks
    }

    private static func styleProse(_ line: String, at offset: Int, in storage: NSTextStorage) {
        let ns = line as NSString
        let lineRange = NSRange(location: offset, length: ns.length)
        let moss = NSColor(Brand.moss)
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(leading)

        if rest.hasPrefix("#"), let space = rest.firstIndex(of: " "), rest[..<space].allSatisfy({ $0 == "#" }) {
            let level = rest.distance(from: rest.startIndex, to: space)
            if level <= 6 {
                let sizes: [CGFloat] = [27, 22, 18.5, 16.5, 15.5, 15]
                storage.addAttributes([.font: NSFont.systemFont(ofSize: sizes[level - 1], weight: .bold)], range: lineRange)
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: NSRange(location: offset + leading, length: level))
                return
            }
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["---", "***", "___"].contains(trimmed) {
            storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: lineRange)
            return
        }
        if rest.hasPrefix(">") {
            storage.addAttributes([.lizardQuote: true, .foregroundColor: NSColor.secondaryLabelColor, .obliqueness: 0.08], range: lineRange)
            storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: NSRange(location: offset + leading, length: 1))
        }
        // Lists and tasks.
        if let match = line.firstMatch(of: /^(\s*)([-*+]|\d+\.)\s(\[[ xX]\]\s)?/) {
            let markerLength = (line[match.range]).utf16.count
            storage.addAttributes([.foregroundColor: moss, .font: NSFont.systemFont(ofSize: 15, weight: .semibold)], range: NSRange(location: offset, length: markerLength))
            if let box = match.output.3, box.contains("x") || box.contains("X") {
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                    range: NSRange(location: offset + markerLength, length: max(0, lineRange.length - markerLength)))
            }
        }
        // Inline styles.
        for token in MarkdownTokenizer.inlineTokens(ns, offset: offset) {
            switch token.kind {
            case .inlineCode:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular), .foregroundColor: moss,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)], range: token.range)
            case .bold:
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 15, weight: .bold)], range: token.range)
            case .italic:
                storage.addAttributes([.obliqueness: 0.18], range: token.range)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: token.range)
            default:
                break
            }
        }
        // #tags
        if let regex = try? NSRegularExpression(pattern: #"(?:^|\s)(#[A-Za-z][\w/-]*)"#) {
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: 1)
                storage.addAttributes([.foregroundColor: NSColor(Brand.teal)], range: NSRange(location: offset + range.location, length: range.length))
            }
        }
    }

    /// Light, language-agnostic code colouring: comments, strings, numbers, common keywords.
    private static func highlightCode(_ line: String, at offset: Int, in storage: NSTextStorage) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func color(_ pattern: String, _ color: NSColor, italic: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: line, range: full) {
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if italic { attributes[.obliqueness] = 0.15 }
                storage.addAttributes(attributes, range: NSRange(location: offset + match.range.location, length: match.range.length))
            }
        }
        color(#"\b\d+(\.\d+)?\b"#, .systemOrange)
        let words = try? NSRegularExpression(pattern: #"\b[A-Za-z_]+\b"#)
        for match in words?.matches(in: line, range: full) ?? [] where keywords.contains(ns.substring(with: match.range)) {
            storage.addAttributes([.foregroundColor: NSColor.systemPurple], range: NSRange(location: offset + match.range.location, length: match.range.length))
        }
        color(#""[^"\n]*"|'[^'\n]*'"#, NSColor(Brand.teal))
        color(#"(//|#(?!!)).*$"#, .secondaryLabelColor, italic: true)
        // Shell prompt "$ " at the start of a line.
        color(#"^\s*\$(?= )"#, .tertiaryLabelColor)
    }
}

/// Keyboard conveniences: closing fences, continuing lists, indenting.
@MainActor
enum MarkdownTyping {
    /// ↩: inside an opening fence, add the closing fence; in a list item, continue (or end) the list.
    static func newline(in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return false }
        let lineRange = text.lineRange(for: NSRange(location: cursor.location, length: 0))
        let lineEnd = NSMaxRange(lineRange) - (text.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
        guard cursor.location == lineEnd else { return false }
        let line = text.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // ``` (+ language) on a line that opens a block → insert the closing fence.
        if trimmed.hasPrefix("```") {
            let before = text.substring(to: lineRange.location)
            let fencesBefore = before.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
            if fencesBefore % 2 == 0 {
                let after = text.substring(from: NSMaxRange(lineRange))
                let closesLater = after.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "```" }
                if !closesLater {
                    let indent = String(line.prefix { $0 == " " })
                    textView.insertText("\n\(indent)\n\(indent)```", replacementRange: cursor)
                    textView.setSelectedRange(NSRange(location: cursor.location + 1 + indent.utf16.count, length: 0))
                    return true
                }
            }
            return false
        }

        // Lists: "- item", "1. item", "- [ ] task".
        if let match = line.firstMatch(of: /^(\s*)([-*+]|(\d+)\.)\s(\[[ xX]\]\s)?(.*)$/) {
            let indent = String(match.output.1)
            let content = String(match.output.5)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: end the list.
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
                return false
            }
            var marker = String(match.output.2)
            if let number = match.output.3.flatMap({ Int($0) }) { marker = "\(number + 1)." }
            let box = match.output.4 != nil ? "[ ] " : ""
            textView.insertText("\n\(indent)\(marker) \(box)", replacementRange: cursor)
            return true
        }
        return false
    }

    /// ⇥ / ⇧⇥ on a list line indents/outdents it by two spaces.
    static func indent(in textView: NSTextView, outdent: Bool) -> Bool {
        let text = textView.string as NSString
        let cursor = textView.selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: cursor.location, length: 0))
        let line = text.substring(with: lineRange)
        guard line.firstMatch(of: /^\s*([-*+]|\d+\.)\s/) != nil else { return false }
        if outdent {
            let spaces = min(2, line.prefix { $0 == " " }.count)
            guard spaces > 0 else { return true }
            textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: spaces))
            textView.setSelectedRange(NSRange(location: max(lineRange.location, cursor.location - spaces), length: 0))
        } else {
            textView.insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
            textView.setSelectedRange(NSRange(location: cursor.location + 2, length: 0))
        }
        return true
    }
}
