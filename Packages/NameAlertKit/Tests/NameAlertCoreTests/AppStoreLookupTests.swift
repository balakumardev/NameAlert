import Foundation
import NameAlertCore
import Testing

@Suite("App Store lookup")
struct AppStoreLookupTests {
    private let full = """
        {"resultCount":1,"results":[{"version":"1.2.0","minimumOsVersion":"14.0",\
        "currentVersionReleaseDate":"2026-10-20T07:00:00Z","releaseNotes":"• Faster.",\
        "trackViewUrl":"https://apps.apple.com/us/app/takeheed/id123?mt=12","bundleId":"dev.balakumar.namealert"}]}
        """

    // MARK: Parsing

    @Test func parsesEveryField() throws {
        guard case .release(let release) = AppStoreLookupClient.outcome(of: Data(full.utf8)) else {
            Issue.record("expected a release")
            return
        }
        #expect(release.version == "1.2.0")
        #expect(release.minimumOSVersion == "14.0")
        #expect(release.releaseDate == ISO8601DateFormatter().date(from: "2026-10-20T07:00:00Z"))
        #expect(release.releaseNotes == "• Faster.")
        #expect(release.storeURL?.host == "apps.apple.com")
    }

    @Test func missingOptionalFieldsStillGiveARelease() {
        let json = #"{"resultCount":1,"results":[{"version":"1.2.0"}]}"#
        #expect(
            AppStoreLookupClient.outcome(of: Data(json.utf8))
                == .release(
                    AppStoreRelease(
                        version: "1.2.0", minimumOSVersion: nil, releaseDate: nil, releaseNotes: nil, storeURL: nil)))
    }

    @Test func aBadDateIsNoDate() {
        let json = #"{"resultCount":1,"results":[{"version":"1.2.0","currentVersionReleaseDate":"yesterday"}]}"#
        guard case .release(let release) = AppStoreLookupClient.outcome(of: Data(json.utf8)) else {
            Issue.record("expected a release")
            return
        }
        #expect(release.releaseDate == nil)
    }

    @Test func fractionalSecondsAreAccepted() {
        let json = #"{"resultCount":1,"results":[{"version":"1.2.0","currentVersionReleaseDate":"2026-10-20T07:00:00.123Z"}]}"#
        guard case .release(let release) = AppStoreLookupClient.outcome(of: Data(json.utf8)) else {
            Issue.record("expected a release")
            return
        }
        #expect(release.releaseDate != nil)
    }

    @Test func noResultsMeansNotOnSale() {
        #expect(AppStoreLookupClient.outcome(of: Data(#"{"resultCount":0,"results":[]}"#.utf8)) == .notOnSale)
    }

    @Test func unreadableAnswersFail() {
        let bad = [
            "", "not json", "[]", "{}", #"{"resultCount":1}"#, #"{"resultCount":1,"results":[{}]}"#,
            #"{"resultCount":1,"results":[{"version":""}]}"#, #"{"resultCount":1,"results":[{"version":3}]}"#,
            #"{"resultCount":1,"results":["x"]}"#,
        ]
        for text in bad {
            #expect(AppStoreLookupClient.outcome(of: Data(text.utf8)) == .failed, "\(text)")
        }
    }

    // MARK: The request

    @Test func theAddressNamesOnlyTheBundle() {
        let url = AppStoreLookupClient.lookupURL()
        #expect(url.absoluteString == "https://itunes.apple.com/lookup?bundleId=dev.balakumar.namealert&entity=macSoftware")
    }

    @Test func theRequestCarriesNothingAboutThePerson() async throws {
        let server = UpdateStubServer(.json(full))
        _ = await AppStoreLookupClient(transport: server.session).lookup()
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        #expect(request.url == AppStoreLookupClient.lookupURL())
        #expect(request.timeoutInterval == 15)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func theSessionKeepsNothing() {
        let configuration = AppStoreLookupClient.makeSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }

    // MARK: Over a session

    @Test func aGoodAnswerGivesTheRelease() async {
        let server = UpdateStubServer(.json(full))
        let release = await AppStoreLookupClient(transport: server.session).latestRelease()
        #expect(release?.version == "1.2.0")
    }

    @Test func noResultsIsNotOnSale() async {
        let server = UpdateStubServer(.json(#"{"resultCount":0,"results":[]}"#))
        let client = AppStoreLookupClient(transport: server.session)
        #expect(await client.lookup() == .notOnSale)
        #expect(await client.latestRelease() == nil)
    }

    @Test func httpErrorsFail() async {
        for status in [400, 403, 404, 429, 500, 503] {
            let server = UpdateStubServer(.json(full, status: status))
            #expect(await AppStoreLookupClient(transport: server.session).lookup() == .failed, "\(status)")
        }
    }

    @Test func aTimeoutOrLostNetworkFails() async {
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost] {
            let server = UpdateStubServer(.failure(URLError(code)))
            #expect(await AppStoreLookupClient(transport: server.session).lookup() == .failed, "\(code)")
        }
    }

    @Test func aMalformedAnswerFails() async {
        let server = UpdateStubServer(.json("<html>nope</html>"))
        #expect(await AppStoreLookupClient(transport: server.session).lookup() == .failed)
    }

    @Test func anAnswerThatIsNotHTTPFails() async {
        var reply = UpdateStubServer.Reply.json(full)
        reply.isNotHTTP = true
        let server = UpdateStubServer(reply)
        #expect(await AppStoreLookupClient(transport: server.session).lookup() == .failed)
    }

    @Test func theTimeoutGivenToTheClientIsTheRequestsTimeout() async throws {
        let server = UpdateStubServer(.json(full))
        _ = await AppStoreLookupClient(transport: server.session, timeout: 3).lookup()
        #expect(try #require(server.requests.first).timeoutInterval == 3)
    }
}

@Suite("Update store link")
struct UpdateStoreLinkTests {
    private func release(_ url: String?) -> AppStoreRelease {
        AppStoreRelease(
            version: "1.2.0", minimumOSVersion: nil, releaseDate: nil, releaseNotes: nil, storeURL: url.flatMap { URL(string: $0) })
    }

    @Test func opensTheStorePageTheLookupNamed() {
        let page = "https://apps.apple.com/us/app/takeheed/id123?mt=12"
        #expect(UpdateStoreLink.pageURL(for: release(page)).absoluteString == page)
        #expect(UpdateStoreLink.pageURL(for: release("https://itunes.apple.com/us/app/id123")).host == "itunes.apple.com")
    }

    @Test func anythingElseFallsBackToTheUpdatesTab() {
        for text in [nil, "http://apps.apple.com/app/id1", "https://evil.example/app/id1", "file:///etc/passwd",
            "https://apps.apple.com.evil.example/x", "macappstore://apps.apple.com/app/id1"]
        {
            #expect(UpdateStoreLink.pageURL(for: release(text)) == UpdateStoreLink.updatesPage, "\(text ?? "nil")")
        }
    }
}
