import SwiftUI

/// A row of a settings form: the label, and a text field that takes the rest of the width. See `DraftTextField` for
/// how it keeps what is typed.
struct LabeledTextField: View {
    let title: String
    let value: String
    var prompt: String?
    let onChange: (String) -> Void

    var body: some View {
        LabeledContent(title) {
            DraftTextField(title, value: value, prompt: prompt, onChange: onChange)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity)
        }
    }
}
