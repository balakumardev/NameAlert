import AppKit
import SwiftUI

/// The words a rule listens for: each one a chip with a remove button, then a field for the next. Return or a comma
/// adds what was typed (so does leaving the field), and pasting "Bala, Balakumar" adds both.
///
/// It only shows the words and says what was asked: the caller changes the rule.
struct TermChipsField: View {
    let terms: [String]
    var focus: FocusState<Bool>.Binding
    /// Called with the new words: already trimmed, one by one, without repeats of `terms`.
    let add: ([String]) -> Void
    /// Called with the word whose remove button was pressed.
    let remove: (String) -> Void

    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                TermChip(term: term) { remove(term) }
            }
            TextField(
                "Words", text: $draft,
                prompt: Text(terms.isEmpty ? "Add a name or phrase" : "Add another").foregroundStyle(.secondary)
            )
            .textFieldStyle(.plain)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .focused(focus)
            .frame(minWidth: 150)
            .onSubmit { commit() }
            .onChange(of: draft) { _, text in splitAtCommas(text) }
            .onChange(of: focus.wrappedValue) { _, isFocused in
                if !isFocused { commit() }
            }
            .accessibilityLabel("Add a name or phrase")
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .contentShape(.rect(cornerRadius: 6))
        .onTapGesture { focus.wrappedValue = true }
    }

    /// Adds what is typed.
    private func commit() {
        let new = Self.terms(from: draft, besides: terms)
        draft = ""
        if !new.isEmpty { add(new) }
    }

    /// A comma ends a word: everything before the last comma is added, and what follows stays in the field.
    private func splitAtCommas(_ text: String) {
        guard text.contains(",") else { return }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let finished = parts.dropLast().joined(separator: ",")
        draft = String(parts.last ?? "")
        let new = Self.terms(from: finished, besides: terms)
        if !new.isEmpty { add(new) }
    }

    /// The words in `text`, which may hold several separated by commas: each trimmed, with runs of spaces made single,
    /// leaving out blanks and any word already in `existing` or earlier in `text` (ignoring case).
    static func terms(from text: String, besides existing: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var new: [String] = []
        for part in text.split(separator: ",") {
            guard let term = PopoverActions.keyword(from: String(part)), seen.insert(term.lowercased()).inserted else {
                continue
            }
            new.append(term)
        }
        return new
    }
}

/// One word in the field, with its remove button.
private struct TermChip: View {
    let term: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: term)
                .font(.callout)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Remove “\(term)”")
            .accessibilityLabel("Remove \(term)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(.tint.opacity(0.16)))
    }
}

/// Puts views side by side and starts a new line when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arranged = arrange(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, arranged.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if let width, x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}
