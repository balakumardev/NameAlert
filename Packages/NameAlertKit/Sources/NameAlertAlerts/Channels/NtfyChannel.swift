import Foundation
import NameAlertCore

/// Pushes the hit to a phone through ntfy (ntfy.sh or the user's own server).
///
/// `POST <server>/<topic>` with the context as the body. The title is `Heard “<term>”`; the priority is the one in the
/// settings, and an access token from the Keychain goes in an `Authorization` header when there is one. It has 5 s to
/// answer and is tried once more after a network error or a 5xx answer (see `HTTPRetryPolicy.ntfy`).
public struct NtfyChannel: AlertChannel {
    public var kind: ChannelKind { .ntfy }

    private let client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        guard settings.isConfigured(.ntfy) else { throw AlertDeliveryError.notConfigured(.ntfy) }
        guard let url = Self.url(server: settings.ntfy.server, topic: settings.ntfy.topic) else {
            throw AlertDeliveryError.invalidAddress(.ntfy)
        }

        let title = "Heard “\(hit.term)”"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(hit.context.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(title, forHTTPHeaderField: "Title")
        // The curly quotes put the title beyond ASCII, and URLSession cannot send that in a header: it cuts the value
        // at the first quote (HTTP/1.1) or leaves the header out (HTTP/2), so ntfy would show a title with no name
        // (measured on macOS 27). ntfy reads `X-Title` before `Title` and decodes RFC 2047 encoded words in it, so the
        // same title goes there too.
        if let encoded = WireText.encodedWords(title) {
            request.setValue(encoded, forHTTPHeaderField: "X-Title")
        }
        request.setValue(settings.ntfy.priority.rawValue, forHTTPHeaderField: "Priority")
        request.setValue("ear", forHTTPHeaderField: "Tags")
        if let token = secrets.secret(for: SecretAccount.ntfyToken).map(WireText.trimmed), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        _ = try await client.send(request, timeout: 5, retry: .ntfy)
    }

    /// `<server>/<topic>`: the server's own path (if it has one) and the topic, joined by a single slash.
    /// `nil` when the server is not an http(s) address.
    static func url(server: String, topic: String) -> URL? {
        guard var components = URLComponents(string: WireText.trimmed(server)),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty
        else { return nil }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var segment = Substring(WireText.trimmed(topic))
        while segment.hasPrefix("/") { segment.removeFirst() }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let encodedTopic = String(segment).addingPercentEncoding(withAllowedCharacters: allowed), !encodedTopic.isEmpty
        else { return nil }

        components.percentEncodedPath = path + "/" + encodedTopic
        components.query = nil  // the server is where to publish; it has no say in what is published
        components.fragment = nil
        return components.url
    }
}
