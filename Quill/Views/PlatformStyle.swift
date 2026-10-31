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
        Color(.controlBackgroundColor)
        #endif
    }
}
