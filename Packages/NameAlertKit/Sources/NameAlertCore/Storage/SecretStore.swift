import Foundation
import os
import Security

/// Where NameAlert keeps the few values that must never sit in `config.json`: the ntfy token, the webhook signing
/// secret and the values of custom webhook headers.
///
/// An empty string is the same as no secret. Setting `nil` or `""` deletes, and `secret(for:)` never returns `""`.
public protocol SecretStore: Sendable {
    /// The secret stored under `account`, or `nil` when there is none or it cannot be read right now.
    func secret(for account: String) -> String?

    /// Stores `value` under `account` and replaces what was there. `nil` or `""` deletes it; deleting a secret that
    /// does not exist is not an error.
    func setSecret(_ value: String?, for account: String) throws
}

/// The account names NameAlert stores its secrets under. These strings are where the user's secrets live in the
/// Keychain, so they must not change.
public enum SecretAccount {
    public static let ntfyToken = "ntfy.token"
    public static let webhookSigningSecret = "webhook.signingSecret"

    /// One account per custom webhook header: the header's *name* is kept in the configuration, its value here.
    public static func webhookHeader(_ name: String) -> String {
        "webhook.header.\(name)"
    }
}

/// A Keychain call failed. `status` is the `OSStatus` it returned, for example -25308
/// (`errSecInteractionNotAllowed`: the keychain is locked and cannot ask the user to unlock it).
///
/// It carries a number and the system's message for it, never a secret or an account name.
public struct KeychainError: Error, Equatable, Sendable, LocalizedError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "Keychain error \(status): \(message)"
        }
        return "Keychain error \(status)"
    }
}

/// Keeps secrets in the user's keychain as generic-password items: one item per account, all under one `service`.
///
/// This is the default, file-based keychain. The data-protection keychain (`kSecUseDataProtectionKeychain`) is
/// left out on purpose: it needs a `keychain-access-groups` entitlement, which this app does not have.
///
/// Reading never throws. A missing item, and any Keychain failure, give `nil`; a failure is also logged (its
/// status number only, never an account or a value). Writing throws `KeychainError` when the Keychain refuses.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let logger = Log.logger("secrets")

    public init(service: String = "dev.balakumar.namealert") {
        self.service = service
    }

    public func secret(for account: String) -> String? {
        var query = itemQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Could not read a secret from the Keychain (status \(status, privacy: .public))")
            return nil
        }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        guard let value, !value.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)

        // Update first. Only when there is no such item yet, add it.
        let newValue = [kSecValueData as String: data]
        let updated = SecItemUpdate(itemQuery(for: account) as CFDictionary, newValue as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = itemQuery(for: account)
            item[kSecValueData as String] = data
            // No effect in the file-based keychain: it accepts this attribute but does not keep it (checked on
            // macOS 27), and items there can be read whenever the login keychain is unlocked.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: updated)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(itemQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Picks out the one item for `account`: service and account are what identify an item. Accessibility is only
    /// given when an item is added, so finding, changing and deleting an item never depend on how it was stored.
    private func itemQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Keeps secrets in memory only, for tests and previews. Safe to use from several threads.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    /// Starts with `initial`. An empty value counts as no secret, as it does in `setSecret`.
    public init(_ initial: [String: String] = [:]) {
        values = initial.filter { !$0.value.isEmpty }
    }

    public func secret(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    /// Never throws; it is declared `throws` because the protocol is.
    public func setSecret(_ value: String?, for account: String) throws {
        lock.withLock {
            if let value, !value.isEmpty {
                values[account] = value
            } else {
                values[account] = nil
            }
        }
    }
}
