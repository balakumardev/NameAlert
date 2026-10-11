import AppKit
import NameAlertCore

/// Plays the system sound the user chose, once, at the volume they chose.
public struct SoundChannel: AlertChannel {
    public var kind: ChannelKind { .sound }

    public init() {}

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        let sound = settings.sound
        try await MainActor.run { try Self.play(sound) }
    }

    @MainActor
    private static func play(_ settings: SoundSettings) throws {
        // `NSSound(named:)` hands out one shared object for each name, so it is put right first: not left looping
        // by anything else, and started over if the last hit's sound is still playing.
        guard let sound = NSSound(named: NSSound.Name(settings.soundName)) else {
            throw AlertDeliveryError.soundUnavailable
        }
        if sound.isPlaying { sound.stop() }
        sound.loops = false
        sound.volume = Float(settings.volume)
        guard sound.play() else { throw AlertDeliveryError.soundUnavailable }
    }
}
