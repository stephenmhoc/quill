import Foundation

/// Turns a Ghost post's HTML back into Markdown so it can be edited. Ghost doesn't keep Markdown.
/// Returns nil for anything Markdown can't hold (galleries, embeds, HTML cards, styled spans),
/// because saving a partial conversion would delete that content from the post.
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String? {
        var parser = Parser(html)
        guard let nodes = parser.parse() else { return nil }
        return blocks(nodes)?.joined(separator: "\n\n")
    }

    indirect enum Node {
        case text(String)
        case element(String, [String: String], [Node])
    }

    // MARK: Blocks

    private static let inlineTags: Set<String> = ["strong", "b", "em", "i", "code", "a", "br", "s", "del", "img"]

    private static func isInline(_ node: Node) -> Bool {
        switch node {
        case .text: true
        case .element(let name, _, _): inlineTags.contains(name)
        }
    }

    private static func blocks(_ nodes: [Node]) -> [String]? {
        var out: [String] = []
        var run: [Node] = []
        func flush() -> Bool {
            defer { run = [] }
            guard let text = inline(run) else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            return true
        }
        for node in nodes {
            if isInline(node) { run.append(node); continue }
            guard flush(), case .element(let name, let attrs, let children) = node,
                  let block = block(name, attrs, children) else { return nil }
            out.append(block)
        }
        return flush() ? out : nil
    }

    private static func block(_ name: String, _ attrs: [String: String], _ children: [Node]) -> String? {
        switch name {
        case "p":
            return inline(children)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard let level = Int(name.dropFirst()), let text = inline(children) else { return nil }
            return String(repeating: "#", count: level) + " " + text
        case "blockquote":
            guard let inner = blocks(children) else { return nil }
            // Ghost flattens a quote's paragraphs into one, separated by <br><br>.
            let text = inner.joined(separator: "\n\n").replacingOccurrences(of: "\\\n\\\n", with: "\n\n")
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        case "ul", "ol":
            return list(children, ordered: name == "ol", start: attrs["start"].flatMap(Int.init) ?? 1)
        case "pre":
            guard case .element("code", let codeAttrs, let code)? = children.first, children.count == 1 else { return nil }
            let language = codeAttrs["class"]?.split(separator: " ")
                .first { $0.hasPrefix("language-") }?.dropFirst("language-".count) ?? ""
            let text = plainText(code)
            // The fence has to outrun any backticks in the code itself.
            let longest = text.matches(of: /`+/).map(\.output.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return "\(fence)\(language)\n\(text.hasSuffix("\n") ? text : text + "\n")\(fence)"
        case "hr":
            return "---"
        case "figure":
            // A plain image card. Captions, widths and galleries have no Markdown form.
            guard attrs["class"] == "kg-card kg-image-card",
                  case .element("img", _, _)? = children.first, children.count == 1 else { return nil }
            return inline(children)
        default:
            return nil
        }
    }

    private static func list(_ children: [Node], ordered: Bool, start: Int) -> String? {
        var items: [String] = []
        for child in children {
            guard case .element("li", _, let content) = child, let inner = blocks(content) else {
                if case .text(let text) = child, text.allSatisfy(\.isWhitespace) { continue }
                return nil
            }
            let marker = ordered ? "\(start + items.count). " : "- "
            let loose = content.contains { if case .element("p", _, _) = $0 { true } else { false } }
            let lines = inner.joined(separator: loose ? "\n\n" : "\n").split(separator: "\n", omittingEmptySubsequences: false)
            let indent = String(repeating: " ", count: marker.count)
            items.append(lines.enumerated().map { index, line in
                index == 0 ? marker + line : line.isEmpty ? "" : indent + line
            }.joined(separator: "\n"))
        }
        return items.joined(separator: "\n")
    }

    // MARK: Inline

    private static func inline(_ nodes: [Node]) -> String? {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text):
                out += escape(text.replacing(/\s+/, with: " "))
            case .element(let name, let attrs, let children):
                switch name {
                case "br":
                    out += "\\\n"
                case "img":
                    guard let src = attrs["src"] else { return nil }
                    out += "![\(escape(attrs["alt"] ?? ""))](\(src))"
                case "code":
                    let text = plainText(children)
                    let fence = text.contains("`") ? "``" : "`"
                    out += fence + text + fence
                default:
                    guard let inner = inline(children) else { return nil }
                    switch name {
                    case "strong", "b": out += "**\(inner)**"
                    case "em", "i": out += "*\(inner)*"
                    case "s", "del": out += "~~\(inner)~~"
                    case "a":
                        guard let href = attrs["href"] else { return nil }
                        out += "[\(inner)](\(href))"
                    default: return nil
                    }
                }
            }
        }
        return out
    }

    private static func plainText(_ nodes: [Node]) -> String {
        nodes.map { node in
            switch node {
            case .text(let text): text
            case .element(_, _, let children): plainText(children)
            }
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_[]~<".contains(character) { out.append("\\") }
            out.append(character)
        }
        // A literal "&lt;" in the text would otherwise publish as "<".
        out.replace(/&(?=#?\w+;)/) { _ in "\\&" }
        // Would otherwise start a heading, quote or list.
        if let match = out.firstMatch(of: /^(\s*)(#{1,6} |> |[-+] |\d+[.)] )/) {
            let marker = String(match.output.2)
            let escaped = marker.first!.isNumber
                ? marker.dropLast(2) + "\\" + marker.suffix(2) : "\\" + marker
            out = match.output.1 + escaped + out[match.range.upperBound...]
        }
        return out
    }

    // MARK: Parser

    /// Just enough HTML for what Ghost renders. Bails on anything unexpected.
    private struct Parser {
        private static let void: Set<String> = ["br", "hr", "img"]
        private var rest: Substring

        init(_ html: String) { rest = html[...] }

        mutating func parse() -> [Node]? {
            guard let nodes = children(until: nil), rest.isEmpty else { return nil }
            return nodes
        }

        private mutating func children(until closing: String?) -> [Node]? {
            var nodes: [Node] = []
            while !rest.isEmpty {
                if rest.hasPrefix("<!--") {
                    guard let end = rest.range(of: "-->") else { return nil }
                    let comment = rest[..<end.lowerBound]
                    // Only markdown cards are plain content; HTML cards can hold anything.
                    guard comment.contains("kg-card") && comment.contains("markdown") else { return nil }
                    rest = rest[end.upperBound...]
                } else if rest.hasPrefix("</") {
                    guard let end = rest.firstIndex(of: ">") else { return nil }
                    let name = rest[rest.index(rest.startIndex, offsetBy: 2)..<end].lowercased()
                    guard name == closing else { return nil }
                    rest = rest[rest.index(after: end)...]
                    return nodes
                } else if rest.hasPrefix("<") {
                    guard let node = element() else { return nil }
                    nodes.append(node)
                } else {
                    let end = rest.firstIndex(of: "<") ?? rest.endIndex
                    nodes.append(.text(Parser.decode(rest[..<end])))
                    rest = rest[end...]
                }
            }
            return closing == nil ? nodes : nil
        }

        private mutating func element() -> Node? {
            guard let match = rest.prefixMatch(of: /<([a-zA-Z][a-zA-Z0-9]*)((?:\s+[a-zA-Z:-]+(?:="[^"]*")?)*)\s*\/?>/) else { return nil }
            let name = match.output.1.lowercased()
            var attrs: [String: String] = [:]
            for attr in match.output.2.matches(of: /([a-zA-Z:-]+)(?:="([^"]*)")?/) {
                attrs[attr.output.1.lowercased()] = attr.output.2.map(Parser.decode) ?? ""
            }
            rest = rest[match.range.upperBound...]
            if Parser.void.contains(name) { return .element(name, attrs, []) }
            guard let kids = children(until: name) else { return nil }
            return .element(name, attrs, kids)
        }

        private static func decode(_ text: Substring) -> String {
            var out = String(text)
            out = out.replacing(/&#x([0-9a-fA-F]+);/) { match in
                UInt32(match.output.1, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            out = out.replacing(/&#(\d+);/) { match in
                UInt32(match.output.1).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                out = out.replacingOccurrences(of: entity, with: character)
            }
            return out
        }
    }
}
