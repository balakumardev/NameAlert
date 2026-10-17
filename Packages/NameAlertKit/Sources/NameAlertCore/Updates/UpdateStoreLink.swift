import Foundation

/// Where "Update" sends someone: Takeheed's own Mac App Store page, and nothing else. The app only ever opens a
/// page; the App Store does the download and the install (App Review guideline 2.4.5(vii)).
public enum UpdateStoreLink {
    /// The App Store's Updates tab, for when the lookup gave no usable page of ours.
    public static let updatesPage = URL(string: "macappstore://showUpdatesPage")!

    /// The store page the lookup named, if it is an https page on Apple's own App Store hosts; the Updates tab if not.
    /// A lookup answer is data, not a place to send people, so anything else is ignored.
    public static func pageURL(for release: AppStoreRelease) -> URL {
        guard let url = release.storeURL, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
            host == "apps.apple.com" || host == "itunes.apple.com"
        else { return updatesPage }
        return url
    }
}
