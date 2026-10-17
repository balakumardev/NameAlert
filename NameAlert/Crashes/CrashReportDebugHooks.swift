#if DEBUG
import Foundation
import NameAlertCore

/// Debug-only launch arguments for trying the crash report window without crashing the app:
/// - `-SimulatePendingCrashReport YES` keeps one made-up crash report (when the offer is on), so the window opens a
///   moment after launch. The scheme lists it among its arguments, unticked.
/// - `-CrashAfterLaunchForTesting YES` crashes the app 5 seconds after launch. Run the app again after that to see
///   what MetricKit hands over (only a build with a real team identity gets anything).
enum CrashReportDebugHooks {
    /// A MetricKit crash diagnostic, trimmed, with a `terminationReason` that says it is simulated.
    static let simulatedDiagnosticJSON = #"""
    {"version":"1.0.0","callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":false,"callStackRootFrames":[{"binaryUUID":"F63BF418-8F75-34A4-AAF1-8CAF2B9B6A05","offsetIntoBinaryTextSegment":3104,"binaryName":"libsystem_kernel.dylib","address":6770871328}]},{"threadAttributed":true,"callStackRootFrames":[{"binaryUUID":"30460BF7-9FD5-313C-834C-315211E7B1B5","offsetIntoBinaryTextSegment":20696,"binaryName":"Takeheed","address":4309799128,"subFrames":[{"binaryUUID":"022BF08F-0B3A-3225-9E65-16D1553CE90D","offsetIntoBinaryTextSegment":112032,"binaryName":"libdispatch.dylib","address":6769419680}]}]}]},"diagnosticMetaData":{"platformArchitecture":"arm64e","terminationReason":"Simulated crash report (-SimulatePendingCrashReport)","exceptionType":6,"appBuildVersion":"1","isTestFlightApp":false,"osVersion":"macOS 27.0.1 (26A434)","bundleIdentifier":"dev.balakumar.namealert","deviceType":"Mac16,8","exceptionCode":1,"signal":5,"regionFormat":"IN","appVersion":"1.0.0","pid":8501,"lowPowerModeEnabled":false}}
    """#

    /// Reads the debug launch arguments (they reach `UserDefaults.standard`'s argument domain).
    static func applyLaunchArguments(
        defaults: UserDefaults = .standard,
        store: PendingCrashReportStore = .standard,
        preferences: CrashReportPreferences = .standard
    ) {
        if defaults.bool(forKey: "SimulatePendingCrashReport"), preferences.offerToSend {
            store.save(diagnosticJSON: Data(simulatedDiagnosticJSON.utf8), crashedAt: Date(), fallback: .current)
        }
        if defaults.bool(forKey: "CrashAfterLaunchForTesting") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                fatalError("Crash test requested with -CrashAfterLaunchForTesting")
            }
        }
    }
}
#endif
