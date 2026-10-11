import NameAlertRuntime
import SwiftUI

/// What is being heard right now. Placeholder until the live transcript lands.
struct LiveTranscriptWindow: View {
    var body: some View {
        ContentUnavailableView("Live Transcript", systemImage: "text.bubble")
            .frame(minWidth: 520, minHeight: 360)
    }
}
