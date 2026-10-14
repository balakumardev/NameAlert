import Foundation

/// Whether this build sells Pro. Only the Mac App Store build does: `scripts/build_appstore.sh` compiles the app with
/// `APP_STORE_BUILD`. Every other build (the Developer ID disk image, CI's build, a build from source) has everything on
/// and never shows a purchase. A Debug run sells too when started with `-EnforcePro YES` (Edit Scheme > Run >
/// Arguments), against `Pro.storekit`.
///
/// The App Store build and the disk image both run in the App Sandbox with the same bundle ID, so the sandbox cannot
/// tell them apart: this flag is the only switch, and both build scripts check for `marker`
/// (`scripts/check_purchase_mode.sh`).
enum StoreBuild {
    static let isEnforced: Bool = {
        #if APP_STORE_BUILD
        return true
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "EnforcePro")
        #else
        return false
        #endif
    }()

    #if APP_STORE_BUILD
    /// Only the App Store build has this text, so `scripts/check_purchase_mode.sh` can tell a build that sells from one
    /// that does not. It is longer than 15 bytes, so the compiler keeps it as a string in the binary, and `ProStore` logs
    /// it when selling starts, so it is not stripped. Change it here and in that script together.
    static let marker = "app-store-build:pro-purchases-enforced"
    #endif
}
