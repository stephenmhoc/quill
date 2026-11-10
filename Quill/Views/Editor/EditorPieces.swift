import GhostKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SitePicker: View {
    @Bindable var entry: Entry
    let sites: [Site]
    let locked: Bool

    private var site: Site? { sites.first { $0.id == entry.siteID } }

    var body: some View {
        Menu {
            // A picker, so the menu ticks the site the entry is on.
            Picker("Site", selection: $entry.siteID) {
                ForEach(sites) { s in
                    Label(s.name, systemImage: s.accessIcon).tag(Optional(s.id))
                }
            }
        } label: {
            SitePickerLabel(site: site, locked: locked)
        }
        .disabled(locked)
        .accessibilityLabel("Site: \(site?.name ?? "none")")
    }
}

/// The coloured pill naming where an entry will go.
struct SitePickerLabel: View {
    let site: Site?
    let locked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(site?.color.color ?? .gray).frame(width: 8, height: 8)
            Text(site?.name ?? "Choose site").fontWeight(.semibold)
            if let site { Image(systemName: site.accessIcon).font(.caption2) }
            if !locked { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .font(.system(.subheadline, design: .monospaced))
        .padding(.horizontal, 12)
        #if os(macOS)
        .frame(height: 36)
        #else
        .padding(.vertical, 6)
        #endif
        .background((site?.color.color ?? .gray).opacity(0.15), in: Capsule())
        .foregroundStyle(site?.color.color ?? .secondary)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }
}

/// Everything above the text. It scrolls away with the page.
struct EditorHeader: View {
    @Bindable var entry: Entry
    let site: Site?
    let isEditable: Bool
    let showsTitle: Bool
    let focusesTitle: Bool
    let onTags: () -> Void
    let onSubmit: () -> Void
    /// Bump to move the cursor to the title, as ↑ on the first line does on a Mac.
    var titleFocusRequest = 0
    @FocusState private var titleFocused: Bool

    var body: some View {
        // Hosted outside SwiftUI, so it can redraw once more after its entry is deleted.
        if entry.modelContext != nil && !entry.isDeleted { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(entry: entry, site: site)
                .padding(.bottom, 16)
            if showsTitle {
                TextField("Title", text: $entry.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .lineLimit(1...4)
                    .disabled(!isEditable)
                    .focused($titleFocused)
                    .accessibilityIdentifier("titleField")
                    .padding(.bottom, 8)
                    // Multi-line so long titles wrap, but Return still moves on to the text.
                    .onChange(of: entry.title) { _, title in
                        guard title.contains(where: \.isNewline) else { return }
                        entry.title = title.filter { !$0.isNewline }
                        onSubmit()
                    }
                    .task { if focusesTitle { titleFocused = true } }
                    .onChange(of: titleFocusRequest) { titleFocused = true }
                    #if os(macOS)
                    // The title and the text read as one page, so the keys cross between them.
                    // While an input method is composing, its candidate list has them first.
                    .onKeyPress(.downArrow) { moveOn() }
                    .onKeyPress(.tab) { moveOn() }
                    #endif
            }
            if !entry.tags.isEmpty {
                TagStrip(tags: entry.tags, onTap: onTags)
                    .padding(.bottom, 8)
                    .disabled(!isEditable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(macOS)
    private func moveOn() -> KeyPress.Result {
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        onSubmit()
        return .handled
    }
    #endif
}

struct TagStrip: View {
    let tags: [String]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(tags.filter { !$0.hasPrefix("#") }.map { "#\($0)" }.joined(separator: "  "))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Only what needs a decision sits above the text. The calm states are in a bar below the page.
struct StatusBanner: View {
    @Bindable var entry: Entry
    let site: Site?
    @Environment(Publisher.self) private var publisher

    var body: some View {
        switch entry.state {
        case .queued:
            VStack(alignment: .leading, spacing: 8) {
                StatusNote(text: entry.lastError ?? "Waiting to send to \(site?.name ?? "the site").", icon: "clock", color: .orange)
                HStack {
                    Button("Retry Now") { Task { await publisher.publish(entry) } }
                    // A post that may already be on the site has to be found again before it can change.
                    if entry.createAttemptedAt == nil {
                        Button(entry.remotePostID == nil ? "Back to Drafts" : "Keep Editing") { entry.state = .editing }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                StatusNote(text: entry.lastError ?? "Couldn't send.", icon: "exclamationmark.triangle", color: .red)
                HStack {
                    if entry.isConflict {
                        Button("Overwrite \(site?.kind.title ?? "the Site")'s Version") {
                            Task { await publisher.overwrite(entry) }
                        }
                        Button("Use \(site?.kind.title ?? "the Site")'s Version") {
                            Task { await publisher.takeSiteVersion(entry) }
                        }
                    } else {
                        Button("Retry") { Task { await publisher.publish(entry) } }
                    }
                    if entry.createAttemptedAt == nil {
                        Button("Edit") { entry.state = .editing; entry.failureReason = nil }
                            .disabled(publisher.sending.contains(entry.id))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
}

struct StatusNote: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(color)
    }
}

enum ImagePrep {
    /// Re-encodes any image (HEIC etc.) as JPEG, at most 2400px on the long edge, without its
    /// metadata, which can include where it was taken.
    static func jpeg(from data: Data, maxDimension: CGFloat = 2400) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxDimension,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
