import GhostKit
import PhotosUI
import SwiftData
import SwiftUI

struct EditorView: View {
    @Bindable var entry: Entry

    @Environment(Navigation.self) private var navigation
    @Environment(Publisher.self) private var publisher
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.usesColumns) private var usesColumns
    @Query(sort: \Site.createdAt) private var sites: [Site]

    @State private var selection: TextSelection?
    @State private var showingTags = false
    @State private var showingPreview = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?
    @State private var pendingPublicPhoto: PhotosPickerItem?
    @State private var bodyFocused = false
    @State private var focusRequest = 0
    /// The title stays out of the way unless it's ticked on, or the entry already has one.
    @State private var showsTitle = false
    @State private var focusTitle = false
    /// The controls fade while words are arriving and come back in a pause.
    @State private var isTyping = false
    @State private var saveFailed = false

    private var site: Site? { sites.first { $0.id == entry.siteID } }
    private var isFocused: Bool { navigation.isFocused }
    private var isEditable: Bool { entry.state == .editing }
    private var canSend: Bool {
        isEditable && !entry.isBlank && site != nil && !uploading && !publisher.sending.contains(entry.id)
    }

    var body: some View {
        EditorTextView(text: $entry.body, selection: $selection, isFocused: $bodyFocused,
                       focusRequest: focusRequest, isEditable: isEditable,
                       margin: usesColumns ? 48 : 20) {
            // Hosted inside UIKit, so the environment has to be passed along.
            EditorHeader(entry: entry, site: site, isEditable: isEditable, showsTitle: showsTitle,
                         focusesTitle: focusTitle, onTags: { showingTags = true }, onSubmit: { focusRequest += 1 })
                .environment(navigation)
                .environment(publisher)
        }
        .background(Color.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if saveFailed {
                    Label("Couldn't save to this device. Keep this page open and free up some space.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, usesColumns ? 48 : 16)
                        .padding(.vertical, 8)
                        .background(Color.paper)
                }
                VStack(spacing: 0) {
                    if !isFocused { statusBar }
                    if bodyFocused && isEditable && !isFocused { formatBar }
                    if isEditable && !isFocused { publishBar }
                }
                .tint(.secondary)
                .opacity(isTyping ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.2), value: isTyping)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isFocused {
                focusButton
                    .opacity(isTyping ? 0.15 : 0.6)
                    .animation(.easeInOut(duration: 0.2), value: isTyping)
                    .padding(8)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isFocused ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(isFocused)
        .persistentSystemOverlays(isFocused ? .hidden : .automatic)
        .toolbar { toolbar }
        .sheet(isPresented: $showingTags) { TagEditor(entry: entry, site: site) }
        .sheet(isPresented: $showingPreview) { EntryPreview(title: entry.title, markdown: entry.body) }
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
        .onChange(of: entry.body) {
            touchIfStale()
            if bodyFocused { isTyping = true }
        }
        // Saved as you type, so there's nothing to do to keep a draft.
        .task(id: "\(entry.title)\(entry.body)") {
            try? await Task.sleep(for: .seconds(1))
            await saveUntilItWorks()
        }
        // The bars come back as soon as the writing pauses, without waiting on the save.
        .task(id: entry.body) {
            try? await Task.sleep(for: .seconds(0.5))
            if !Task.isCancelled { isTyping = false }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            if site?.isPublic == true { pendingPublicPhoto = item } else { Task { await insertPhoto(item) } }
        }
        .onAppear {
            showsTitle = !entry.title.isEmpty
            if isEditable && entry.isBlank && navigation.focusNextEntry { focusRequest += 1 }
            navigation.focusNextEntry = false
        }
    }

    private func saveUntilItWorks() async {
        while !Task.isCancelled {
            do {
                try context.save()
                saveFailed = false
                return
            } catch {
                if !saveFailed { Telemetry.report(error, while: "save") }
                saveFailed = true
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func touchIfStale() {
        if Date.now.timeIntervalSince(entry.updatedAt) > 30 { entry.touch() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SitePicker(entry: entry, sites: sites, locked: entry.remotePostID != nil || entry.uploadedToSiteID != nil || uploading || !isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            if !isFocused { focusButton }
        }
    }

    private var focusButton: some View {
        Button { navigation.toggleFocus() } label: {
            Image(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.primary)
                .padding(isFocused ? 12 : 0)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Focus")
        .keyboardShortcut("f", modifiers: [.command, .shift])
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
        .padding(.horizontal, usesColumns ? 48 : 16)
        .padding(.vertical, 8)
        .background(Color.paper)
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
        let isUploading = uploading
        PhotosPicker(selection: $photoItem, matching: .images) {
            if isUploading { ProgressView() } else { Image(systemName: "photo") }
        }
        .disabled(site == nil || uploading)
    }

    // MARK: Status bar

    /// Where the entry stands, down here so the page above is only the writing. Problems that need
    /// a decision stay above the text, in `StatusBanner`.
    @ViewBuilder private var statusBar: some View {
        switch entry.state {
        case .editing where entry.remotePostID != nil:
            statusRow { StatusNote(text: "Editing. Going back cancels.", icon: "pencil", color: .secondary) }
        case .sending:
            statusRow { StatusNote(text: "Sending to \(site?.name ?? "the site")…", icon: "arrow.up.circle", color: .secondary) }
        case .sent:
            statusRow {
                StatusNote(text: entry.remoteStatus == .draft ? "Draft" : site?.kind.doneLabel ?? "Published",
                           icon: "checkmark.circle", color: .green)
                Spacer()
                if let url = entry.remoteURL, entry.remoteStatus != .draft {
                    Button("View") { openURL(url) }
                }
                // Where Publish goes, so the main action never moves.
                Button("Edit", action: beginEditing)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.primary)
            }
        default:
            EmptyView()
        }
    }

    private func statusRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, usesColumns ? 48 : 16)
            .padding(.vertical, 10)
            .background(Color.paper)
    }

    private func beginEditing() {
        entry.beginEdit()
        selection = TextSelection(insertionPoint: entry.body.endIndex)
        focusRequest += 1
    }

    // MARK: Publish bar

    private var publishBar: some View {
        HStack(spacing: 12) {
            Button { showingTags = true } label: {
                Label(entry.tags.isEmpty ? "Tags" : "\(entry.tags.count)", systemImage: "tag")
            }
            .disabled(!isEditable)

            Button(action: toggleTitle) {
                Label("Title", systemImage: showsTitle ? "checkmark.square.fill" : "square")
            }
            .accessibilityAddTraits(showsTitle ? .isSelected : [])

            Spacer()

            Button("Preview") { showingPreview = true }
                .disabled(entry.isBlank)
                .accessibilityIdentifier("previewButton")

            Button(action: send) {
                if publisher.sending.contains(entry.id) {
                    ProgressView().tint(Color.paper)
                } else {
                    Text(sendLabel).fontWeight(.semibold).fixedSize()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color.paper)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("sendButton")
        }
        .padding(.horizontal, usesColumns ? 48 : 16)
        .padding(.vertical, 10)
        .background(Color.paper)
    }

    private var sendLabel: String {
        let kind = site?.kind ?? .ghost
        if entry.remotePostID != nil, entry.remoteStatus != .draft { return kind.updateLabel }
        return kind.publishLabel
    }

    private func toggleTitle() {
        showsTitle.toggle()
        focusTitle = showsTitle
        if showsTitle {
            entry.title = entry.hiddenTitle ?? ""
            entry.hiddenTitle = nil
        } else {
            entry.hiddenTitle = entry.title
            entry.title = ""
        }
    }

    private func send() {
        guard canSend else { return }
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
            let url = try await publisher.backend(for: site)
                .uploadImage(jpeg, filename: "quill-\(UUID().uuidString).jpg")
            // Going back cancels an edit, and the picture goes with it.
            guard entry.modelContext != nil, !entry.isDeleted, entry.state == .editing else { return }
            entry.uploadedToSiteID = site.id
            let (text, newSelection) = MarkdownFormat.insert("\n![](\(url.absoluteString))\n", into: entry.body, at: selection)
            entry.body = text
            selection = newSelection
        } catch {
            uploadError = error.localizedDescription
            Telemetry.report(error, while: "image upload")
        }
    }
}
