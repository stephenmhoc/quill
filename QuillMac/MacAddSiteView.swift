import AppKit
import SwiftUI

/// File > Add Site, in the manner of the Mac's own account sheets: a header that says what's
/// being added, the kinds of site as a row of choices, then that kind's fields.
struct MacAddSiteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SiteKind = .ghost

    var body: some View {
        VStack(spacing: 0) {
            SiteSetupHeader(symbol: kind.systemImage, title: "Add a \(kind.title) Site", subtitle: kind.summary)
            SiteKindChoices(kind: $kind)
            siteForm(kind: kind, site: nil, isCentered: false) { dismiss() }
                .environment(\.siteFormHasCancel, true)
                .environment(\.siteFormHeight, kind.formHeight(isNew: true))
                .id(kind)
        }
        .sheetSize()
        // Switching kind grows or shrinks the sheet smoothly instead of in one jump.
        .animation(.smooth(duration: 0.25), value: kind)
    }
}

/// First run: the same choices and fields as Add Site, in the middle of the window.
struct MacWelcomeView: View {
    @State private var kind: SiteKind = .ghost

    var body: some View {
        VStack(spacing: 0) {
            SiteSetupHeader(image: Image(nsImage: NSApp.applicationIconImage), title: "Welcome to Quill",
                            subtitle: "Choose where you want to write. You can add more sites later.")
            SiteKindChoices(kind: $kind)
            // First run replaces this view by itself, so there's nothing for Add Site to close.
            siteForm(kind: kind, site: nil, isCentered: true) {}
                .environment(\.siteFormHeight, kind.formHeight(isNew: true))
                .id(kind)
        }
        .sheetSize()
        .animation(.smooth(duration: 0.25), value: kind)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Welcome to Quill")
    }
}

/// A sheet's heading: a large icon, a title and a line saying what's needed.
struct SiteSetupHeader: View {
    var symbol: String?
    var image: Image?
    let title: String
    let subtitle: String

    init(symbol: String, title: String, subtitle: String) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }

    init(image: Image, title: String, subtitle: String) {
        self.image = image
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tint)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

/// The kinds of site as a row of large choices, chosen before any field.
struct SiteKindChoices: View {
    @Binding var kind: SiteKind

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SiteKind.allCases) { option in
                SiteKindChoice(kind: option, isSelected: option == kind) {
                    withAnimation(.snappy(duration: 0.2)) { kind = option }
                }
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Type")
    }
}

private struct SiteKindChoice: View {
    let kind: SiteKind
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 22))
                    .frame(height: 26)
                Text(kind.title)
                    .font(.callout)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? AnyShapeStyle(.tint.quinary) : AnyShapeStyle(.fill.quinary),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(kind.summary)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("siteKind.\(kind)")
    }
}

extension SiteKind {
    /// What each kind's fields need, measured from the forms, so none scrolls or leaves a gap.
    func formHeight(isNew: Bool) -> CGFloat {
        switch self {
        case .ghost: 380
        case .microblog: 290
        case .local: 150
        }
    }
}
