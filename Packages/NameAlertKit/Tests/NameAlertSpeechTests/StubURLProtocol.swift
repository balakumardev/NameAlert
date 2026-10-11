import Foundation
import os

/// A server that lives inside the test process. Each one answers at its own URL, so tests that run at the same time
/// never see each other's requests.
final class StubServer: Sendable {
    /// What the server sends back for one request.
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        /// The body, in the pieces it is sent in. (A URLSession keeps back the start of a body smaller than about
        /// 64 KB until the connection ends, so a test that needs bytes to arrive while it is still open sends more.)
        var chunks: [Data] = []
        /// Fail the connection after the last chunk, the way a dropped network does.
        var error: URLError?
        var hold = Hold.nothing

        /// Where the server waits for the test to call `release()`, to keep a download in flight.
        enum Hold: Sendable {
            case nothing
            /// Sends nothing until released.
            case beforeAnswer
            /// Sends the answer and the chunks, then keeps the connection open until released. A test that never
            /// releases leaves it open until the client gives up.
            case beforeEnd
        }

        static func ok(_ text: String) -> Reply { Reply(chunks: [Data(text.utf8)]) }
    }

    let url: URL
    /// A session whose only network is this stub.
    let session: URLSession

    private let makeReply: @Sendable (URLRequest) -> Reply
    private let seen = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private let gate = OSAllocatedUnfairLock(initialState: Gate())

    private struct Gate {
        var isOpen = false
        var waiting: [@Sendable () -> Void] = []
    }

    init(reply: @escaping @Sendable (URLRequest) -> Reply) {
        // `URL(string:)` only fails on a malformed string, and this one is built from a UUID.
        url = URL(string: "https://models.stub.test/\(UUID().uuidString)/model.bin")!
        makeReply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        StubURLProtocol.register(self)
    }

    func close() {
        StubURLProtocol.unregister(self)
        session.invalidateAndCancel()
        gate.withLock { $0.waiting = [] }
    }

    /// Every request the server got, in order.
    var requests: [URLRequest] { seen.withLock { $0 } }

    /// The `Range` header of each request, `nil` where there was none.
    var rangeHeaders: [String?] { requests.map { $0.value(forHTTPHeaderField: "Range") } }

    /// Lets the held answers go, and any that come later.
    func release() {
        let waiting = gate.withLock { gate -> [@Sendable () -> Void] in
            gate.isOpen = true
            defer { gate.waiting = [] }
            return gate.waiting
        }
        for deliver in waiting { deliver() }
    }

    // MARK: Used by the protocol

    func answer(_ request: URLRequest) -> Reply {
        seen.withLock { $0.append(request) }
        return makeReply(request)
    }

    /// Runs `deliver` now when the server is open, or as soon as `release()` opens it.
    func deliverWhenReleased(_ deliver: @escaping @Sendable () -> Void) {
        let runNow = gate.withLock { gate -> Bool in
            if gate.isOpen { return true }
            gate.waiting.append(deliver)
            return false
        }
        if runNow { deliver() }
    }

    // MARK: Ready-made servers

    /// The start of a `Range: bytes=<start>-` request, or nil when the request has none.
    static func rangeStart(of request: URLRequest) -> Int? {
        guard let value = request.value(forHTTPHeaderField: "Range"), value.hasPrefix("bytes="), value.hasSuffix("-")
        else { return nil }
        return Int(value.dropFirst("bytes=".count).dropLast())
    }

    /// The answer of a server that has `body` and honors `Range`: 206 with the rest, from `start` on.
    static func partialReply(of body: Data, from start: Int) -> Reply {
        Reply(
            status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
            chunks: [Data(body[start...])])
    }

    /// A server that has `body`. It honors `Range` unless told not to, in which case it sends everything with 200.
    static func serving(_ body: Data, honoringRange: Bool = true) -> @Sendable (URLRequest) -> Reply {
        { request in
            if honoringRange, let start = rangeStart(of: request) {
                return partialReply(of: body, from: start)
            }
            return Reply(chunks: [body])
        }
    }
}

/// Answers the requests of a `StubServer`'s session without touching the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock<[URL: StubServer]>(initialState: [:])

    static func register(_ server: StubServer) { servers.withLock { $0[server.url] = server } }
    static func unregister(_ server: StubServer) { servers.withLock { $0[server.url] = nil } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return servers.withLock { $0[url] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = server.answer(request)
        switch reply.hold {
        case .nothing:
            sendAnswer(reply, from: url)
            sendEnd(reply)
        case .beforeAnswer:
            server.deliverWhenReleased { [self] in
                sendAnswer(reply, from: url)
                sendEnd(reply)
            }
        case .beforeEnd:
            sendAnswer(reply, from: url)
            server.deliverWhenReleased { [self] in sendEnd(reply) }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    private func sendAnswer(_ reply: StubServer.Reply, from url: URL) {
        guard !isStopped,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            guard !isStopped else { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
    }

    private func sendEnd(_ reply: StubServer.Reply) {
        guard !isStopped else { return }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
