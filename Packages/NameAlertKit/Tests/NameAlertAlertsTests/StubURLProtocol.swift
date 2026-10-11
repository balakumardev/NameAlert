import Foundation
import os

/// A server that lives inside the test process. Each one has its own session, and a request is answered by the
/// server of the session it was sent through, so tests that run at the same time never see each other's requests.
final class StubServer: Sendable {
    /// What the server answers to one request.
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Fail the request the way a lost network does, instead of answering.
        var error: URLError?
        /// Answer with something that is not an HTTP response.
        var isNotHTTP = false
        /// Wait this long before answering. A cancelled request is not answered at all.
        var delay: TimeInterval = 0

        static func ok(_ text: String = "") -> Reply { Reply(body: Data(text.utf8)) }
        static func status(_ code: Int) -> Reply { Reply(status: code) }
        static func failure(_ error: URLError) -> Reply { Reply(error: error) }
    }

    /// A request as the server got it. (A body reaches a URL protocol as a stream, so it is read out here.)
    struct Received: Sendable {
        let request: URLRequest
        let body: Data

        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    /// The header that tells the protocol which server a request is for. The session adds it to every request.
    static let idHeader = "X-Stub-Server"

    /// A session whose only network is this server.
    let session: URLSession

    private let id: String
    private let replies: [Reply]
    private let received = OSAllocatedUnfairLock<[Received]>(initialState: [])

    /// The server answers with `replies` in turn, and with the last one for every request after that.
    init(_ replies: [Reply] = [.ok()]) {
        let id = UUID().uuidString
        self.id = id
        self.replies = replies.isEmpty ? [.ok()] : replies
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil  // the cache policy is left as it is, so that tests see what the client asked for
        configuration.httpAdditionalHeaders = [Self.idHeader: id]
        session = URLSession(configuration: configuration)
        StubURLProtocol.register(self, id: id)
    }

    convenience init(_ reply: Reply) { self.init([reply]) }

    deinit {
        StubURLProtocol.unregister(id: id)
        session.invalidateAndCancel()
    }

    /// Every request the server got, in order.
    var requests: [Received] { received.withLock { $0 } }
    var requestCount: Int { received.withLock { $0.count } }

    /// The one request the server got.
    var onlyRequest: Received? {
        let all = requests
        return all.count == 1 ? all[0] : nil
    }

    // MARK: Used by the protocol

    func answer(_ request: URLRequest) -> Reply {
        received.withLock { received in
            let index = received.count
            received.append(Received(request: request, body: StubServer.readBody(of: request)))
            return replies[min(index, replies.count - 1)]
        }
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Answers the requests of a `StubServer`'s session without touching the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// A server that is let go by its test is not kept alive by this list.
    private struct Entry: @unchecked Sendable {
        weak var server: StubServer?
    }
    private static let servers = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    static func register(_ server: StubServer, id: String) { servers.withLock { $0[id] = Entry(server: server) } }
    static func unregister(id: String) { servers.withLock { $0[id] = nil } }

    private static func server(for request: URLRequest) -> StubServer? {
        guard let id = request.value(forHTTPHeaderField: StubServer.idHeader) else { return nil }
        return servers.withLock { $0[id]?.server }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private var isStopped: Bool { stopped.withLock { $0 } }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = server.answer(request)
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in respond(reply, from: url) }
        } else {
            respond(reply, from: url)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func respond(_ reply: StubServer.Reply, from url: URL) {
        guard !isStopped else { return }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response: URLResponse =
            reply.isNotHTTP
            ? URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            : HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
