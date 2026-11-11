import SwiftUI

/// What the writing lives on, in words. A Mac isn't a "device" to the person using it.
nonisolated let thisDevice: String = {
    #if os(macOS)
    "this Mac"
    #else
    "this device"
    #endif
}()

/// A form row's title. A Mac shows it as a label beside the field, iOS uses the placeholder.
func fieldTitle(mac: String, iOS: String) -> String {
    #if os(macOS)
    mac
    #else
    iOS
    #endif
}

extension EnvironmentValues {
    /// Mac: the form is in a sheet, so it has a Cancel beside its own buttons.
    @Entry var siteFormHasCancel = false
    /// Mac: the height of a site form's fields. A grouped form scrolls, so it can't size itself.
    @Entry var siteFormHeight: CGFloat = 360
}

#if os(macOS)
extension EnvironmentValues {
    /// Mac: what's typed in the sidebar's search field, which narrows the list beside it.
    @Entry var listQuery = ""
    /// Mac: the lock screen covers the window, so its title mustn't name a site.
    @Entry var isCovered = false
    /// Mac: Focus Mode's page covers the window, so the columns behind it give it no title and
    /// take their items out of the toolbar, which stays in place so the window keeps its size.
    @Entry var hidesTitle = false
}
#endif

/// A form section's heading. A Mac's labelled rows already say what each one is.
@ViewBuilder func sectionHeader(_ text: String) -> some View {
    #if os(iOS)
    Text(text)
    #endif
}

/// The small differences between iOS and the Mac, so shared views stay free of `#if`.
extension View {
    /// A form's note under its fields. iOS styles footers itself; a Mac form shows plain text.
    @ViewBuilder func formNote() -> some View {
        #if os(macOS)
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        #else
        self
        #endif
    }

    /// A site form's title in the bar. A Mac sheet has no bar, and first run names the window itself.
    @ViewBuilder func formTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
        #else
        self
        #endif
    }

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

    /// A field that says what it's for inside its own box. A Mac form labels it beside the field.
    @ViewBuilder func promptedField() -> some View {
        #if os(macOS)
        multilineTextAlignment(.leading)
        #else
        self
        #endif
    }

    /// A choice between a couple of options: radio buttons on a Mac, segments on iOS.
    @ViewBuilder func choiceStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup).horizontalRadioGroupLayout()
        #else
        pickerStyle(.segmented)
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

    func cardRow(isSelected: Bool = false) -> some View { modifier(CardRow(isSelected: isSelected)) }

    /// A sheet on a Mac takes its height from its content, and only needs a width.
    @ViewBuilder func sheetSize() -> some View {
        #if os(macOS)
        frame(width: 480)
        #else
        self
        #endif
    }

    /// A site form's Save, plus Remove and Cancel on a Mac. iOS puts Save in the bar; a Mac
    /// puts them all along the bottom, where a Mac sheet's buttons go, Return and Esc included.
    /// A Mac shows the form's error above the buttons, outside the fixed-height form, where it can't be clipped.
    func siteFormButtons(isNew: Bool, canSave: Bool, isWorking: Bool = false, error: String? = nil, removeNote: String? = nil,
                         isConfirmingRemove: Binding<Bool> = .constant(false), save: @escaping () -> Void) -> some View {
        modifier(SiteFormButtons(isNew: isNew, canSave: canSave, isWorking: isWorking, error: error, removeNote: removeNote,
                                 isConfirmingRemove: isConfirmingRemove, save: save))
    }

    /// `extraHeight` makes room on a Mac for a section that comes and goes, like Micro.blog's Blog picker.
    func siteFormStyle(isCentered: Bool, extraHeight: CGFloat = 0) -> some View {
        modifier(SiteFormStyle(isCentered: isCentered, extraHeight: extraHeight))
    }
}

/// A card on iPhone. In iPad's columns a block of rows looks boxy against the page, so they sit
/// directly on it, and only the open one is marked. The Mac keeps its own list surfaces.
private struct CardRow: ViewModifier {
    let isSelected: Bool
    @Environment(\.usesColumns) private var usesColumns

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if usesColumns {
            // Taller rows, so the mark clears the dividers either side of it.
            content
                .padding(.vertical, 6)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
                        .padding(.vertical, 5))
        } else {
            content.listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.card)
        }
        #else
        content
        #endif
    }
}

private struct SiteFormStyle: ViewModifier {
    let isCentered: Bool
    let extraHeight: CGFloat
    @Environment(\.siteFormHeight) private var height
    #if os(iOS)
    /// First run fills the window, where a form any wider than this is hard to read.
    private static let readableWidth: CGFloat = 600
    @State private var width: CGFloat = 0
    #endif

    #if os(macOS)
    private static let maxHeight: CGFloat = 560
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .safeAreaPadding(.horizontal, isCentered ? max(0, (width - Self.readableWidth) / 2) : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #else
        // System Settings' grouped rows, at the height their kind of site needs (see
        // `SiteKind.formHeight`), which Add Site animates between. The heights fit, so they don't
        // scroll, until a section that comes and goes needs more room than a sheet should take.
        let wanted = height + extraHeight
        content.formStyle(.grouped)
            .scrollDisabled(wanted <= Self.maxHeight)
            .frame(height: min(wanted, Self.maxHeight))
            .animation(.smooth(duration: 0.25), value: extraHeight)
        #endif
    }
}

private struct SiteFormButtons: ViewModifier {
    let isNew: Bool
    let canSave: Bool
    let isWorking: Bool
    let error: String?
    let removeNote: String?
    @Binding var isConfirmingRemove: Bool
    let save: () -> Void
    @Environment(\.siteFormHasCancel) private var hasCancel
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking { ProgressView() } else {
                    Button(isNew ? "Add" : "Save", action: save)
                        .accessibilityIdentifier("saveSite")
                        .disabled(!canSave)
                }
            }
        }
        #else
        VStack(spacing: 0) {
            content
            Divider()
            if let error {
                FormErrorRow(message: error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .accessibilityIdentifier("siteFormError")
            }
            HStack(spacing: 8) {
                if let removeNote {
                    Button("Remove Site…", role: .destructive) { isConfirmingRemove = true }
                        .help(removeNote)
                }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.callout).foregroundStyle(.secondary)
                }
                if hasCancel { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(isNew ? "Add Site" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isWorking)
                    .accessibilityIdentifier("saveSite")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        #endif
    }
}

/// A form's error, where it happened instead of in an alert: the form's last section on iOS, and
/// above the buttons on a Mac (see `siteFormButtons`), whose fixed-height form would clip it.
struct FormErrorRow: View {
    let message: String

    var body: some View {
        #if os(macOS)
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        #else
        Section {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
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
    /// The Mac's label beside the field. iOS shows the prompt instead.
    var label = ""
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack {
            SecureField(fieldTitle(mac: label, iOS: prompt), text: $text, prompt: fieldPrompt(prompt))
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

/// Below the form on iOS. A Mac sheet puts Remove in its footer instead; see `siteFormButtons`.
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
