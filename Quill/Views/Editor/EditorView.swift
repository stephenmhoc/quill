import GhostKit
import PhotosUI
import SwiftData
import SwiftUI

struct EditorView: View {
    @Bindable var entry: Entry

    @Environment(AppLock.self) private var lock
    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Site.createdAt) private var sites: [Site]

    @State private var selection: TextSelection?
    @State private var confirmingPublic = false
    @State private var showingTags = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?
    @State private var pendingPublicPhoto: PhotosPickerItem?
    @FocusState private var focus: Field?

    enum Field { case title, body }

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isEditable: Bool { entry.state == .editing }
    private var tint: Color { site?.color.color ?? .accentColor }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !publisher.sending.contains(entry.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StatusBanner(entry: entry, site: site)
                    .padding(.bottom, 16)

                TextField("Title (optional)", text: $entry.title)
                    .font(.system(.title, design: .serif).weight(.semibold))
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }
                    .padding(.bottom, 8)
                    .disabled(!isEditable)

                if !entry.tags.isEmpty {
                    TagStrip(tags: entry.tags) { showingTags = true }
                        .padding(.bottom, 8)
                        .disabled(!isEditable)
                }

                ZStack(alignment: .topLeading) {
                    if entry.body.isEmpty {
                        Text("Write…")
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $entry.body, selection: $selection)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        .focused($focus, equals: .body)
                        .disabled(!isEditable)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, sizeClass == .regular ? 48 : 20)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tint.opacity(0.035))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if focus != nil && isEditable { formatBar }
                publishBar
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingTags) { TagEditor(entry: entry, site: site) }
        .confirmationDialog("Publish to \(site?.name ?? "")?", isPresented: $confirmingPublic, titleVisibility: .visible) {
            Button(entry.publishStatus == .published ? "Publish publicly" : "Send draft") { send() }
        } message: {
            Text("\(site?.host ?? "This site") is a public site.")
        }
        .confirmationDialog("Upload image to \(site?.name ?? "")?", isPresented: Binding(
            get: { pendingPublicPhoto != nil }, set: { if !$0 { pendingPublicPhoto = nil; photoItem = nil } }
        ), titleVisibility: .visible) {
            Button("Upload to public site") {
                if let item = pendingPublicPhoto { Task { await insertPhoto(item) } }
                pendingPublicPhoto = nil
            }
        } message: {
            Text("The image goes to \(site?.host ?? "the site") now, before you publish, and this entry stays on that site.")
        }
        .alert("Image upload failed", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
            Button("OK") { uploadError = nil }
        } message: { Text(uploadError ?? "") }
        // Throttled: updatedAt re-sorts every list on screen.
        .onChange(of: entry.title) { touchIfStale() }
        .onChange(of: entry.body) { touchIfStale() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            if site?.isPublic == true { pendingPublicPhoto = item } else { Task { await insertPhoto(item) } }
        }
        .onAppear { if isEditable && entry.isBlank { focus = .body } }
    }

    private func touchIfStale() {
        if Date.now.timeIntervalSince(entry.updatedAt) > 30 { entry.touch() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SitePicker(entry: entry, sites: sites, locked: entry.remotePostID != nil || entry.uploadedToSiteID != nil || uploading || !isEditable)
        }
        if sizeClass == .regular {
            ToolbarItem(placement: .primaryAction) {
                Button { navigation.toggleFocus() } label: {
                    Label("Focus", systemImage: navigation.columnVisibility == .detailOnly
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
        }
    }

    /// In the layout, not a keyboard toolbar: that one floats over the publish bar and takes its taps.
    private var formatBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 22) { formatButtons }
            }
            .scrollIndicators(.hidden)
            Button { focus = nil } label: { Image(systemName: "keyboard.chevron.compact.down") }
                .accessibilityLabel("Hide Keyboard")
        }
        .padding(.horizontal, sizeClass == .regular ? 48 : 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var formatButtons: some View {
        Button { apply(.bold) } label: { Image(systemName: "bold") }
            .keyboardShortcut("b")
        Button { apply(.italic) } label: { Image(systemName: "italic") }
            .keyboardShortcut("i")
        Button { apply(.heading) } label: { Image(systemName: "number") }
        Button { apply(.bullet) } label: { Image(systemName: "list.bullet") }
        Button { apply(.quote) } label: { Image(systemName: "text.quote") }
        Button { apply(.link) } label: { Image(systemName: "link") }
            .keyboardShortcut("k")
        PhotosPicker(selection: $photoItem, matching: .images) {
            if uploading { ProgressView() } else { Image(systemName: "photo") }
        }
        .disabled(site == nil || uploading)
    }

    // MARK: Publish bar

    private var publishBar: some View {
        HStack(spacing: 12) {
            Button { showingTags = true } label: {
                Label(entry.tags.isEmpty ? "Tags" : "\(entry.tags.count)", systemImage: "tag")
            }
            .disabled(!isEditable)

            Picker("Status", selection: $entry.publishStatus) {
                Text("Publish").tag(GhostPost.Status.published)
                Text("Draft").tag(GhostPost.Status.draft)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(!isEditable)

            Spacer()

            if site?.isPublic == true {
                Label("PUBLIC", systemImage: "globe")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(tint)
            }

            Button(action: requestSend) {
                if publisher.sending.contains(entry.id) {
                    ProgressView().tint(.white)
                } else {
                    Text(sendLabel).fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("sendButton")
        }
        .padding(.horizontal, sizeClass == .regular ? 48 : 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var sendLabel: String {
        if entry.remotePostID != nil { return "Update" }
        if entry.publishStatus == .draft { return "Send Draft" }
        return site?.isPublic == true ? "Publish publicly" : "Publish"
    }

    private func requestSend() {
        guard canSend, let site else { return }
        if site.isPublic { confirmingPublic = true } else { send() }
    }

    private func send() {
        focus = nil
        let sent = entry
        Task {
            await publisher.publish(sent)
            // On success, start a fresh page; the sent entry stays in Sent.
            if sent.state == .sent, navigation.selectedEntry == sent {
                navigation.openBlankEntry(in: context)
            }
        }
    }

    // MARK: Formatting

    private func apply(_ format: MarkdownFormat) {
        let (text, newSelection) = format.apply(to: entry.body, selection: selection)
        entry.body = text
        selection = newSelection
        focus = .body
    }

    private func insertPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let site else { return }
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = ImagePrep.jpeg(from: data) else {
                uploadError = "Couldn't read that image."
                return
            }
            let url = try await lock.client(for: site)
                .uploadImage(jpeg, filename: "quill-\(Int(Date.now.timeIntervalSince1970)).jpg", mimeType: "image/jpeg")
            entry.uploadedToSiteID = site.id
            let (text, newSelection) = MarkdownFormat.insert("\n![](\(url.absoluteString))\n", into: entry.body, at: selection)
            entry.body = text
            selection = newSelection
        } catch {
            uploadError = error.localizedDescription
        }
    }
}

// MARK: - Pieces

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
                    Label(s.name, systemImage: s.isPublic ? "globe" : "lock")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(site?.color.color ?? .gray).frame(width: 8, height: 8)
                Text(site?.name ?? "Choose site").fontWeight(.semibold)
                if let site { Image(systemName: site.isPublic ? "globe" : "lock").font(.caption2) }
                if !locked { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
            }
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background((site?.color.color ?? .gray).opacity(0.15), in: Capsule())
            .foregroundStyle(site?.color.color ?? .secondary)
        }
        .disabled(locked)
        .accessibilityLabel("Site: \(site?.name ?? "none")")
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
    @Environment(Publisher.self) private var publisher
    @Environment(Navigation.self) private var navigation
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch entry.state {
        case .editing:
            if entry.remotePostID != nil {
                note("Editing a sent entry. Update replaces it in \(site?.name ?? "Ghost").", "pencil", .secondary)
            }
        case .sending:
            note("Sending to \(site?.name ?? "the site")…", "arrow.up.circle", .secondary)
        case .queued:
            VStack(alignment: .leading, spacing: 8) {
                note(entry.lastError ?? "Waiting to send to \(site?.name ?? "the site").", "clock", .orange)
                HStack {
                    Button("Retry now") { Task { await publisher.publish(entry) } }
                    Button("Back to drafts") { entry.state = .editing }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                note(entry.lastError ?? "Couldn't send.", "exclamationmark.triangle", .red)
                HStack {
                    if entry.isConflict {
                        Button("Overwrite Ghost's version") { Task { await publisher.overwrite(entry) } }
                    } else {
                        Button("Retry") { Task { await publisher.publish(entry) } }
                    }
                    Button("Edit") { entry.state = .editing; entry.failureReason = nil }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .sent:
            HStack {
                note("\(entry.remoteStatus == .draft ? "Saved as a draft" : "Published") to \(site?.name ?? "Ghost")",
                     "checkmark.circle", .green)
                Spacer()
                if let url = entry.remoteURL, entry.remoteStatus != .draft {
                    Button("View") { openURL(url) }
                }
                Button("Edit") {
                    entry.state = .editing
                    navigation.sidebar = .drafts
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
    /// Re-encodes any image (HEIC etc.) as JPEG, at most 2400px on the long edge.
    static func jpeg(from data: Data, maxDimension: CGFloat = 2400) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
