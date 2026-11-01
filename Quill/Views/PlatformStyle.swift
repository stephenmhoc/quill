import SwiftUI

/// The small differences between iOS and the Mac, so shared views stay free of `#if`.
extension View {
    /// A short title in the bar, where iOS would otherwise choose.
    @ViewBuilder func compactTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func largeTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }

    /// For keys, tokens and addresses, which a keyboard would otherwise "fix".
    @ViewBuilder func literalEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    /// A field that says what it's for inside its own box. A Mac form would otherwise turn the
    /// title into a label beside a blank, invisible field.
    @ViewBuilder func promptedField() -> some View {
        #if os(macOS)
        labelsHidden().multilineTextAlignment(.leading)
        #else
        self
        #endif
    }

    /// The paper background behind a list. The Mac keeps its own list surfaces.
    @ViewBuilder func paperList() -> some View {
        #if os(iOS)
        scrollContentBackground(.hidden).background(Color.paper.ignoresSafeArea())
        #else
        self
        #endif
    }

    @ViewBuilder func cardRow(isSelected: Bool = false) -> some View {
        #if os(iOS)
        listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.card)
        #else
        self
        #endif
    }

    /// A sheet on a Mac takes its size from its content, and needs telling.
    @ViewBuilder func sheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 500, minHeight: 460)
        #else
        self
        #endif
    }

    /// A sheet's main button on a Mac needs more room than its word.
    @ViewBuilder func sheetButtonLabel() -> some View {
        #if os(macOS)
        padding(.horizontal, 12)
        #else
        self
        #endif
    }

    func siteFormStyle(isCentered: Bool) -> some View { modifier(SiteFormStyle(isCentered: isCentered)) }
}

private struct SiteFormStyle: ViewModifier {
    let isCentered: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.safeAreaPadding(.horizontal, isCentered && sizeClass == .regular ? 180 : 0)
        #else
        content.formStyle(.grouped)
        #endif
    }
}

extension Color {
    static var groupedSurface: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(.windowBackgroundColor)
        #endif
    }

    static var groupedCard: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color.primary.opacity(0.06)
        #endif
    }
}

/// What a Mac shows inside a field whose label is hidden. iOS already uses the title.
func fieldPrompt(_ text: String) -> Text? {
    #if os(macOS)
    Text(text)
    #else
    nil
    #endif
}

/// A secret's field with a Paste button beside it. Keys are always copied from somewhere, and a
/// stray line break from that copy would make a good key fail. No password content type: iOS
/// would offer to save the key to Passwords, and these stay in this device's Keychain.
struct SecretField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack {
            SecureField(prompt, text: $text, prompt: fieldPrompt(prompt))
                .promptedField()
                .literalEntry()
            #if os(macOS)
            Button {
                if let value = NSPasteboard.general.string(forType: .string) { paste(value) }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Paste")
            .accessibilityLabel("Paste")
            #else
            PasteButton(payloadType: String.self) { pasted in
                if let value = pasted.first { paste(value) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            #endif
        }
    }

    private func paste(_ value: String) {
        text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Below the form on iOS. A Mac sheet puts it in the footer, as `RemoveSiteToolbarItem`.
struct RemoveSiteSection: View {
    let note: String
    @Binding var isConfirming: Bool

    var body: some View {
        #if os(iOS)
        Section {
            Button("Remove Site", role: .destructive) { isConfirming = true }
        } footer: {
            Text(note)
        }
        #endif
    }
}

#if os(macOS)
struct RemoveSiteToolbarItem: ToolbarContent {
    let note: String
    @Binding var isConfirming: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .destructiveAction) {
            Button("Remove Site…", role: .destructive) { isConfirming = true }
                .help(note)
        }
    }
}
#endif
