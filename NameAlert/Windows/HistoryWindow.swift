import NameAlertRuntime
import SwiftUI

/// Every mention NameAlert heard. Placeholder until the history table lands.
struct HistoryWindow: View {
    var body: some View {
        ContentUnavailableView("History", systemImage: "clock")
            .frame(minWidth: 640, minHeight: 400)
    }
}
