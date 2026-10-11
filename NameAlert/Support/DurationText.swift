import Foundation

/// Short, plain wording for a number of seconds, as the settings show it: "3 s", "1 min", "1 min 30 s".
enum DurationText {
    static func short(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// The same for VoiceOver: "10 seconds", "1 minute, 30 seconds".
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(max(0, Int(seconds.rounded())))
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}
