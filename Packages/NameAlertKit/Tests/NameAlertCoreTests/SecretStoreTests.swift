import Foundation
import NameAlertCore  // not @testable: these tests see only what other modules see
import Security
import Testing

@Suite("SecretStore")
struct SecretStoreTests {
    // MARK: Account names

    @Test func webhookHeaderAccount() {
        #expect(SecretAccount.webhookHeader("X-Token") == "webhook.header.X-Token")
        #expect(SecretAccount.webhookHeader("Authorization") == "webhook.header.Authorization")
    }

    @Test func fixedAccountNames() {
        // These strings are where users' secrets live in their Keychain. Changing one would orphan what is stored.
        #expect(SecretAccount.ntfyToken == "ntfy.token")
        #expect(SecretAccount.webhookSigningSecret == "webhook.signingSecret")
    }

    // MARK: InMemorySecretStore

    @Test func inMemorySetGetDelete() throws {
        let store = InMemorySecretStore()
        #expect(store.secret(for: "a") == nil)

        try store.setSecret("1", for: "a")
        #expect(store.secret(for: "a") == "1")

        try store.setSecret(nil, for: "a")
        #expect(store.secret(for: "a") == nil)

        // An empty string deletes too, so there is no such thing as a stored empty secret.
        try store.setSecret("1", for: "a")
        try store.setSecret("", for: "a")
        #expect(store.secret(for: "a") == nil)

        // Deleting what is not there is not an error.
        try store.setSecret(nil, for: "never-set")
        try store.setSecret("", for: "never-set")
        #expect(store.secret(for: "never-set") == nil)
    }

    @Test func inMemoryOverwriteKeepsAccountsApart() throws {
        let store = InMemorySecretStore()
        try store.setSecret("one", for: "a")
        try store.setSecret("other", for: "b")
        try store.setSecret("two", for: "a")  // overwrite
        #expect(store.secret(for: "a") == "two")
        #expect(store.secret(for: "b") == "other")

        try store.setSecret(nil, for: "a")
        #expect(store.secret(for: "a") == nil)
        #expect(store.secret(for: "b") == "other")  // deleting one account leaves the others alone
    }

    @Test func inMemoryStartsWithTheGivenValues() {
        // An empty value is "no secret", exactly as it would be after setSecret("").
        let store = InMemorySecretStore(["a": "1", "b": ""])
        #expect(store.secret(for: "a") == "1")
        #expect(store.secret(for: "b") == nil)
        #expect(store.secret(for: "c") == nil)
    }

    @Test func inMemoryStoreIsSafeToShareBetweenTasks() async throws {
        let store = InMemorySecretStore()
        let workers = 8
        let rounds = 2_000

        // Every worker reads and writes its own account and, at the same time, adds and removes keys that all the
        // workers share, so the dictionary inside keeps growing, shrinking and being read from several threads.
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    for round in 0..<rounds {
                        try? store.setSecret("w\(worker)-r\(round)", for: "own\(worker)")
                        _ = store.secret(for: "own\(worker)")
                        let shared = "shared\(round % 64)"
                        try? store.setSecret(round.isMultiple(of: 3) ? nil : "v\(worker)", for: shared)
                        _ = store.secret(for: shared)
                    }
                }
            }
        }

        // Nothing was lost or mixed up: each own account holds the last value its worker wrote.
        for worker in 0..<workers {
            #expect(store.secret(for: "own\(worker)") == "w\(worker)-r\(rounds - 1)")
        }
    }

    // MARK: KeychainSecretStore

    @Test func keychainErrorNamesTheStatus() {
        let error = KeychainError(status: errSecInteractionNotAllowed)
        #expect(error.status == -25_308)
        #expect(error.errorDescription?.contains("-25308") == true)
        #expect(error.localizedDescription.contains("-25308"))
    }

    /// Talks to the real Keychain, so it only runs when asked to: `NAMEALERT_INTEGRATION=1 swift test …`.
    ///
    /// It uses a service of its own (a new one on every run) and account names that no real secret uses, and it
    /// deletes everything it adds, even when a check fails halfway.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1",
        "Set NAMEALERT_INTEGRATION=1 to run against the real Keychain."
    ))
    func keychainRoundTrip() throws {
        let service = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let elsewhere = KeychainSecretStore(service: service + ".other")
        let first = "tests.first"
        let second = "tests.second"
        defer {
            try? store.setSecret(nil, for: first)
            try? store.setSecret(nil, for: second)
            try? elsewhere.setSecret(nil, for: first)
        }

        // Nothing there yet. Reading finds nothing, and deleting what is not there is not an error.
        #expect(store.secret(for: first) == nil)
        try store.setSecret(nil, for: first)
        try store.setSecret("", for: first)

        // Add.
        try store.setSecret("one", for: first)
        #expect(store.secret(for: first) == "one")

        // Overwrite: same item, new value. Not-ASCII text must come back as it went in.
        try store.setSecret("two — ünïcode ✓", for: first)
        #expect(store.secret(for: first) == "two — ünïcode ✓")

        // A second account is a separate item, and so is the same account under another service.
        try store.setSecret("other", for: second)
        try elsewhere.setSecret("elsewhere", for: first)
        #expect(store.secret(for: second) == "other")
        #expect(store.secret(for: first) == "two — ünïcode ✓")
        #expect(elsewhere.secret(for: first) == "elsewhere")

        // Delete with nil. Only that item goes.
        try store.setSecret(nil, for: first)
        #expect(store.secret(for: first) == nil)
        #expect(store.secret(for: second) == "other")
        #expect(elsewhere.secret(for: first) == "elsewhere")

        // Delete with an empty string, then once more with the item already gone.
        try store.setSecret("three", for: first)
        try store.setSecret("", for: first)
        #expect(store.secret(for: first) == nil)
        try store.setSecret(nil, for: first)

        // Clean up the rest, and check it is really gone.
        try store.setSecret(nil, for: second)
        try elsewhere.setSecret(nil, for: first)
        #expect(store.secret(for: second) == nil)
        #expect(elsewhere.secret(for: first) == nil)
    }
}
