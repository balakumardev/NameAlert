import Foundation
import NameAlertCore

/// One way of telling the user about a hit: a sound, a notification, a push to a phone, and so on.
///
/// A channel delivers one hit at a time and is told the settings and the secrets to use with each call, so it never
/// holds state about the user's configuration. `deliver` returns once the alert has been handed over (a sound
/// started, a request was answered with success) and throws when it could not be. It should stop quickly when its
/// task is cancelled: the `AlertDispatcher` cancels a delivery that takes too long.
///
/// A channel must not log secrets, header values, the user's addresses or what was heard.
public protocol AlertChannel: Sendable {
    var kind: ChannelKind { get }
    func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws
}

/// The last time a channel failed to deliver, as the settings screen shows it ("Last delivery failed: ...").
public struct DeliveryFailure: Sendable, Equatable {
    public let kind: ChannelKind
    /// What went wrong, in words the user can read. It never holds a secret or the address that was called.
    public let reason: String
    public let date: Date

    public init(kind: ChannelKind, reason: String, date: Date) {
        self.kind = kind
        self.reason = reason
        self.date = date
    }

    /// The words a failure gives for `error`: its `localizedDescription`. NameAlert's own errors (`AlertDeliveryError`,
    /// `HTTPError`) say what went wrong in plain words through it. Any other error gets the sentence the system has for
    /// it rather than its internals: a network error's description lists the address that was called (a webhook
    /// address can hold a secret), a system error's its domain, code and user info.
    public static func reason(for error: any Error) -> String {
        error.localizedDescription
    }
}

/// Why a delivery failed, when NameAlert itself found the reason (as opposed to the network or the system).
public enum AlertDeliveryError: Error, Equatable, Sendable {
    /// The channel did not finish within the dispatcher's delivery timeout.
    case timedOut
    /// The dispatcher has no channel of this kind.
    case noChannel(ChannelKind)
    /// The channel needs a setting that is empty: the ntfy topic, the Telegram user, the webhook address.
    case notConfigured(ChannelKind)
    /// A setting holds an address that cannot be used, such as a server without `https://`.
    case invalidAddress(ChannelKind)
    /// The sound named in the settings was not found, or could not be played.
    case soundUnavailable
    /// The channel turned the alert down because its last one went out too recently: Telegram calls go out at most once
    /// a minute. That is the channel working as it should, so the dispatcher does not count it as a failure; a Test
    /// reports it.
    case rateLimited(ChannelKind)
}

extension AlertDeliveryError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .timedOut: "Timed out"
        case .noChannel: "This alert is not available"
        case .notConfigured: "Not set up yet"
        case .invalidAddress: "The address is not valid"
        case .soundUnavailable: "The sound could not be played"
        case .rateLimited(.telegramCall): "Telegram calls are limited to one a minute — try again shortly."
        case .rateLimited: "This alert went out a moment ago — try again shortly."
        }
    }

    public var errorDescription: String? { description }
}
