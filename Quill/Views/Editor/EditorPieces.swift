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
            ForEach(sites) { s in
                Button {
                    entry.siteID = s.id
                } label: {
                    Label(s.name, systemImage: s.accessIcon)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(site?.color.color ?? .gray).frame(width: 8, height: 8)
                Text(site?.name ?? "Choose site").fontWeight(.semibold)
                if let site { Image(systemName: site.accessIcon).font(.caption2) }
                if !locked { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
            }
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background((site?.color.color ?? .gray).opacity(0.15), in: Capsule())
            .foregroundStyle(site?.color.color ?? .secondary)
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
        .disabled(locked)
        .accessibilityLabel("Site: \(site?.name ?? "none")")
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
    let onEdit: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        // Hosted outside SwiftUI, so it can redraw once more after its entry is deleted.
        if entry.modelContext != nil && !entry.isDeleted { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(entry: entry, site: site, onEdit: onEdit)
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
            }
            if !entry.tags.isEmpty {
                TagStrip(tags: entry.tags, onTap: onTags)
                    .padding(.bottom, 8)
                    .disabled(!isEditable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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

/// Explains non-editable states and offers the way forward.
struct StatusBanner: View {
    @Bindable var entry: Entry
    let site: Site?
    let onEdit: () -> Void
    @Environment(Publisher.self) private var publisher
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch entry.state {
        case .editing:
            if entry.remotePostID != nil {
                note("Editing. Going back cancels.", "pencil", .secondary)
            }
        case .sending:
            note("Sending to \(site?.name ?? "the site")…", "arrow.up.circle", .secondary)
        case .queued:
            VStack(alignment: .leading, spacing: 8) {
                note(entry.lastError ?? "Waiting to send to \(site?.name ?? "the site").", "clock", .orange)
                HStack {
                    Button("Retry now") { Task { await publisher.publish(entry) } }
                    // A post that may already be on the site has to be found again before it can change.
                    if entry.createAttemptedAt == nil {
                        Button(entry.remotePostID == nil ? "Back to drafts" : "Keep editing") { entry.state = .editing }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                note(entry.lastError ?? "Couldn't send.", "exclamationmark.triangle", .red)
                HStack {
                    if entry.isConflict {
                        Button("Overwrite \(site?.kind.title ?? "the site")'s version") { Task { await publisher.overwrite(entry) } }
                        Button("Use \(site?.kind.title ?? "the site")'s version") { Task { await publisher.takeSiteVersion(entry) } }
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
        case .sent:
            HStack {
                note(entry.remoteStatus == .draft ? "Draft" : site?.kind.doneLabel ?? "Published", "checkmark.circle", .green)
                Spacer()
                if let url = entry.remoteURL, entry.remoteStatus != .draft {
                    Button("View") { openURL(url) }
                }
                Button("Edit") {
                    entry.beginEdit()
                    onEdit()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func note(_ text: String, _ icon: String, _ color: Color) -> some View {
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
