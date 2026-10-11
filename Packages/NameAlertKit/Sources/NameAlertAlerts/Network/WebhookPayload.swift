import CryptoKit
import Foundation
import NameAlertCore

/// What the webhook channel sends, and how it signs it.
///
/// The body is JSON with its keys in alphabetical order and no escaped slashes, so that the same hit always gives
/// the same bytes; the time is ISO 8601 in UTC, to the second.
public enum WebhookPayload {
    /// The body of the request for `hit`. `event` is `keyword.detected` for a real hit and `test` for a test.
    public static func body(for hit: Hit, event: String, appVersion: String, build: String) throws -> Data {
        let payload = Payload(
            event: event, version: 1, id: hit.id, timestamp: hit.timestamp,
            rule: RuleSummary(id: hit.ruleID, name: hit.ruleName), term: hit.term, matchedText: hit.matchedText,
            context: hit.context, source: hit.source, engine: hit.engine,
            app: AppSummary(version: appVersion, build: build))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    /// The value of the `X-NameAlert-Signature` header: `t=<unix seconds>,v1=<hex HMAC-SHA256>`. The HMAC is made
    /// with the secret as the key, over the timestamp, a dot and the body exactly as it is sent. The receiver checks
    /// it the same way, and can refuse a timestamp that is too old.
    public static func signatureHeader(body: Data, secret: String, timestamp: Int) -> String {
        var message = Data("\(timestamp).".utf8)
        message.append(body)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        let hex = code.map { String(format: "%02x", $0) }.joined()
        return "t=\(timestamp),v1=\(hex)"
    }

    // MARK: The body's shape (schema version 1)

    private struct Payload: Encodable {
        let event: String
        let version: Int
        let id: UUID
        let timestamp: Date
        let rule: RuleSummary
        let term: String
        let matchedText: String
        let context: String
        let source: AudioSourceKind
        let engine: EngineID
        let app: AppSummary
    }

    private struct RuleSummary: Encodable {
        let id: UUID
        let name: String
    }

    private struct AppSummary: Encodable {
        let version: String
        let build: String
    }
}
