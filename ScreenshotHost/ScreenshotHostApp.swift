import SwiftUI

/// Hosts the render and screenshot tests (`NameAlertScreenshots`). It is built from the app's sources minus the app's
/// `@main`, Info.plist and entitlements: it opens no window, loads no settings and never listens. The tests build the
/// views they render, each with its own demo controller.
@main
struct ScreenshotHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
