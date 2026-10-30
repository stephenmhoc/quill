import GhostKit
import SwiftUI

/// Brief confirmation after a send, naming the site it went to.
struct ResultBanner: View {
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let result = publisher.lastResult {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(message(result)).font(.system(.footnote, design: .monospaced))
                    if let url = result.url, result.status != .draft {
                        Button("Open") { openURL(url) }.font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.top, 56) // clears the site picker
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: result.id) {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { publisher.lastResult = nil }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: publisher.lastResult)
        .sensoryFeedback(.success, trigger: publisher.lastResult?.id)
    }

    private func message(_ result: Publisher.Result) -> String {
        if result.wasUpdate { return "Updated on \(result.siteName)" }
        return result.status == .draft ? "Draft sent to \(result.siteName)" : "Published to \(result.siteName)"
    }
}
