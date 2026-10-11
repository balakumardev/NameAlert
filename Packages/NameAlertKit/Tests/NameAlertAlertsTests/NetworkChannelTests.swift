import Foundation
import NameAlertAlerts  // not @testable: these tests see only what the app and the runtime see
import NameAlertCore
import Testing
import os

// MARK: - Helpers

/// The hit every test uses unless it says otherwise.
private func sampleHit(segmentID: String = "s1", term: String = "Bala", context: String = "…can Bala share the deck…")
    -> Hit
{
    Hit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        ruleID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, ruleName: "My name", term: term,
        matchedText: "Bala", context: context, timestamp: Date(timeIntervalSince1970: 1_760_175_000),
        source: .systemAudio, engine: .appleSpeechTranscriber, segmentID: segmentID)
}

/// The sleeps a client was asked to make, instead of making them.
private final class SleepLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    func record(_ duration: Duration) { storage.withLock { $0.append(duration) } }
    var durations: [Duration] { storage.withLock { $0 } }
}

private func client(_ server: StubServer, sleeps: SleepLog = SleepLog()) -> HTTPClient {
    HTTPClient(session: server.session, sleep: { sleeps.record($0) })
}

/// A clock the test moves by hand.
private final class TestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)
    private let elapsed = OSAllocatedUnfairLock(initialState: 0.0)

    var now: Date { Self.start.addingTimeInterval(elapsed.withLock { $0 }) }
    func set(to seconds: Double) { elapsed.withLock { $0 = seconds } }
}

private func request(_ address: String = "https://service.example/path") -> URLRequest {
    URLRequest(url: URL(string: address)!)
}

/// True once `condition` holds. Gives up after `timeout`, so a test that goes wrong fails instead of hanging.
private func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func webhookChannel(
    _ server: StubServer, sleeps: SleepLog = SleepLog(), now: @escaping @Sendable () -> Date = { Date() }
) -> WebhookChannel {
    WebhookChannel(client: client(server, sleeps: sleeps), appVersion: "1.0.0", build: "123", now: now)
}

private func webhookSettings(url: String = "https://hooks.example/alert", headerNames: [String] = [])
    -> ChannelSettings
{
    var settings = ChannelSettings()
    settings.webhook.url = url
    settings.webhook.headerNames = headerNames
    return settings
}

private func ntfySettings(server: String = "https://ntfy.example/", topic: String = "team", priority: NtfyPriority = .high)
    -> ChannelSettings
{
    var settings = ChannelSettings()
    settings.ntfy.server = server
    settings.ntfy.topic = topic
    settings.ntfy.priority = priority
    return settings
}

private func telegramSettings(user: String = "bala") -> ChannelSettings {
    var settings = ChannelSettings()
    settings.telegramCall.user = user
    return settings
}

private let noSecrets = InMemorySecretStore()

