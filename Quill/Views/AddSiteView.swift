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
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .navigationDestination(for: SiteKind.self) { kind in
                siteForm(kind: kind, site: nil, isCentered: isRequired) { dismiss() }
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
        NavigationStack {
            siteForm(kind: site.kind, site: site, isCentered: false) { dismiss() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .sheetSize()
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
        Section("Colour") {
            HStack(spacing: 14) {
                ForEach(SiteColor.allCases) { option in
                    Button { color = option } label: {
                        Circle().fill(option.color).frame(width: 30, height: 30)
                            .overlay {
                                if option == color {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                }
            }
        }
    }
}
