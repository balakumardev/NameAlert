import Foundation
import NameAlertCore

/// Pushes the hit to a phone through ntfy (ntfy.sh or the user's own server).
///
/// A JSON publish: `POST <server>/` with `{"topic", "title", "message", "priority", "tags"}`. The title is
/// `Heard “<term>”`, the message is the words around the term (the excerpt when there are none), the priority is the
/// one in the settings (3, 4 or 5 for default, high or urgent) and the tag is an ear. An access token from the Keychain
/// goes in an `Authorization` header when there is one. It has 5 s to answer and is tried once more after a network
/// error or a 5xx answer (see `HTTPRetryPolicy.ntfy`).
///
/// JSON, and not ntfy's way of putting the title and the priority in headers, because the title has curly quotes and
/// a name can have any letters, and a header cannot carry those: URLSession cuts the value at the first one
/// (HTTP/1.1) or leaves the header out (HTTP/2), so the notification would show no name. In the body, text goes as
/// UTF-8, as it is.
public struct NtfyChannel: AlertChannel {
    public var kind: ChannelKind { .ntfy }

    private let client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        guard settings.isConfigured(.ntfy) else { throw AlertDeliveryError.notConfigured(.ntfy) }
        guard let url = Self.url(server: settings.ntfy.server) else { throw AlertDeliveryError.invalidAddress(.ntfy) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try Self.body(for: hit, topic: settings.ntfy.topic, priority: settings.ntfy.priority)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = secrets.secret(for: SecretAccount.ntfyToken).map(WireText.trimmed), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        _ = try await client.send(request, timeout: 5, retry: .ntfy)
    }

    /// `<server>/`: ntfy takes a JSON publish at the root of its address, so the server's own path (if it has one,
    /// behind a reverse proxy, say) is kept and ends in exactly one slash. The server's query and fragment are dropped:
    /// it is where to publish, and has no say in what is published. `nil` when the server is not an http(s) address
    /// with a host.
    static func url(server: String) -> URL? {
        guard var components = URLComponents(string: WireText.trimmed(server)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty
        else { return nil }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The JSON of the publish, with its keys in alphabetical order and no escaped slashes, like the webhook's body.
    static func body(for hit: Hit, topic: String, priority: NtfyPriority) throws -> Data {
        let message = Message(
            topic: WireText.trimmed(topic), title: "Heard “\(hit.term)”", message: text(of: hit),
            priority: level(of: priority), tags: ["ear"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(message)
    }

    /// The words around the term; when there are none (only spaces), the excerpt; when that is no better, nothing,
    /// and ntfy then shows its own "triggered".
    private static func text(of hit: Hit) -> String {
        for candidate in [hit.context, hit.excerpt ?? ""] where !WireText.trimmed(candidate).isEmpty {
            return candidate
        }
        return ""
    }

    /// ntfy's priority numbers: 3 is its default, 4 high and 5 its maximum.
    private static func level(of priority: NtfyPriority) -> Int {
        switch priority {
        case .default: 3
        case .high: 4
        case .urgent: 5
        }
    }

    private struct Message: Encodable {
        let topic: String
        let title: String
        let message: String
        let priority: Int
        let tags: [String]
    }
}
