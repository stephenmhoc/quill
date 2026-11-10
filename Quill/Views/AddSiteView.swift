import SwiftUI

/// Choosing a kind of site, then its form. New kinds appear here by joining `SiteKind`.
struct AddSiteView: View {
    /// First run: there's nothing behind this, so it can't be cancelled.
    var isRequired = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isRequired ? "Where do you want to write?" : "What kind of site?")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .padding(.bottom, 6)
                    ForEach(SiteKind.allCases) { kind in
                        NavigationLink(value: kind) { SiteKindCard(kind: kind) }
                            .buttonStyle(SiteKindCardStyle())
                    }
                    Text("You can add more sites later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Color.groupedSurface)
            .navigationTitle(isRequired ? "Welcome to Quill" : "Add Site")
            .compactTitle()
            .toolbar {
                if !isRequired {
                    ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel") } }
                }
            }
            .navigationDestination(for: SiteKind.self) { kind in
                // First run replaces this view by itself. On a Mac, dismissing would close the window.
                siteForm(kind: kind, site: nil, isCentered: isRequired) { if !isRequired { dismiss() } }
            }
        }
        .sheetSize()
    }
}

private struct SiteKindCard: View {
    let kind: SiteKind

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.headline)
                Text(kind.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 18))
        #if os(macOS)
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.separator) }
        #endif
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("siteKind.\(kind.rawValue)")
    }
}

/// A soft press, so choosing feels physical.
private struct SiteKindCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// Edit an existing site, with the form for its kind.
struct EditSiteView: View {
    let site: Site
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The sheet can draw once more as it closes after the site is removed.
        if site.isLive {
            #if os(macOS)
            // No navigation on a Mac: the form and its buttons are the whole sheet.
            VStack(spacing: 0) {
                SiteSetupHeader(symbol: site.kind.systemImage, title: site.name, subtitle: "\(site.kind.title) site")
                siteForm(kind: site.kind, site: site, isCentered: false) { dismiss() }
                    .environment(\.siteFormHasCancel, true)
                    .environment(\.siteFormHeight, site.kind.formHeight(isNew: false))
            }
            .sheetSize()
            #else
            NavigationStack {
                siteForm(kind: site.kind, site: site, isCentered: false) { dismiss() }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel") } }
                    }
            }
            .sheetSize()
            #endif
        }
    }
}

/// The one place a kind of site chooses its form. `onDone` closes the whole flow.
@ViewBuilder func siteForm(kind: SiteKind, site: Site?, isCentered: Bool, onDone: @escaping () -> Void) -> some View {
    switch kind {
    case .ghost: GhostSiteForm(site: site, isCentered: isCentered, onDone: onDone)
    case .microblog: MicroblogSiteForm(site: site, isCentered: isCentered, onDone: onDone)
    case .local: LocalSiteForm(site: site, isCentered: isCentered, onDone: onDone)
    }
}

/// The colour row every site form shares.
struct SiteColorSection: View {
    @Binding var color: SiteColor

    var body: some View {
        #if os(macOS)
        LabeledContent("Color") {
            HStack(spacing: 8) {
                ForEach(SiteColor.allCases) { option in MacSwatch(color: option, isSelected: option == color) { color = option } }
            }
        }
        #else
        Section("Color") {
            // Each swatch is a full-size target, though the circle is drawn smaller.
            HStack(spacing: 4) {
                ForEach(SiteColor.allCases) { option in
                    Button { color = option } label: {
                        Circle().fill(option.color).frame(width: 32, height: 32)
                            .overlay {
                                if option == color {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(option == color ? .isSelected : [])
                }
            }
        }
        #endif
    }
}

#if os(macOS)
/// A colour to choose, the size of the Mac's own accent colour swatches, ringed when chosen.
private struct MacSwatch: View {
    let color: SiteColor
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(color.color)
                .frame(width: 18, height: 18)
                .overlay { if isSelected { Circle().fill(.white).frame(width: 6, height: 6) } }
                .padding(3)
                // The ring is drawn over the same fixed frame, so choosing one never moves the row.
                .overlay { if isSelected { Circle().strokeBorder(color.color, lineWidth: 1.5) } }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // A ring that follows Tab when keyboard navigation is on.
        .focusable()
        .help(color.label)
        .accessibilityLabel(color.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
