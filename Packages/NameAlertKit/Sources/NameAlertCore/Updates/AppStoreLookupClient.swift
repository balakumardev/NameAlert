import Foundation

/// How the lookup client reaches the network; a `URLSession` is one, and tests bring their own.
public protocol UpdateLookupTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateLookupTransport {}

/// What a lookup found.
public enum AppStoreLookupOutcome: Equatable, Sendable {
    case release(AppStoreRelease)
    /// Apple answered, and has no such app: it is not on sale yet (or not in this storefront).
    case notOnSale
    /// No network, a timeout, a bad status or an answer that cannot be read.
    case failed
}

/// Asks `itunes.apple.com/lookup` for Takeheed's current version. The request is a plain GET with the bundle ID in the
/// address: no body, no headers of ours, no cookies, nothing that names the person, the Mac or the install. It is the
/// only request the update check makes, and nothing about it is logged.
public struct AppStoreLookupClient: Sendable {
    public static let bundleID = "dev.balakumar.namealert"

    private let transport: any UpdateLookupTransport
    private let timeout: TimeInterval

    public init(
        transport: any UpdateLookupTransport = AppStoreLookupClient.makeSession(),
        timeout: TimeInterval = UpdateCheckConfiguration.standard.requestTimeout
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    /// A session that keeps nothing: no cookies, no cache, no credentials.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public static func lookupURL(bundleID: String = AppStoreLookupClient.bundleID) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "macSoftware"),
        ]
        return components.url!
    }

    static func request(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: lookupURL(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    public func lookup() async -> AppStoreLookupOutcome {
        do {
            let (data, response) = try await transport.data(for: Self.request(timeout: timeout))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed
            }
            return Self.outcome(of: data)
        } catch {
            return .failed
        }
    }

    /// The newest release, or nil when there is none to report (not on sale yet) or the lookup failed.
    public func latestRelease() async -> AppStoreRelease? {
        if case .release(let release) = await lookup() { return release }
        return nil
    }

    // MARK: Parsing

    private struct Response: Decodable {
        let resultCount: Int?
        let results: [Item]?

        struct Item: Decodable {
            let version: String?
            let minimumOsVersion: String?
            let currentVersionReleaseDate: String?
            let releaseNotes: String?
            let trackViewUrl: String?
        }
    }

    public static func outcome(of data: Data) -> AppStoreLookupOutcome {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .failed }
        let results = response.results ?? []
        guard let item = results.first else { return response.resultCount == 0 ? .notOnSale : .failed }
        guard let version = item.version?.trimmingCharacters(in: .whitespaces), !version.isEmpty else {
            return .failed
        }
        return .release(
            AppStoreRelease(
                version: version,
                minimumOSVersion: item.minimumOsVersion,
                releaseDate: item.currentVersionReleaseDate.flatMap(parseDate),
                releaseNotes: item.releaseNotes,
                storeURL: item.trackViewUrl.flatMap { URL(string: $0) }))
    }

    /// Apple writes "2026-10-20T07:00:00Z"; fractional seconds are accepted too.
    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
