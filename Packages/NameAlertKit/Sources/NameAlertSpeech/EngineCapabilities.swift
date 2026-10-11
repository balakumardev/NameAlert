import Foundation
import Speech

/// What this Mac's speech recognition can do, as a plain snapshot. The resolver picks an engine from it, and tests
/// build their own.
public struct EngineCapabilities: Sendable, Equatable {
    /// The major version of macOS: 14, 15, 26.
    public var osMajorVersion: Int
    /// Whether `SpeechTranscriber` runs on this Mac. It needs macOS 26 and is not there on Intel Macs.
    public var speechTranscriberAvailable: Bool
    /// The languages `SpeechTranscriber` can transcribe, as identifiers like "en-US". Empty when it is not available.
    public var speechTranscriberLocales: [String]
    /// The languages `DictationTranscriber` can transcribe. Empty before macOS 26.
    public var dictationTranscriberLocales: [String]
    /// The languages `SFSpeechRecognizer` can recognize on this Mac without the network.
    public var sfSpeechOnDeviceLocales: [String]
    /// Whether this is an Apple silicon Mac. For information only: the resolver goes by what is available.
    public var isAppleSilicon: Bool

    public init(
        osMajorVersion: Int, speechTranscriberAvailable: Bool, speechTranscriberLocales: [String],
        dictationTranscriberLocales: [String], sfSpeechOnDeviceLocales: [String], isAppleSilicon: Bool
    ) {
        self.osMajorVersion = osMajorVersion
        self.speechTranscriberAvailable = speechTranscriberAvailable
        self.speechTranscriberLocales = speechTranscriberLocales
        self.dictationTranscriberLocales = dictationTranscriberLocales
        self.sfSpeechOnDeviceLocales = sfSpeechOnDeviceLocales
        self.isAppleSilicon = isAppleSilicon
    }
}

extension EngineResolver {
    /// Asks this Mac what speech recognition it has.
    ///
    /// It only reads what the system lists, so it never shows a permission prompt and can be called at any time.
    /// The answer is not kept: callers that need it more than once should keep it themselves. Languages come back
    /// as sorted identifiers like "en-US". The ones from `SpeechTranscriber` and `DictationTranscriber` include
    /// languages whose assets are not installed yet, because the engine installs them when it starts.
    public static func probeCapabilities() async -> EngineCapabilities {
        var speechTranscriberAvailable = false
        var speechTranscriberLocales: [String] = []
        var dictationTranscriberLocales: [String] = []
        if #available(macOS 26, *) {
            if SpeechTranscriber.isAvailable {
                speechTranscriberAvailable = true
                speechTranscriberLocales = bcp47Identifiers(await SpeechTranscriber.supportedLocales)
            }
            dictationTranscriberLocales = bcp47Identifiers(await DictationTranscriber.supportedLocales)
        }

        let sfSpeechOnDeviceLocales = bcp47Identifiers(
            SFSpeechRecognizer.supportedLocales().filter {
                SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
            })

        #if arch(arm64)
            let isAppleSilicon = true
        #else
            let isAppleSilicon = false
        #endif

        return EngineCapabilities(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            speechTranscriberAvailable: speechTranscriberAvailable,
            speechTranscriberLocales: speechTranscriberLocales,
            dictationTranscriberLocales: dictationTranscriberLocales,
            sfSpeechOnDeviceLocales: sfSpeechOnDeviceLocales,
            isAppleSilicon: isAppleSilicon)
    }
}

/// "en-US" style identifiers for `locales`, without repeats and in alphabetical order, so the same Mac always gives
/// the same snapshot.
private func bcp47Identifiers(_ locales: some Sequence<Locale>) -> [String] {
    Set(locales.map { $0.identifier(.bcp47) }).sorted()
}
