import AppKit

/// Plays a system sound by name (e.g. "Glass", "Ping", "Submarine").
struct BeepAlert: Alert {
    let id = "beep"
    let displayName = "System Beep"
    let soundName: String

    func fire(reason: Hit) async {
        await MainActor.run { [soundName] in
            NSSound(named: NSSound.Name(soundName))?.play()
        }
    }

    /// macOS bundled system sounds in /System/Library/Sounds.
    static let systemSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
        "Submarine", "Tink"
    ]
}
