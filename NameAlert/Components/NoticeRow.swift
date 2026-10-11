import SwiftUI

/// A tinted note with an icon, a sentence and an optional button under it: a problem or a warning the user can act
/// on.
struct NoticeRow<Action: View>: View {
    let systemImage: String
    let tint: Color
    let message: String
    @ViewBuilder let action: () -> Action

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 16)  // the same text edge whatever the symbol's width
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.6))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension NoticeRow where Action == EmptyView {
    init(systemImage: String, tint: Color, message: String) {
        self.init(systemImage: systemImage, tint: tint, message: message) { EmptyView() }
    }
}
