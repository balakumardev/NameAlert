import CoreGraphics
import Foundation
import NameAlertCore

/// The words on the alarm panel, taken from a hit.
struct AlarmContent: Equatable, Sendable {
    let title: String
    let ruleName: String
    let context: String
    /// What was said just before the term, when the hit has it: the excerpt without the spaces around it. `nil` when
    /// the hit has none or it is blank, so that the panel shows no empty box.
    let excerpt: String?

    init(hit: Hit) {
        title = "Heard “\(hit.term)”"
        ruleName = hit.ruleName
        context = hit.context
        let trimmed = hit.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        excerpt = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// The rules of the alarm panel, apart from the window and the sound: when it opens, when it only changes its words,
/// and when it closes. Each call says what to do about it as a list of effects, which `AlarmPanel` carries out.
///
/// Hits that come while the alarm shows do not open a second one: they change the words and start the auto-stop
/// time over. Every time the alarm is told to start waiting (`armTimer`), the wait gets a new `generation`, and a
/// timer only counts if it still has the latest one, so a timer that was started for an earlier hit, or for an alarm
/// that is gone, can never close the current one.
struct AlarmState: Equatable {
    enum Effect: Equatable {
        /// Show the panel with these words.
        case open(AlarmContent)
        /// The panel is showing already: change its words.
        case update(AlarmContent)
        case startSound(String)
        /// Wait this long, then call `timerFired` with this generation. Replaces a wait set before.
        case armTimer(generation: Int, seconds: Int)
        case stopSound
        /// Tell the app the user wants a pause of this many minutes.
        case snooze(minutes: Int)
        case close
    }

    private(set) var content: AlarmContent?
    private(set) var generation = 0

    var isShowing: Bool { content != nil }

    mutating func present(_ new: AlarmContent, soundName: String, autoStopSeconds: Int) -> [Effect] {
        generation += 1
        let wait = Effect.armTimer(generation: generation, seconds: max(autoStopSeconds, 1))
        defer { content = new }
        guard content != nil else { return [.open(new), .startSound(soundName), wait] }
        return [.update(new), wait]  // the sound that is looping goes on
    }

    mutating func dismiss() -> [Effect] {
        finish([])
    }

    mutating func snooze(minutes: Int) -> [Effect] {
        finish([.snooze(minutes: minutes)])
    }

    mutating func timerFired(generation fired: Int) -> [Effect] {
        fired == generation ? finish([]) : []
    }

    private mutating func finish(_ first: [Effect]) -> [Effect] {
        guard content != nil else { return [] }
        content = nil
        generation += 1  // a timer that is still on its way is out of date from now on
        return first + [.stopSound, .close]
    }
}

/// Where the alarm panel goes.
enum AlarmPlacement {
    /// The distance to the screen's edges, in points.
    static let margin: CGFloat = 16

    /// The lower left corner for a panel of `size` in the top right corner of `visibleFrame`, `margin` in from the top
    /// and the right. On a screen too small for that, the panel stays against the left and bottom edge.
    static func origin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.maxX - size.width - margin, visibleFrame.minX),
            y: max(visibleFrame.maxY - size.height - margin, visibleFrame.minY))
    }

    /// The position in `frames` of the first one that holds `point`, edges included; `nil` when none does.
    static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
    }
}
