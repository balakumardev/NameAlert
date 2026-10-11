import SwiftUI

/// A borderless button drawn like a menu row: a rounded highlight on hover, on press and on keyboard focus.
struct RowButtonStyle: ButtonStyle {
    /// Draws the hover highlight all the time: for a selected row, or to render the hover look.
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool

    @State private var isHovered = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect(cornerRadius: 6))
            .background(.primary.opacity(highlight), in: .rect(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }

    private var highlight: Double {
        let increased = contrast == .increased
        if configuration.isPressed { return increased ? 0.25 : 0.14 }
        if isHighlighted || isHovered || isFocused { return increased ? 0.16 : 0.08 }
        return 0
    }
}
