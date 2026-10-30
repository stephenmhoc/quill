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
    @State private var bodyFocused = false
    @State private var focusRequest = 0
    /// The title stays out of the way until asked for, or if the entry already has one.
    @State private var wantsTitle = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isEditable: Bool { entry.state == .editing }
    private var tint: Color { site?.color.color ?? .accentColor }
    private var showsTitle: Bool { wantsTitle || !entry.title.isEmpty }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !publisher.sending.contains(entry.id)
    }

    var body: some View {
        EditorTextView(text: $entry.body, selection: $selection, isFocused: $bodyFocused,
                       focusRequest: focusRequest, isEditable: isEditable, tint: tint,
                       margin: sizeClass == .regular ? 48 : 20) {
            // Hosted inside UIKit, so the environment has to be passed along.
            EditorHeader(entry: entry, site: site, isEditable: isEditable, showsTitle: showsTitle,
                         focusesTitle: wantsTitle && entry.title.isEmpty, onTags: { showingTags = true }, onSubmit: { focusRequest += 1 })
                .environment(navigation)
                .environment(publisher)
        }
        .background(tint.opacity(0.035))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if bodyFocused && isEditable { formatBar }
                if isEditable { publishBar }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showingTags) { TagEditor(entry: entry, site: site) }
        .confirmationDialog("Publish to \(site?.name ?? "")?", isPresented: $confirmingPublic, titleVisibility: .visible) {
            Button("Publish publicly") { send() }
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
        // Saved as you type, so there's nothing to do to keep a draft.
        .task(id: "\(entry.title)\(entry.body)") {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { try? context.save() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            if site?.isPublic == true { pendingPublicPhoto = item } else { Task { await insertPhoto(item) } }
        }
        .onAppear { if isEditable && entry.isBlank { focusRequest += 1 } }
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
            Button(action: hideKeyboard) { Image(systemName: "keyboard.chevron.compact.down") }
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
            .accessibilityLabel("Heading")
        Button { apply(.bullet) } label: { Image(systemName: "list.bullet") }
        Button { apply(.quote) } label: { Image(systemName: "text.quote") }
            .accessibilityLabel("Quote")
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

            if !showsTitle {
                Button { wantsTitle = true } label: {
                    Label("Add Title", systemImage: "textformat")
                }
            }

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
        if entry.remotePostID != nil, entry.remoteStatus != .draft { return "Update" }
        return site?.isPublic == true ? "Publish publicly" : "Publish"
    }

    private func requestSend() {
        guard canSend, let site else { return }
        if site.isPublic { confirmingPublic = true } else { send() }
    }

    private func send() {
        hideKeyboard()
        let sent = entry
        let isNew = sent.remotePostID == nil
        sent.publishStatus = .published
        Task {
            await publisher.publish(sent)
            // A new entry is done, so start a fresh page. An update stays on the entry.
            if isNew, sent.state == .sent, navigation.selectedEntry == sent {
                navigation.openBlankEntry(in: context)
            }
        }
    }

    // MARK: Formatting

    private func apply(_ format: MarkdownFormat) {
        let (text, newSelection) = format.apply(to: entry.body, selection: selection)
        entry.body = text
        selection = newSelection
        focusRequest += 1
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

/// Everything above the text. It scrolls away with the page.
private struct EditorHeader: View {
    @Bindable var entry: Entry
    let site: Site?
    let isEditable: Bool
    let showsTitle: Bool
    let focusesTitle: Bool
    let onTags: () -> Void
    let onSubmit: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(entry: entry, site: site)
                .padding(.bottom, 16)
            if showsTitle {
                TextField("Title", text: $entry.title, axis: .vertical)
                    .font(.system(.title, design: .serif).weight(.semibold))
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
                note(entry.remoteStatus == .draft ? "Draft" : "Published", "checkmark.circle", .green)
                Spacer()
                if let url = entry.remoteURL, entry.remoteStatus != .draft {
                    Button("View") { openURL(url) }
                }
                Button("Edit") { entry.beginEdit() }
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
