import Foundation
import os

/// A server inside the test process for the update lookup: each one has its own session, and a request is answered by
/// the server of the session it was sent through, so tests that run at the same time never see each other's requests.
final class UpdateStubServer: Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError?
        var isNotHTTP = false

        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
        static func failure(_ error: URLError) -> Reply { Reply(error: error) }
    }

    static let idHeader = "X-Update-Stub"

    let session: URLSession
    private let id = UUID().uuidString
    private let reply: Reply
    private let received = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    init(_ reply: Reply) {
        self.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.idHeader: id]
        session = URLSession(configuration: configuration)
        UpdateStubProtocol.register(self, id: id)
    }

    deinit {
        UpdateStubProtocol.unregister(id: id)
        session.invalidateAndCancel()
    }

    var requests: [URLRequest] { received.withLock { $0 } }

    func answer(_ request: URLRequest) -> Reply {
        received.withLock { $0.append(request) }
        return reply
    }
}

final class UpdateStubProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry: @unchecked Sendable { weak var server: UpdateStubServer? }
    private static let servers = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    static func register(_ server: UpdateStubServer, id: String) { servers.withLock { $0[id] = Entry(server: server) } }
    static func unregister(id: String) { servers.withLock { $0[id] = nil } }

    private static func server(for request: URLRequest) -> UpdateStubServer? {
        guard let id = request.value(forHTTPHeaderField: UpdateStubServer.idHeader) else { return nil }
        return servers.withLock { $0[id]?.server }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = server.answer(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response: URLResponse =
            reply.isNotHTTP
            ? URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
            : HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
