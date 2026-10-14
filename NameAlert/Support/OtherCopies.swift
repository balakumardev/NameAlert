import AppKit
import Observation

/// Other copies of the app that LaunchServices knows about: an older build, a second download, the App Store copy next
/// to the one from the website.
///
/// macOS opens the app by its bundle id in places, and it may pick one of these then: after Screen Recording was
/// allowed, "Quit & Reopen" opened another copy, which had neither the permission nor this copy's settings. Setup's
/// Screen Recording card and the popover's Screen Recording notes say where the other copy is.
@MainActor
@Observable
final class OtherCopies {
    /// What the app uses. Tests make their own.
    static let shared = OtherCopies()

    /// The other copies, the one LaunchServices would open first, first. Empty until `refresh()`.
    private(set) var urls: [URL]

    /// `urls` are copies to start with, for tests and renders; the app starts with none and asks.
    init(urls: [URL] = []) {
        self.urls = urls
    }

    /// Asks LaunchServices again: at launch, and whenever the app or the popover comes forward, since a copy may have
    /// been deleted meanwhile.
    func refresh() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let found = Self.others(
            of: Bundle.main.bundleURL, among: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID))
        if found != urls { urls = found }
    }

    /// The copies in `registered` other than `running`, in the same order, without those whose files are gone:
    /// LaunchServices can still list a copy that was deleted, or one on a disk image that was ejected. Paths are
    /// compared standardized and with symbolic links resolved. A copy that Gatekeeper runs from a random folder (App
    /// Translocation) cannot tell which registered copy it is, so it finds none.
    ///
    /// Looking a path up is allowed in the sandbox, and inside Downloads too without asking (only reading what is in a
    /// folder there asks).
    nonisolated static func others(
        of running: URL, among registered: [URL],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [URL] {
        let own = canonicalPath(running)
        guard !own.contains("/AppTranslocation/") else { return [] }
        var seen: Set<String> = [own]
        return registered.filter { seen.insert(canonicalPath($0)).inserted && exists($0) }
    }

    nonisolated private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Where the first of `copies` is, and what to do about it; `nil` when there is none.
    nonisolated static func note(for copies: [URL]) -> String? {
        guard let copy = copies.first else { return nil }
        return "Another copy of \(AppInfo.displayName) is at \(copy.path). After you allow Screen Recording, macOS may "
            + "open that copy instead. Delete it, then open this one."
    }
}
