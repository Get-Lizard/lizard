import Foundation

/// Detects a generation stuck in a loop: the same chunk (≥ 40 chars) repeated 4+ times in a row
/// at the end of the output — the classic small-model failure that burns minutes of GPU.
public enum RepetitionGuard {
    public static func isLooping(_ text: String) -> Bool {
        let chars = Array(text.suffix(2400))
        guard chars.count >= 400 else { return false }
        for period in stride(from: 40, through: 600, by: 1) where period * 4 <= chars.count {
            let end = chars.count
            var repeats = 1
            while repeats < 4 {
                let a = end - period * repeats, b = end - period * (repeats + 1)
                guard b >= 0, chars[b..<a] == chars[a..<(a + period)] else { break }
                repeats += 1
            }
            if repeats >= 4 {
                // Ignore pure whitespace/punctuation runs (indentation, separators).
                let unit = String(chars[(end - period)..<end])
                if unit.contains(where: { $0.isLetter }) { return true }
            }
        }
        return false
    }
}