/// The query items of a URL, decoded.
private func queryItems(of request: URLRequest) -> [String: String] {
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
    return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private let expectedBody =
    #"{"app":{"build":"123","version":"1.0.0"},"context":"…can Bala share the deck…","engine":"appleSpeechTranscriber","event":"keyword.detected","id":"00000000-0000-0000-0000-000000000001","matchedText":"Bala","rule":{"id":"00000000-0000-0000-0000-0000000000AA","name":"My name"},"source":"systemAudio","term":"Bala","timestamp":"2025-10-11T09:30:00Z","version":1}"#

// MARK: - Tests

@Suite("NetworkChannels", .timeLimit(.minutes(1)))
struct NetworkChannelsTests {
    // MARK: Webhook payload

    @Test func webhookBodyExact() throws {
        let body = try WebhookPayload.body(for: sampleHit(), event: "keyword.detected", appVersion: "1.0.0", build: "123")
        #expect(String(decoding: body, as: UTF8.self) == expectedBody)
    }

    @Test func webhookBodyKeepsSlashesAndDropsFractionalSeconds() throws {
        let hit = Hit(
            ruleID: UUID(), ruleName: "Links", term: "deck", matchedText: "deck", context: "see https://a.example/b/c",
            timestamp: Date(timeIntervalSince1970: 1_760_175_000.789), source: .both, engine: .whisperLight,
            segmentID: "s9")

        let text = String(
            decoding: try WebhookPayload.body(for: hit, event: "test", appVersion: "2", build: "7"), as: UTF8.self)

        #expect(text.contains(#""context":"see https://a.example/b/c""#))  // no \/
        #expect(text.contains(#""timestamp":"2025-10-11T09:30:00Z""#))
        #expect(text.contains(#""event":"test""#))
        #expect(text.contains(#""source":"both""#) && text.contains(#""engine":"whisperLight""#))
    }

    @Test func signatureKnownAnswer() {
        let header = WebhookPayload.signatureHeader(
            body: Data(#"{"a":1}"#.utf8), secret: "s3cret", timestamp: 1_700_000_000)
        #expect(header == "t=1700000000,v1=1698a50bc74d1ff1db85c4e0a5297c2ad9fdba245d5737cdb789e4cc6e098940")
    }

    // MARK: HTTP client

    @Test func retryPoliciesAreAsSpecified() {
        #expect(HTTPRetryPolicy.webhook.maxAttempts == 3)
        #expect(HTTPRetryPolicy.webhook.delays == [.seconds(1), .seconds(4)])
        #expect(HTTPRetryPolicy.ntfy.maxAttempts == 2)
        #expect(HTTPRetryPolicy.ntfy.delays == [.seconds(1)])
        #expect(HTTPRetryPolicy.none.maxAttempts == 1)
    }

    @Test func retriesOn5xxThenSucceeds() async throws {
        let server = StubServer([.status(500), .status(500), .status(200)])
        let sleeps = SleepLog()

        let response = try await client(server, sleeps: sleeps).send(request(), timeout: 5, retry: .webhook)

        #expect(response.statusCode == 200)
        #expect(server.requestCount == 3)
        #expect(sleeps.durations == [.seconds(1), .seconds(4)])
    }

    @Test func noRetryOn4xx() async {
        let server = StubServer(.status(400))
        let sleeps = SleepLog()

        await #expect(throws: HTTPError.status(400)) {
            try await client(server, sleeps: sleeps).send(request(), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func networkErrorExhausts() async {
        let server = StubServer(.failure(URLError(.notConnectedToInternet)))
        let sleeps = SleepLog()

        await #expect(throws: URLError.self) {
            try await client(server, sleeps: sleeps).send(request(), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 3)
        #expect(sleeps.durations == [.seconds(1), .seconds(4)])
    }

    @Test func aServerThatKeepsFailingEndsInItsStatus() async {
        let server = StubServer(.status(503))

        await #expect(throws: HTTPError.status(503)) {
            try await client(server).send(request(), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 3)
    }

    @Test func aNetworkErrorThatCannotGetBetterIsNotRetried() async {
        let server = StubServer(.failure(URLError(.appTransportSecurityRequiresSecureConnection)))
        let sleeps = SleepLog()

        await #expect(throws: URLError.self) {
            try await client(server, sleeps: sleeps).send(request("http://plain.example/"), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func aPolicyWithoutRetriesTriesOnce() async {
        let server = StubServer(.status(500))
        let sleeps = SleepLog()

        await #expect(throws: HTTPError.status(500)) {
            try await client(server, sleeps: sleeps).send(request(), timeout: 5, retry: .none)
        }

        #expect(server.requestCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func theLastDelayIsReusedWhenThePolicyHasFewer() async {
        let server = StubServer(.status(502))
        let sleeps = SleepLog()
        let policy = HTTPRetryPolicy(maxAttempts: 4, delays: [.seconds(2)])

        await #expect(throws: HTTPError.status(502)) {
            try await client(server, sleeps: sleeps).send(request(), timeout: 5, retry: policy)
        }

        #expect(server.requestCount == 4)
        #expect(sleeps.durations == [.seconds(2), .seconds(2), .seconds(2)])
    }

    @Test func everyRequestCarriesTheTimeoutAndSkipsTheCache() async throws {
        let server = StubServer([.status(500), .status(204)])

        let response = try await client(server).send(request(), timeout: 7, retry: .ntfy)

        #expect(response.statusCode == 204)  // any 2xx is success
        #expect(server.requests.map(\.request.timeoutInterval) == [7, 7])
        #expect(server.requests.allSatisfy { $0.request.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    @Test func anAnswerThatIsNotHTTPIsRejected() async {
        let server = StubServer(StubServer.Reply(isNotHTTP: true))

        await #expect(throws: HTTPError.invalidResponse) {
            try await client(server).send(request(), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 1)
    }

    @Test func aRedirectWithoutATargetIsNotASuccess() async {
        let server = StubServer(.status(304))

        await #expect(throws: HTTPError.status(304)) {
            try await client(server).send(request(), timeout: 5, retry: .webhook)
        }

        #expect(server.requestCount == 1)
    }

    @Test func aCancelledSendStopsWithoutRetrying() async {
        let server = StubServer(StubServer.Reply(delay: 30))
        let sleeps = SleepLog()
        let http = client(server, sleeps: sleeps)

        let task = Task { try await http.send(request(), timeout: 60, retry: .webhook) }
        #expect(await eventually { server.requestCount == 1 })
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requestCount == 1)
        #expect(sleeps.durations.isEmpty)
    }

    @Test func httpErrorsReadAsPlainWords() {
        #expect(String(describing: HTTPError.status(404)) == "HTTP 404")
        #expect(HTTPError.status(404).localizedDescription == "HTTP 404")
        #expect(HTTPError.invalidResponse.localizedDescription.isEmpty == false)
    }

    // MARK: Webhook channel

    @Test func webhookHeaders() async throws {
        let server = StubServer()
        let secrets = InMemorySecretStore([
            SecretAccount.webhookSigningSecret: "s3cret", SecretAccount.webhookHeader("X-Token"): "abc",
        ])

        try await webhookChannel(server).deliver(
            sampleHit(), settings: webhookSettings(headerNames: ["X-Token"]), secrets: secrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.header("X-Token") == "abc")
        #expect(sent.header("X-NameAlert-Event") == "keyword.detected")
        #expect(sent.header("X-NameAlert-Signature")?.hasPrefix("t=") == true)
    }

    @Test func webhookRequestShape() async throws {
        let server = StubServer()

        try await webhookChannel(server).deliver(sampleHit(), settings: webhookSettings(), secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://hooks.example/alert")
        #expect(sent.header("Content-Type") == "application/json")
        #expect(sent.header("User-Agent") == "NameAlert/1.0.0")
        #expect(sent.request.timeoutInterval == 5)
        #expect(sent.bodyText == expectedBody)
        #expect(sent.header("X-NameAlert-Signature") == nil)  // no signing secret, no signature
    }

    @Test func webhookEventIsTestForTheSampleHit() async throws {
        let server = StubServer()

        try await webhookChannel(server).deliver(
            sampleHit(segmentID: "test"), settings: webhookSettings(), secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.header("X-NameAlert-Event") == "test")
        #expect(sent.bodyText.contains(#""event":"test""#))
    }

    @Test func webhookSignatureCoversTheBodyThatWasSent() async throws {
        let server = StubServer()
        let secrets = InMemorySecretStore([SecretAccount.webhookSigningSecret: "s3cret"])
        let now = Date(timeIntervalSince1970: 1_700_000_000.9)

        try await webhookChannel(server, now: { now }).deliver(
            sampleHit(), settings: webhookSettings(), secrets: secrets)

        let sent = try #require(server.onlyRequest)
        #expect(
            sent.header("X-NameAlert-Signature")
                == WebhookPayload.signatureHeader(body: sent.body, secret: "s3cret", timestamp: 1_700_000_000))
    }

    @Test func webhookSkipsHeaderNamesWithoutAValue() async throws {
        let server = StubServer()
        let secrets = InMemorySecretStore([SecretAccount.webhookHeader("X-Token"): "abc"])

        try await webhookChannel(server).deliver(
            sampleHit(), settings: webhookSettings(headerNames: ["X-Token", "X-Missing"]), secrets: secrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.header("X-Token") == "abc")
        #expect(sent.header("X-Missing") == nil)
    }

    @Test func webhookUsesTheTrimmedAddress() async throws {
        let server = StubServer()

        try await webhookChannel(server).deliver(
            sampleHit(), settings: webhookSettings(url: "  https://hooks.example/alert \n"), secrets: noSecrets)

        #expect(server.onlyRequest?.request.url?.absoluteString == "https://hooks.example/alert")
    }

    @Test func webhookRetriesServerErrors() async throws {
        let server = StubServer([.status(500), .status(200)])
        let sleeps = SleepLog()

        try await webhookChannel(server, sleeps: sleeps).deliver(
            sampleHit(), settings: webhookSettings(), secrets: noSecrets)

        #expect(server.requestCount == 2)
        #expect(sleeps.durations == [.seconds(1)])
    }

    @Test func webhookDoesNotRetryAClientError() async {
        let server = StubServer(.status(404))

        await #expect(throws: HTTPError.status(404)) {
            try await webhookChannel(server).deliver(sampleHit(), settings: webhookSettings(), secrets: noSecrets)
        }

        #expect(server.requestCount == 1)
    }

    @Test func webhookWithoutAUsableAddressThrowsBeforeAnyRequest() async {
        let server = StubServer()

        for address in ["", "   ", "ftp://hooks.example/x", "not a url"] {
            await #expect(throws: AlertDeliveryError.notConfigured(.webhook)) {
                try await webhookChannel(server).deliver(
                    sampleHit(), settings: webhookSettings(url: address), secrets: noSecrets)
            }
        }
        #expect(server.requestCount == 0)
    }

    // MARK: ntfy channel

    @Test func ntfyRequest() async throws {
        let server = StubServer()
        let secrets = InMemorySecretStore([SecretAccount.ntfyToken: "tk_secret"])

        try await NtfyChannel(client: client(server)).deliver(sampleHit(), settings: ntfySettings(), secrets: secrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.request.url?.absoluteString == "https://ntfy.example/team")
        #expect(sent.header("Title") == "Heard “Bala”")
        #expect(sent.header("Priority") == "high")
        #expect(sent.header("Authorization") == "Bearer tk_secret")
    }

    @Test func ntfyRequestShape() async throws {
        let server = StubServer()

        try await NtfyChannel(client: client(server)).deliver(sampleHit(), settings: ntfySettings(), secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.bodyText == "…can Bala share the deck…")
        #expect(sent.header("Content-Type") == "text/plain; charset=utf-8")
        #expect(sent.header("Tags") == "ear")
        #expect(sent.header("Authorization") == nil)  // no token, no Authorization
        #expect(sent.request.timeoutInterval == 5)
    }

    /// URLSession cuts a header value at a curly quote (HTTP/1.1) or drops the header (HTTP/2), and the title has
    /// curly quotes. ntfy reads `X-Title` before `Title` and decodes RFC 2047 words.
    @Test func ntfyTitleAlsoTravelsAsAnEncodedWord() async throws {
        let server = StubServer()

        try await NtfyChannel(client: client(server)).deliver(sampleHit(), settings: ntfySettings(), secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        #expect(sent.header("X-Title") == "=?UTF-8?B?SGVhcmQg4oCcQmFsYeKAnQ==?=")  // Heard “Bala”
    }

    @Test func ntfyPriorityFollowsTheSetting() async throws {
        for priority in NtfyPriority.allCases {
            let server = StubServer()
            try await NtfyChannel(client: client(server)).deliver(
                sampleHit(), settings: ntfySettings(priority: priority), secrets: noSecrets)
            #expect(server.onlyRequest?.header("Priority") == priority.rawValue)
        }
    }

    @Test func ntfyJoinsServerAndTopicWithOneSlash() async throws {
        let rows: [(server: String, topic: String, expected: String)] = [
            ("https://ntfy.example", "team", "https://ntfy.example/team"),
            ("https://ntfy.example/", "team", "https://ntfy.example/team"),
            ("https://ntfy.example/base", "team", "https://ntfy.example/base/team"),
            ("https://ntfy.example/base//", "team", "https://ntfy.example/base/team"),
            ("  https://ntfy.example:8443/ \n", " team\t", "https://ntfy.example:8443/team"),
            ("https://ntfy.example/", "/team", "https://ntfy.example/team"),
            ("http://192.168.1.5:8080", "my topic", "http://192.168.1.5:8080/my%20topic"),
        ]
        for row in rows {
            let server = StubServer()
            try await NtfyChannel(client: client(server)).deliver(
                sampleHit(), settings: ntfySettings(server: row.server, topic: row.topic), secrets: noSecrets)
            #expect(server.onlyRequest?.request.url?.absoluteString == row.expected, "for \(row.server) + \(row.topic)")
        }
    }

    @Test func ntfyRetriesOnce() async throws {
        let recovering = StubServer([.status(500), .status(200)])
        let sleeps = SleepLog()
        try await NtfyChannel(client: client(recovering, sleeps: sleeps)).deliver(
            sampleHit(), settings: ntfySettings(), secrets: noSecrets)
        #expect(recovering.requestCount == 2)
        #expect(sleeps.durations == [.seconds(1)])

        let failing = StubServer(.status(500))
        await #expect(throws: HTTPError.status(500)) {
            try await NtfyChannel(client: client(failing)).deliver(
                sampleHit(), settings: ntfySettings(), secrets: noSecrets)
        }
        #expect(failing.requestCount == 2)  // two attempts, not three
    }

    @Test func ntfyWithoutATopicOrAUsableServerThrowsBeforeAnyRequest() async {
        let server = StubServer()

        await #expect(throws: AlertDeliveryError.notConfigured(.ntfy)) {
            try await NtfyChannel(client: client(server)).deliver(
                sampleHit(), settings: ntfySettings(topic: " "), secrets: noSecrets)
        }
        for address in ["", "ntfy.example", "ftp://ntfy.example"] {
            await #expect(throws: AlertDeliveryError.invalidAddress(.ntfy)) {
                try await NtfyChannel(client: client(server)).deliver(
                    sampleHit(), settings: ntfySettings(server: address), secrets: noSecrets)
            }
        }
        #expect(server.requestCount == 0)
    }

    @Test func ntfyTitleHoldsAnyTermIntact() async throws {
        let term = "Bālakumar 🙂 " + String(repeating: "very long name ", count: 12)
        let server = StubServer()

        try await NtfyChannel(client: client(server)).deliver(
            sampleHit(term: term), settings: ntfySettings(), secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        let encoded = try #require(sent.header("X-Title"))
        #expect(encoded.allSatisfy { $0.isASCII })
        // Every encoded word is short enough for a header line, and together they read back as the title.
        let words = encoded.split(separator: " ")
        #expect(words.allSatisfy { $0.count <= 75 && $0.hasPrefix("=?UTF-8?B?") && $0.hasSuffix("?=") })
        let decoded = words.map { word -> String in
            let base64 = word.dropFirst("=?UTF-8?B?".count).dropLast(2)
            return String(decoding: Data(base64Encoded: String(base64)) ?? Data(), as: UTF8.self)
        }.joined()
        #expect(decoded == "Heard “\(term)”")
    }

    // MARK: Telegram call channel

    @Test func telegramRateLimit() async throws {
        let server = StubServer()
        let clock = TestClock()
        let channel = TelegramCallChannel(client: client(server), now: { clock.now })
        let hit = sampleHit()

        clock.set(to: 0)
        try await channel.deliver(hit, settings: telegramSettings(), secrets: noSecrets)
        clock.set(to: 10)
        try await channel.deliver(hit, settings: telegramSettings(), secrets: noSecrets)  // too soon: no request
        #expect(server.requestCount == 1)

        clock.set(to: 61)  // a minute after the call, whatever happened in between
        try await channel.deliver(hit, settings: telegramSettings(), secrets: noSecrets)
        #expect(server.requestCount == 2)

        let query = queryItems(of: try #require(server.requests.first).request)
        #expect(query["user"] == "@bala")
        #expect(query["text"]?.contains("Bala") == true)
    }

    @Test func telegramRequestShape() async throws {
        let server = StubServer()
        var settings = telegramSettings()
        settings.telegramCall.voice = "en-GB-Standard-A"

        try await TelegramCallChannel(client: client(server)).deliver(sampleHit(), settings: settings, secrets: noSecrets)

        let sent = try #require(server.onlyRequest)
        let url = try #require(sent.request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(sent.request.httpMethod == "GET")
        #expect(components.scheme == "https" && components.host == "api.callmebot.com")
        #expect(components.path == "/start.php")
        #expect(components.queryItems?.map(\.name) == ["user", "text", "lang"])
        let query = queryItems(of: sent.request)
        #expect(query["lang"] == "en-GB-Standard-A")
        #expect(query["text"] == "NameAlert heard Bala: …can Bala share the deck…")  // the default template
        #expect(sent.request.timeoutInterval == 10)
    }

    @Test func telegramUserForms() async throws {
        let rows: [(user: String, sent: String, rawQuery: String)] = [
            ("bala", "@bala", "user=@bala&"),
            ("@bala", "@bala", "user=@bala&"),
            ("  +15551234567 \n", "+15551234567", "user=%2B15551234567&"),  // a plus must not read as a space
        ]
        for row in rows {
            let server = StubServer()
            try await TelegramCallChannel(client: client(server)).deliver(
                sampleHit(), settings: telegramSettings(user: row.user), secrets: noSecrets)
            let sent = try #require(server.onlyRequest).request
            #expect(queryItems(of: sent)["user"] == row.sent)
            #expect(sent.url?.query?.hasPrefix(row.rawQuery) == true, "for \(row.user)")
        }
    }

    @Test func telegramFillsTheTemplateOnce() async throws {
        let server = StubServer()
        var settings = telegramSettings()
        settings.telegramCall.messageTemplate = "{keyword} / {text} / {context} / {other} / {keyword}"
        // A transcript can hold braces: what was heard must come out as it is, not be filled in again.
        let hit = sampleHit(term: "Bala", context: "say {keyword} & {text} 100% + more")

        try await TelegramCallChannel(client: client(server)).deliver(hit, settings: settings, secrets: noSecrets)

        let text = queryItems(of: try #require(server.onlyRequest).request)["text"]
        #expect(text == "Bala / Bala / say {keyword} & {text} 100% + more / {other} / Bala")
    }

    @Test func telegramFailureDoesNotUseUpTheMinute() async throws {
        let server = StubServer([.status(500), .status(200)])
        let clock = TestClock()
        let channel = TelegramCallChannel(client: client(server), now: { clock.now })

        clock.set(to: 0)
        await #expect(throws: HTTPError.status(500)) {
            try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        }
        clock.set(to: 5)
        try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        #expect(server.requestCount == 2)  // one try each: this channel never retries by itself
        #expect(server.requests.map(\.request.timeoutInterval) == [10, 10])

        clock.set(to: 20)
        try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        #expect(server.requestCount == 2)  // the call that went through at 5 s holds the minute
    }

    @Test func telegramNoNetworkDoesNotUseUpTheMinute() async throws {
        let server = StubServer([.failure(URLError(.notConnectedToInternet)), .status(200)])
        let clock = TestClock()
        let channel = TelegramCallChannel(client: client(server), now: { clock.now })

        clock.set(to: 0)
        await #expect(throws: URLError.self) {
            try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        }
        clock.set(to: 5)
        try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)

        #expect(server.requestCount == 2)  // nothing was sent the first time, so the second hit may call
    }

    @Test func telegramATimedOutRequestKeepsTheMinute() async throws {
        // The service may have placed the call before the answer was lost, so a second one a moment later is held back.
        let server = StubServer([.failure(URLError(.timedOut)), .status(200)])
        let clock = TestClock()
        let channel = TelegramCallChannel(client: client(server), now: { clock.now })

        clock.set(to: 0)
        await #expect(throws: URLError.self) {
            try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        }
        clock.set(to: 5)
        try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        #expect(server.requestCount == 1)

        clock.set(to: 61)
        try await channel.deliver(sampleHit(), settings: telegramSettings(), secrets: noSecrets)
        #expect(server.requestCount == 2)
    }

    @Test func telegramWithoutAUserThrowsBeforeAnyRequest() async {
        let server = StubServer()

        await #expect(throws: AlertDeliveryError.notConfigured(.telegramCall)) {
            try await TelegramCallChannel(client: client(server)).deliver(
                sampleHit(), settings: telegramSettings(user: "  "), secrets: noSecrets)
        }
        #expect(server.requestCount == 0)
    }

    // MARK: Kinds

    @Test func channelsReportTheirKind() {
        #expect(NtfyChannel().kind == .ntfy)
        #expect(TelegramCallChannel().kind == .telegramCall)
        #expect(WebhookChannel(appVersion: "1", build: "1").kind == .webhook)
    }
}
