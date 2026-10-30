import SwiftUI

/// Markdown shortcuts applied to the current selection. Pure string logic so it's testable.
enum MarkdownFormat {
    case bold, italic, link, heading, bullet, quote

    func apply(to text: String, selection: TextSelection?) -> (String, TextSelection?) {
        let range = Self.range(in: text, selection)
        switch self {
        case .bold: return Self.wrap(text, range, "**", "**")
        case .italic: return Self.wrap(text, range, "_", "_")
        case .link: return Self.wrap(text, range, "[", "](https://)")
        case .heading: return Self.prefixLine(text, range, "## ")
        case .bullet: return Self.prefixLine(text, range, "- ")
        case .quote: return Self.prefixLine(text, range, "> ")
        }
    }

    static func insert(_ snippet: String, into text: String, at selection: TextSelection?) -> (String, TextSelection?) {
        let range = range(in: text, selection)
        var result = text
        result.replaceSubrange(range, with: snippet)
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + snippet.count
        return (result, caret(in: result, at: offset))
    }

    // MARK: Helpers (offsets in Characters, so indices stay valid after edits)

    private static func range(in text: String, _ selection: TextSelection?) -> Range<String.Index> {
        if case .selection(let r)? = selection?.indices,
           r.lowerBound >= text.startIndex, r.upperBound <= text.endIndex {
            return r
        }
        return text.endIndex..<text.endIndex
    }

    private static func wrap(_ text: String, _ range: Range<String.Index>, _ open: String, _ close: String) -> (String, TextSelection?) {
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let selected = String(text[range])
        var result = text
        result.replaceSubrange(range, with: open + selected + close)
        // Empty selection: caret between the markers. Otherwise select the wrapped text.
        let innerStart = start + open.count
        if selected.isEmpty { return (result, caret(in: result, at: innerStart)) }
        let lower = result.index(result.startIndex, offsetBy: innerStart)
        let upper = result.index(lower, offsetBy: selected.count)
        return (result, TextSelection(range: lower..<upper))
    }

    private static func prefixLine(_ text: String, _ range: Range<String.Index>, _ prefix: String) -> (String, TextSelection?) {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let caretOffset = text.distance(from: text.startIndex, to: range.upperBound)
        var result = text
        if text[lineStart...].hasPrefix(prefix) {
            result.removeSubrange(lineStart..<text.index(lineStart, offsetBy: prefix.count))
            return (result, caret(in: result, at: max(0, caretOffset - prefix.count)))
        }
        result.insert(contentsOf: prefix, at: lineStart)
        return (result, caret(in: result, at: caretOffset + prefix.count))
    }

    private static func caret(in text: String, at offset: Int) -> TextSelection {
        let index = text.index(text.startIndex, offsetBy: min(offset, text.count))
        return TextSelection(insertionPoint: index)
    }
}
