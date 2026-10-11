import Foundation
import NameAlertCore
@testable import NameAlertSpeech
import Speech
import Testing

// MARK: - Capability fixtures

/// macOS 26 on Apple silicon: every Apple engine is there.
private let capsA = EngineCapabilities(
    osMajorVersion: 26, speechTranscriberAvailable: true, speechTranscriberLocales: ["en-US", "en-GB"],
    dictationTranscriberLocales: ["en-US", "fr-FR"], sfSpeechOnDeviceLocales: ["en-US"], isAppleSilicon: true)

/// macOS 26 on an Intel Mac: `SpeechTranscriber` does not run, `DictationTranscriber` does.
private let capsB = EngineCapabilities(
    osMajorVersion: 26, speechTranscriberAvailable: false, speechTranscriberLocales: [],
    dictationTranscriberLocales: ["en-US"], sfSpeechOnDeviceLocales: [], isAppleSilicon: false)

/// macOS 15: only `SFSpeechRecognizer`.
private let capsC = EngineCapabilities(
    osMajorVersion: 15, speechTranscriberAvailable: false, speechTranscriberLocales: [],
    dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: ["en-US"], isAppleSilicon: true)

/// macOS 14 on an Intel Mac with no on-device language at all.
private let capsD = EngineCapabilities(
    osMajorVersion: 14, speechTranscriberAvailable: false, speechTranscriberLocales: [],
    dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: [], isAppleSilicon: false)

private extension EngineResolution {
    /// The reason, when no engine was picked.
    var unavailableReason: String? {
        if case let .unavailable(reason) = self { reason } else { nil }
    }
}

private func resolve(
    _ preference: EnginePreference, _ locale: String, _ size: LocalModelSize = .light,
    _ capabilities: EngineCapabilities
) -> EngineResolution {
    EngineResolver.resolve(
        preference: preference, localeIdentifier: locale, localModelSize: size, capabilities: capabilities)
}

private func engine(_ id: EngineID, _ locale: String) -> EngineResolution {
    .engine(id, localeIdentifier: locale)
}

// MARK: - Tests

@Suite("EngineResolver")
struct EngineResolverTests {
    enum Expected: Sendable {
        case engine(EngineID, String)
        case unavailable
    }

    /// One line of the decision table.
    struct Row: Sendable, CustomTestStringConvertible {
        let capsName: String
        let capabilities: EngineCapabilities
        let preference: EnginePreference
        let locale: String
        let size: LocalModelSize
        let expected: Expected

        var testDescription: String { "\(capsName) \(preference) \(locale) \(size)" }
    }

    /// The brief's table: the capabilities (A to D above), preference, language and size in, the engine out.
    static let decisionTable: [Row] = [
        Row(capsName: "A", capabilities: capsA, preference: .automatic, locale: "en-US", size: .light,
            expected: .engine(.appleSpeechTranscriber, "en-US")),
        Row(capsName: "A", capabilities: capsA, preference: .automatic, locale: "en-IN", size: .light,
            expected: .engine(.appleSpeechTranscriber, "en-GB")),
        Row(capsName: "A", capabilities: capsA, preference: .automatic, locale: "fr-FR", size: .light,
            expected: .engine(.appleDictationTranscriber, "fr-FR")),
        Row(capsName: "A", capabilities: capsA, preference: .automatic, locale: "ta-IN", size: .balanced,
            expected: .engine(.whisperBalanced, "ta-IN")),
        Row(capsName: "A", capabilities: capsA, preference: .apple, locale: "ta-IN", size: .light,
            expected: .unavailable),
        Row(capsName: "A", capabilities: capsA, preference: .localModel, locale: "en-US", size: .light,
            expected: .engine(.whisperLight, "en-US")),
        Row(capsName: "B", capabilities: capsB, preference: .automatic, locale: "en-US", size: .light,
            expected: .engine(.appleDictationTranscriber, "en-US")),
        Row(capsName: "C", capabilities: capsC, preference: .automatic, locale: "en-US", size: .light,
            expected: .engine(.appleSFSpeech, "en-US")),
        Row(capsName: "C", capabilities: capsC, preference: .automatic, locale: "de-DE", size: .light,
            expected: .engine(.whisperLight, "de-DE")),
        Row(capsName: "D", capabilities: capsD, preference: .automatic, locale: "en-US", size: .light,
            expected: .engine(.whisperLight, "en-US")),
        Row(capsName: "D", capabilities: capsD, preference: .apple, locale: "en-US", size: .light,
            expected: .unavailable),
    ]

