import Foundation
import NameAlertCore

/// How often a request is tried and how long to wait between the tries.
public struct HTTPRetryPolicy: Sendable, Equatable {
    /// The most times the request is sent, the first time included.
    public let maxAttempts: Int
    /// The wait after the first failed attempt, after the second, and so on. When a policy needs more waits than it
    /// has delays, the last delay is used again.
    public let delays: [Duration]

    public init(maxAttempts: Int, delays: [Duration]) {
        self.maxAttempts = maxAttempts
        self.delays = delays
    }

    /// Three attempts, waiting 1 s and then 4 s.
    public static let webhook = HTTPRetryPolicy(maxAttempts: 3, delays: [.seconds(1), .seconds(4)])
    /// Two attempts, waiting 1 s.
    public static let ntfy = HTTPRetryPolicy(maxAttempts: 2, delays: [.seconds(1)])
    /// One attempt.
    public static let none = HTTPRetryPolicy(maxAttempts: 1, delays: [])

    /// The wait after attempt number `attempt` (counting from 1) has failed.
    func delay(afterAttempt attempt: Int) -> Duration {
        guard let last = delays.last else { return .zero }
        return delays.indices.contains(attempt - 1) ? delays[attempt - 1] : last
    }
}

/// Why an HTTP request did not give a successful answer, other than the network failing (that is a `URLError`).
public enum HTTPError: Error, Equatable {
    /// The server answered with this status, which is not a 2xx.
    case status(Int)
    /// The answer was not an HTTP response.
    case invalidResponse
}

extension HTTPError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .status(let code): "HTTP \(code)"
        case .invalidResponse: "The answer was not an HTTP response"
        }
    }

    public var errorDescription: String? { description }
}

/// Sends the HTTP requests of the alert channels: a time limit on each try, and tries again when the network or the
/// server is the problem.
///
/// A request is retried after a `URLError` (the network failed) and after a 5xx answer (the server failed), as often
/// as the policy allows, waiting between the tries. A 4xx answer is the request's fault and ends it at once, as does
/// any other status that is not a 2xx. A network error that another try cannot fix does not start one either: a
/// cancelled request, and a request that can never be made (a bad or unsupported address, a plain `http` address
/// that App Transport Security does not allow).
///
/// Cancelling the task that calls `send` ends the request and throws `CancellationError`, with no more tries.
///
/// Nothing about the request (not its address, headers or body) is logged.
public struct HTTPClient: Sendable {
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void
    private static let logger = Log.logger("network")

    /// - Parameter sleep: How the client waits between tries; tests replace it to see the waits without making them.
    public init(
        session: URLSession = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.sleep = sleep
    }

    /// Sends `request` and returns the first 2xx answer. `timeout` is the time limit on each try, and the answer
    /// is never taken from the cache.
    public func send(
        _ request: URLRequest, timeout: TimeInterval, retry: HTTPRetryPolicy
    ) async throws -> HTTPURLResponse {
        var request = request
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let attempts = max(retry.maxAttempts, 1)

        var attempt = 1
        while true {
            do {
                return try await sendOnce(request)
            } catch let error where Self.canBeFixedByTryingAgain(error) {
                guard attempt < attempts else { throw error }
                Self.logger.info("A request failed (\(Self.summary(of: error), privacy: .public)); trying again")
                try await sleep(retry.delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> HTTPURLResponse {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
            return http
        } catch let error as URLError {
            // URLSession reports a cancelled task as a URLError; callers should see the cancellation itself.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func canBeFixedByTryingAgain(_ error: any Error) -> Bool {
        if let error = error as? URLError { return !neverWorks.contains(error.code) }
        if let error = error as? HTTPError, case .status(let code) = error { return (500..<600).contains(code) }
        return false
    }

    private static let neverWorks: Set<URLError.Code> = [
        .cancelled, .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection,
    ]

    /// What can be said about a failed try in a log: a status or an error code, never the address.
    private static func summary(of error: any Error) -> String {
        if let error = error as? URLError { return "network error \(error.code.rawValue)" }
        return String(describing: error)
    }
}
