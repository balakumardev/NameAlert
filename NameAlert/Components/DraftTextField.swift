import SwiftUI

/// A text field that holds what is typed itself and reports every change.
///
/// The settings live in the controller, which takes a change a moment after it is asked for. A field that showed the
/// controller's value while the user types would put back an older text and lose characters. This one keeps its own
/// text, and follows `value` again only when it is not being edited (a setting that changed elsewhere, or loaded late).
struct DraftTextField: View {
    private let title: String
    private let prompt: String?
    private let value: String
    private let onChange: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(_ title: String, value: String, prompt: String? = nil, onChange: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.value = value
        self.onChange = onChange
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text(verbatim: $0).foregroundStyle(.secondary) })
            .focused($isFocused)
            .onChange(of: text) { _, new in onChange(new) }
            .onChange(of: value) { _, new in
                if !isFocused, new != text { text = new }
            }
            .accessibilityLabel(title)
    }
}

/// A slider that moves with the pointer and reports every change; see `DraftTextField` for why it keeps its own value.
/// With a `step` the slider moves in whole steps and shows tick marks; without one it moves smoothly.
struct DraftSlider: View {
    private let title: String
    private let range: ClosedRange<Double>
    private let step: Double?
    private let onChange: (Double) -> Void

    @State private var draft: Double

    init(
        _ title: String, value: Double, in range: ClosedRange<Double>, step: Double? = nil,
        onChange: @escaping (Double) -> Void
    ) {
        self.title = title
        self.range = range
        self.step = step
        self.onChange = onChange
        _draft = State(initialValue: value)
    }

    var body: some View {
        slider
            .labelsHidden()
            .onChange(of: draft) { _, new in onChange(new) }
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $draft, in: range, step: step) { Text(verbatim: title) }
        } else {
            Slider(value: $draft, in: range) { Text(verbatim: title) }
        }
    }
}