    @Test("Picks the engine in the decision table", arguments: EngineResolverTests.decisionTable)
    func decisionTableRow(row: Row) {
        let result = resolve(row.preference, row.locale, row.size, row.capabilities)
        switch row.expected {
        case let .engine(id, locale):
            #expect(result == .engine(id, localeIdentifier: locale))
        case .unavailable:
            #expect(result.unavailableReason != nil, "expected no engine, got \(result)")
        }
    }

    // MARK: When no engine is available

    @Test func unavailableReasonNamesTheLanguage() {
        let language = Locale.current.localizedString(forLanguageCode: "ta") ?? "ta"
        #expect(
            resolve(.apple, "ta-IN", .light, capsA).unavailableReason
                == "Apple speech recognition isn't available for \(language) on this Mac.")
    }

    @Test func unavailableReasonFallsBackToTheRawCode() {
        // No Mac has a language called "zz", so the name lookup finds nothing.
        let language = Locale.current.localizedString(forLanguageCode: "zz") ?? "zz"
        #expect(
            resolve(.apple, "zz_ZZ", .light, capsD).unavailableReason
                == "Apple speech recognition isn't available for \(language) on this Mac.")
    }

    // MARK: Which engine, and for which language

    @Test func whisperKeepsTheLanguageExactlyAsGiven() {
        #expect(resolve(.localModel, "ta_IN", .balanced, capsA) == engine(.whisperBalanced, "ta_IN"))
        #expect(resolve(.automatic, "de_DE", .light, capsC) == engine(.whisperLight, "de_DE"))
    }

    @Test func appleEnginesAreReportedWithTheSupportedSpelling() {
        #expect(resolve(.automatic, "EN_us", .light, capsA) == engine(.appleSpeechTranscriber, "en-US"))
    }

    @Test func systemLocaleWithARegionOverrideStillMatchesExactly() {
        // `Locale.current.identifier` on a Mac with US English and an India region reads "en_US@rg=inzzzz".
        // It must find "en-US", not the first English locale in the list.
        let caps = EngineCapabilities(
            osMajorVersion: 26, speechTranscriberAvailable: true, speechTranscriberLocales: ["en-AU", "en-US"],
            dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: [], isAppleSilicon: true)
        #expect(resolve(.automatic, "en_US@rg=inzzzz", .light, caps) == engine(.appleSpeechTranscriber, "en-US"))
    }

    @Test func theAnalyzerEnginesNeedMacOS26() {
        var caps = capsA
        caps.osMajorVersion = 25
        #expect(resolve(.automatic, "en-US", .light, caps) == engine(.appleSFSpeech, "en-US"))
        #expect(resolve(.automatic, "fr-FR", .light, caps) == engine(.whisperLight, "fr-FR"))
    }

    @Test func speechTranscriberNeedsToBeAvailableNotJustListed() {
        var caps = capsA
        caps.speechTranscriberAvailable = false
        #expect(resolve(.automatic, "en-US", .light, caps) == engine(.appleDictationTranscriber, "en-US"))
    }

    @Test func localModelIgnoresWhatAppleCanDo() {
        #expect(resolve(.localModel, "fr-FR", .balanced, capsA) == engine(.whisperBalanced, "fr-FR"))
    }

    // MARK: Matching a language to the supported ones

    @Test func matchLocaleNormalizes() {
        #expect(EngineResolver.matchLocale("en_us", in: ["en-US"]) == "en-US")
        #expect(EngineResolver.matchLocale("pt-BR", in: ["en-US"]) == nil)
    }

    @Test func exactMatchWinsOverTheSameLanguage() {
        #expect(EngineResolver.matchLocale("en-US", in: ["en-GB", "en-US"]) == "en-US")
        #expect(EngineResolver.matchLocale("EN-gb", in: ["en-US", "en-GB"]) == "en-GB")
    }

    @Test func sameLanguageFallsBackToTheAlphabeticallyFirst() {
        #expect(EngineResolver.matchLocale("en-IN", in: ["en-US", "en-GB", "fr-FR"]) == "en-GB")
        #expect(EngineResolver.matchLocale("en", in: ["fr-FR", "en-US", "en-GB"]) == "en-GB")
    }

    @Test func theLanguageCodeMustMatchWholly() {
        // "est" (Estonian) starts with "es" (Spanish) but is another language.
        #expect(EngineResolver.matchLocale("es-MX", in: ["est-EE"]) == nil)
        #expect(EngineResolver.matchLocale("en-US", in: ["fr-FR", "de-DE"]) == nil)
    }

    @Test func keywordsAndExtensionsAreIgnored() {
        let supported = ["en-AU", "en-US"]
        #expect(EngineResolver.matchLocale("en_US@rg=inzzzz", in: supported) == "en-US")
        #expect(EngineResolver.matchLocale("en-US-u-rg-inzzzz", in: supported) == "en-US")
        #expect(EngineResolver.matchLocale("en@calendar=gregorian", in: supported) == "en-AU")
    }

    @Test func nothingMatchesNothing() {
        #expect(EngineResolver.matchLocale("", in: ["en-US"]) == nil)
        #expect(EngineResolver.matchLocale("en-US", in: []) == nil)
    }

    // MARK: Reading the real Mac

    /// Reads what this Mac's speech frameworks list. It shows no prompt, but what it finds depends on the Mac, so it
    /// only runs when asked to: `NAMEALERT_INTEGRATION=1 swift test …`.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1",
            "Set NAMEALERT_INTEGRATION=1 to read this Mac's speech recognition."))
    func probeReadsThisMac() async {
        let caps = await EngineResolver.probeCapabilities()
        func show(_ name: String, _ value: Any) { print("probeReadsThisMac: \(name)=\(value)") }
        func showLocales(_ name: String, _ locales: [String]) { show("\(name)(\(locales.count))", locales) }
        show("osMajorVersion", caps.osMajorVersion)
        show("isAppleSilicon", caps.isAppleSilicon)
        show("speechTranscriberAvailable", caps.speechTranscriberAvailable)
        showLocales("speechTranscriberLocales", caps.speechTranscriberLocales)
        showLocales("dictationTranscriberLocales", caps.dictationTranscriberLocales)
        showLocales("sfSpeechOnDeviceLocales", caps.sfSpeechOnDeviceLocales)
        show("speechPermission", SpeechPermission.status())
        for identifier in ["en-US", Locale.current.identifier, "ta-IN"] {
            for preference in EnginePreference.allCases {
                show("\(preference) \(identifier)", resolve(preference, identifier, .light, caps))
            }
        }

        #expect(caps.osMajorVersion == ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        if caps.osMajorVersion < 26 {
            #expect(!caps.speechTranscriberAvailable)
            #expect(caps.dictationTranscriberLocales.isEmpty)
        }
        if !caps.speechTranscriberAvailable {
            #expect(caps.speechTranscriberLocales.isEmpty)
        }
        for locales in [caps.speechTranscriberLocales, caps.dictationTranscriberLocales, caps.sfSpeechOnDeviceLocales] {
            #expect(locales == Array(Set(locales)).sorted(), "locales should be sorted and without repeats")
            #expect(locales.allSatisfy { !$0.isEmpty && !$0.contains("_") }, "locales should read like \"en-US\"")
        }
        #if arch(arm64)
            #expect(caps.isAppleSilicon)
        #else
            #expect(!caps.isAppleSilicon)
        #endif
    }
}

@Suite("SpeechPermission")
struct SpeechPermissionTests {
    @Test func statusMapping() {
        #expect(SpeechPermission.permissionStatus(for: .authorized) == .granted)
        #expect(SpeechPermission.permissionStatus(for: .denied) == .denied)
        #expect(SpeechPermission.permissionStatus(for: .restricted) == .denied)
        #expect(SpeechPermission.permissionStatus(for: .notDetermined) == .notDetermined)
    }
}
