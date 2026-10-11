import Foundation
import NameAlertCore

/// Places a Telegram voice call that reads the alert out, through the free CallMeBot service.
///
/// The user has to allow @CallMeBot_txtbot on Telegram first. The message is the user's template with `{keyword}` (the
/// term), `{text}` (what was heard) and `{context}` (the words around it) filled in. Calls are placed at most one a
/// minute: a hit that comes sooner is skipped without a request, and `deliver` throws
/// `AlertDeliveryError.rateLimited`, which the dispatcher does not count as a failure and a Test shows. The request has
/// 10 s and is not tried again. A request that is refused or never made (no network, an error answer) does not use up
/// the minute; one that is cut short (timed out, cancelled) does, because the call may have been placed.
public actor TelegramCallChannel: AlertChannel {
    public nonisolated var kind: ChannelKind { .telegramCall }

    private static let endpoint = "https://api.callmebot.com/start.php"
    private static let minimumGap: TimeInterval = 60

    private let client: HTTPClient
    private let now: @Sendable () -> Date
    private let logger = Log.logger("telegram")
    /// When the last call went out; `nil` before the first one, and again after a call that failed.
    private var lastCall: Date?

    public init(client: HTTPClient = HTTPClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        guard settings.isConfigured(.telegramCall) else { throw AlertDeliveryError.notConfigured(.telegramCall) }
        let call = settings.telegramCall
        guard
            let url = Self.url(
                user: call.user, message: Self.message(from: call.messageTemplate, for: hit), voice: call.voice)
        else { throw AlertDeliveryError.invalidAddress(.telegramCall) }

        // A clock that was set back counts as the minute being over.
        let moment = now()
        if let last = lastCall, moment >= last, moment.timeIntervalSince(last) < Self.minimumGap {
            logger.info("A Telegram call was skipped: the last one was less than a minute ago")
            throw AlertDeliveryError.rateLimited(.telegramCall)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Taken before the request goes out, so that a second hit that arrives while it is on its way is held back too.
        let before = lastCall
        lastCall = moment
        do {
            _ = try await client.send(request, timeout: 10, retry: .none)
        } catch {
            if !Self.mayHavePlacedTheCall(after: error) { lastCall = before }
            throw error
        }
    }

    /// Whether a request that ended in `error` may still have made the service place the call: one that was cut short
    /// may have, one that was refused (an error answer) or could not be made (no network) did not.
    private static func mayHavePlacedTheCall(after error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError { return [.timedOut, .cancelled, .networkConnectionLost].contains(error.code) }
        return false
    }

    /// `template` with the placeholders filled in, in one pass: what was heard may contain `{keyword}` or the like,
    /// and must come out as it was heard.
    static func message(from template: String, for hit: Hit) -> String {
        let values = [("{keyword}", hit.term), ("{text}", hit.matchedText), ("{context}", hit.context)]
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let rest = template[index...]
            if rest.first == "{", let (placeholder, value) = values.first(where: { rest.hasPrefix($0.0) }) {
                result += value
                index = template.index(index, offsetBy: placeholder.count)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }

    /// CallMeBot's address for the call. A user name gets an `@` in front unless it has one; a phone number starts
    /// with `+`.
    static func url(user: String, message: String, voice: String) -> URL? {
        var user = WireText.trimmed(user)
        if !user.hasPrefix("@") && !user.hasPrefix("+") { user = "@" + user }
        let query = [("user", user), ("text", message), ("lang", voice)]
            .map { "\($0.0)=\(WireText.queryValue($0.1))" }
            .joined(separator: "&")
        return URL(string: endpoint + "?" + query)
    }
}
