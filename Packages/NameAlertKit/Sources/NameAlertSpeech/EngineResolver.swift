import Foundation
import NameAlertCore

/// The engine that was picked, or the reason none could be.
public enum EngineResolution: Sendable, Equatable {
    /// Use this engine, for this language. The language is spelled the way the engine lists it.
    case engine(EngineID, localeIdentifier: String)
    /// No engine fits what the user asked for. The reason is plain text for the user.
    case unavailable(reason: String)
}

/// Picks the speech engine for a language.
///
/// In Automatic, Apple's engines come first, from the newest to the oldest:
/// 1. `SpeechTranscriber`, on macOS 26 and later where it runs.
/// 2. `DictationTranscriber`, on macOS 26 and later. This is what Intel Macs get.
/// 3. `SFSpeechRecognizer`, when it can recognize the language on the device.
///
/// If none of them can, the local whisper model is used, at the size the user chose.
/// "Apple" stops after step 3 and "Local model" goes straight to whisper.
///
/// `resolve` works only from the capabilities it is given, so tests can try any Mac. (The one thing it reads from
/// the system is the display language, to name a language in the "unavailable" text.) `probeCapabilities()` is what
/// reads the real Mac.
public enum EngineResolver {
    /// The macOS version that brought `SpeechAnalyzer`, and with it `SpeechTranscriber` and `DictationTranscriber`.
    private static let analyzerMajorVersion = 26

    public static func resolve(
        preference: EnginePreference, localeIdentifier: String, localModelSize: LocalModelSize,
        capabilities: EngineCapabilities
    ) -> EngineResolution {
        switch preference {
        case .automatic:
            appleEngine(for: localeIdentifier, capabilities: capabilities)
                ?? localModel(for: localeIdentifier, size: localModelSize)
        case .apple:
            appleEngine(for: localeIdentifier, capabilities: capabilities)
                ?? .unavailable(reason: unavailableReason(for: localeIdentifier))
        case .localModel:
            localModel(for: localeIdentifier, size: localModelSize)
        }
    }

    /// The supported identifier that serves `identifier`, spelled as the `supported` list has it.
    ///
    /// `_` and `-` are the same, and case does not matter. An exact match wins. Otherwise one of the supported
    /// identifiers with the same language: the one for the region where the language is most spoken (Foundation's
    /// likely subtags: English → US, Portuguese → Brazil), so "en-IN" finds "en-US" and not "en-ID" when there is no
    /// Indian English; without that region, the first in alphabetical order. Settings that a language does not need,
    /// like the "@rg=inzzzz" in the identifier of a Mac with a region override, are left out. Returns nil when no
    /// supported identifier has the language.
    public static func matchLocale(_ identifier: String, in supported: [String]) -> String? {
        let wanted = canonical(identifier)
        guard let language = languageCode(of: wanted) else { return nil }
        let candidates = supported.map { (identifier: $0, canonical: canonical($0)) }
        if let exact = candidates.first(where: { $0.canonical == wanted }) {
            return exact.identifier
        }
        let sameLanguage =
            candidates
            .filter { languageCode(of: $0.canonical) == language }
            .sorted { ($0.canonical, $0.identifier) < ($1.canonical, $1.identifier) }
        if let likely = likelyRegion(ofLanguage: language),
            let inLikelyRegion = sameLanguage.first(where: { region(of: $0.identifier) == likely })
        {
            return inLikelyRegion.identifier
        }
        return sameLanguage.first?.identifier
    }

    // MARK: Steps

    /// Steps 1 to 3, or nil when Apple cannot do the language.
    private static func appleEngine(
        for localeIdentifier: String, capabilities: EngineCapabilities
    ) -> EngineResolution? {
        if capabilities.osMajorVersion >= analyzerMajorVersion {
            if capabilities.speechTranscriberAvailable,
                let locale = matchLocale(localeIdentifier, in: capabilities.speechTranscriberLocales)
            {
                return .engine(.appleSpeechTranscriber, localeIdentifier: locale)
            }
            if let locale = matchLocale(localeIdentifier, in: capabilities.dictationTranscriberLocales) {
                return .engine(.appleDictationTranscriber, localeIdentifier: locale)
            }
        }
        if let locale = matchLocale(localeIdentifier, in: capabilities.sfSpeechOnDeviceLocales) {
            return .engine(.appleSFSpeech, localeIdentifier: locale)
        }
        return nil
    }

    /// Step 4. The language is passed on as it came; the model catalog decides between the English and the
    /// multilingual file.
    private static func localModel(for localeIdentifier: String, size: LocalModelSize) -> EngineResolution {
        let engine: EngineID =
            switch size {
            case .light: .whisperLight
            case .balanced: .whisperBalanced
            }
        return .engine(engine, localeIdentifier: localeIdentifier)
    }

    private static func unavailableReason(for localeIdentifier: String) -> String {
        let code = languageCode(of: canonical(localeIdentifier)) ?? localeIdentifier
        let language = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "Apple speech recognition isn't available for \(language) on this Mac."
    }

    // MARK: Identifiers

    /// One spelling for comparing: lowercase, `_` as `-`, and without ICU keywords ("@rg=inzzzz") and extensions
    /// ("-u-rg-inzzzz"), which come after the language, script and region.
    private static func canonical(_ identifier: String) -> String {
        var subtags: [Substring] = []
        for subtag in identifier.prefix(while: { $0 != "@" }).split(whereSeparator: { $0 == "-" || $0 == "_" }) {
            if subtag.count == 1 { break }  // "u", "x" and the like start an extension
            subtags.append(subtag)
        }
        return subtags.joined(separator: "-").lowercased()
    }

    /// The language part of a `canonical` identifier, or nil when it is empty.
    private static func languageCode(of canonical: String) -> String? {
        canonical.split(separator: "-").first.map(String.init)
    }

    /// The region where `language` is most spoken, from Foundation's likely subtags ("en" → "en-Latn-US" → "US"), or
    /// nil when there is none.
    private static func likelyRegion(ofLanguage language: String) -> String? {
        let maximal = Locale.Language(identifier: language).maximalIdentifier
        return Locale.Language(identifier: maximal).region?.identifier.uppercased()
    }

    /// The region of a supported identifier ("en-US" → "US"). It is the language's region: a region override
    /// ("@rg=inzzzz") does not change it.
    private static func region(of identifier: String) -> String? {
        Locale.Language(identifier: identifier).region?.identifier.uppercased()
    }
}
