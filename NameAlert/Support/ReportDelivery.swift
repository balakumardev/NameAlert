import AppKit
import Foundation

/// How a report leaves the app: only by the person's own hands. Takeheed has no server and sends nothing. The report is
/// put on the pasteboard, and the person's mail app opens a message to the support address with one line that says to
/// paste it. The report itself is never in the link.
enum ReportDelivery {
    /// The support address, the one the website's support and privacy pages give.
    static let supportAddress = "mail@balakumar.dev"

    /// The one line a message holds.
    static let pasteInstruction = "Paste the report here. It was copied to your clipboard."

    /// A message to `supportAddress` with `subject` and the paste instruction.
    static func mailURL(subject: String) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: pasteInstruction),
        ]
        // `URLComponents` leaves a space in a query as it is; mail apps want it encoded.
        if let text = components.string?.replacingOccurrences(of: " ", with: "%20"), let url = URL(string: text) {
            return url
        }
        return URL(string: "mailto:\(supportAddress)") ?? URL(fileURLWithPath: "/")
    }

    /// Puts `text` on the pasteboard, then opens the mail message. In this order, so that the mail app never opens
    /// before the report can be pasted.
    @MainActor
    static func copyAndOpenMail(
        text: String, subject: String,
        copy: (String) -> Void = Pasteboard.copy,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        copy(text)
        open(mailURL(subject: subject))
    }
}
