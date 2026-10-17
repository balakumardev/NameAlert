import Foundation
import os

/// The last answer StoreKit gave about Pro on this Mac, and when.
public struct ProAccessRecord: Codable, Sendable, Equatable {
    public var access: ProAccess
    public var verifiedAt: Date

    public init(access: ProAccess, verifiedAt: Date) {
        self.access = access
        self.verifiedAt = verifiedAt
    }
}

/// Keeps the last verified answer about Pro in the app's defaults, so that a Pro owner has Pro from the first moment of
/// a launch, before StoreKit has answered. It is never the last word: every StoreKit answer replaces it, so editing it
/// by hand gains a few seconds at most.
public struct ProAccessCache {
    public static let key = "pro.lastVerifiedAccess"

    private let defaults: UserDefaults
    private let logger = Log.logger("pro")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved record; `nil` when there is none or it cannot be read.
    public func load() -> ProAccessRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(ProAccessRecord.self, from: data)
        } catch {
            let ns = error as NSError
            logger.error("Could not read the saved Pro answer (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); treating it as none")
            return nil
        }
    }

    public func save(_ record: ProAccessRecord) {
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: Self.key)
        } catch {
            let ns = error as NSError
            logger.error("Could not save the Pro answer (\(ns.domain, privacy: .public) \(ns.code, privacy: .public))")
        }
    }
}
