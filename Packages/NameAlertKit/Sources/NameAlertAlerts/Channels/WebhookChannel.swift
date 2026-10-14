import Foundation
import NameAlertCore

/// Posts the hit as JSON to the address the user set (see `WebhookPayload`).
///
/// The request carries `X-Takeheed-Event` (`keyword.detected`, or `test` for the hit of a test button), the custom
/// headers the user named (their values are read from the Keychain; a name with no value is left out), and, when a
/// signing secret is set, `X-Takeheed-Signature` (both named in `WebhookHeader`). It has 5 s to answer and is tried
/// again after a network error or a 5xx answer (see `HTTPRetryPolicy.webhook`), never after a 4xx answer.
public struct WebhookChannel: AlertChannel {
    public var kind: ChannelKind { .webhook }

    private let client: HTTPClient
    private let appVersion: String
    private let build: String
    private let now: @Sendable () -> Date

    /// The segment ID of the hit that a test button sends.
    static let testSegmentID = "test"

    public init(
        client: HTTPClient = HTTPClient(), appVersion: String, build: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.appVersion = appVersion
        self.build = build
        self.now = now
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        guard settings.isConfigured(.webhook) else { throw AlertDeliveryError.notConfigured(.webhook) }
        guard let url = URL(string: WireText.trimmed(settings.webhook.url)) else {
            throw AlertDeliveryError.invalidAddress(.webhook)
        }

        let event = hit.segmentID == Self.testSegmentID ? "test" : "keyword.detected"
        let body = try WebhookPayload.body(for: hit, event: event, appVersion: appVersion, build: build)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(WebhookHeader.userAgent(version: appVersion), forHTTPHeaderField: "User-Agent")
        request.setValue(event, forHTTPHeaderField: WebhookHeader.event)
        for name in settings.webhook.headerNames {
            let field = WireText.trimmed(name)
            guard WireText.isHeaderName(field),
                let value = secrets.secret(for: SecretAccount.webhookHeader(name)).map(WireText.trimmed),
                !value.isEmpty, !value.contains(where: \.isNewline)
            else { continue }
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Last, so that nothing the user named can replace it.
        if let secret = secrets.secret(for: SecretAccount.webhookSigningSecret) {
            let timestamp = Int(now().timeIntervalSince1970)
            request.setValue(
                WebhookPayload.signatureHeader(body: body, secret: secret, timestamp: timestamp),
                forHTTPHeaderField: WebhookHeader.signature)
        }

        _ = try await client.send(request, timeout: 5, retry: .webhook)
    }
}
