import Foundation

/// Common interface for any alert channel (sound, notification, push, phone call).
protocol Alert: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fire(reason: Hit) async
}
