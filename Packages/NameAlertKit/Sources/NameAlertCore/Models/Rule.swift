import Foundation

/// A named set of words to listen for, and what to do when one is heard.
public struct Rule: Codable, Sendable, Equatable, Hashable, Identifiable {
    public static let cooldownRange: ClosedRange<Double> = 2...600

    public var id: UUID
    public var name: String
    public var terms: [String]
    public var sensitivity: Sensitivity
    public var channels: Set<ChannelKind>
    /// Seconds before this rule may fire again. Always within `cooldownRange`.
    public var cooldownSeconds: Double {
        didSet { cooldownSeconds = cooldownSeconds.clamped(to: Self.cooldownRange) }
    }
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(), name: String, terms: [String], sensitivity: Sensitivity = .balanced,
        channels: Set<ChannelKind> = [.sound, .notification], cooldownSeconds: Double = 10, isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.terms = terms
        self.sensitivity = sensitivity
        self.channels = channels
        // Property observers do not run inside an initializer, so clamp explicitly.
        self.cooldownSeconds = cooldownSeconds.clamped(to: Self.cooldownRange)
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        self.init(name: "", terms: [])  // fresh id and defaults; anything that decodes cleanly replaces them
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &id, forKey: .id)
        container.decodeTolerantly(into: &name, forKey: .name)
        container.decodeTolerantly(into: &terms, forKey: .terms)
        container.decodeTolerantly(into: &sensitivity, forKey: .sensitivity)
        container.decodeTolerantly(intoSet: &channels, forKey: .channels)
        container.decodeTolerantly(into: &cooldownSeconds, forKey: .cooldownSeconds)
        container.decodeTolerantly(into: &isEnabled, forKey: .isEnabled)
        cooldownSeconds = cooldownSeconds.clamped(to: Self.cooldownRange)  // decoding bypasses didSet too
    }
}
