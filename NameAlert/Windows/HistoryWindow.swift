import NameAlertRuntime
import SwiftUI

/// Every mention NameAlert heard: the same table as Settings → History, in a window of its own.
struct HistoryWindow: View {
    static let minimumSize = CGSize(width: 640, height: 400)

    var body: some View {
        HistoryLoader { hits in
            HistoryTable(hits: hits)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }
}
