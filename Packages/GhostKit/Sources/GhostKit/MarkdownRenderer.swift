import cmark_gfm
import cmark_gfm_extensions

/// CommonMark + GitHub extensions (tables, strikethrough, autolinks, task lists) → HTML.
/// Raw HTML passes through (it's the author's own content) and quotes/dashes are smartened.
enum MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tasklist"]

    static func html(from markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_SMART | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }
}
