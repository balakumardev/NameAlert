import NameAlertRuntime
import SwiftUI

/// While listening: the level meter and the last words heard. Clicking it opens the live transcript.
struct LiveStrip: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// About how many of the last characters heard to show, when they fit.
    static let snippetLength = 60

    var body: some View {
        let transcript = controller.liveTranscript
        Button {
            router.open(.live)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                LiveLevelMeter()
                if !Self.snippet(of: transcript).isEmpty {
                    // The longest ending that fits, so the line starts at a word and keeps its quotes.
                    ViewThatFits(in: .horizontal) {
                        quoted(Self.snippet(of: transcript))
                        quoted(Self.snippet(of: transcript, length: 52))
                        quoted(Self.snippet(of: transcript, length: 44))
                        quoted(Self.snippet(of: transcript, length: 36))
                        quoted(Self.snippet(of: transcript, length: 28))
                        quoted(Self.snippet(of: transcript, length: 20))
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle())
        .help("Show the live transcript")
        .accessibilityLabel("Show live transcript")
    }

    private func quoted(_ snippet: String) -> some View {
        Text(verbatim: "“\(snippet)”")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The end of the transcript: at most `length` characters, from the start of a word, with "…" when cut.
    static func snippet(of transcript: String, length: Int = snippetLength) -> String {
        let text = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > length else { return text }
        var tail = text.suffix(length)
        if let space = tail.firstIndex(of: " ") {
            tail = tail[tail.index(after: space)...]
        }
        return "…" + tail
    }
}

/// The level meter, reading the level itself: the level changes up to 15 times a second, and only this view has to
/// follow it.
private struct LiveLevelMeter: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        LevelMeter(level: controller.level)
    }
}
