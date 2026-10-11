import Foundation
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import SwiftUI

/// Settings → Speech: which engine turns speech into text and what it is told to listen for, the language, and the
/// local models.
struct SpeechSettingsView: View {
    /// The local models, in the order they are listed.
    static let models: [WhisperModel] = [.lightEnglish, .lightMultilingual, .balancedEnglish, .balancedMultilingual]

    @Environment(ListeningController.self) private var controller
    @Environment(\.speechCapabilities) private var probeCapabilities

    @State private var capabilities: EngineCapabilities?
    @State private var resolution: EngineResolution?
    @State private var actions = ModelActions()

    var body: some View {
        let speech = controller.configuration.speech
        Form {
            engineSection(speech)
            languageSection(speech)
            sizeSection()
            modelsSection()
        }
        .formStyle(.grouped)
        .task { capabilities = await probeCapabilities() }
        .task(id: speech) { resolution = await controller.resolvedEngine() }
    }

    // MARK: Engine

    private func engineSection(_ speech: SpeechSettings) -> some View {
        let summary = Self.summary(for: resolution, preference: speech.engine)
        return Section {
            Picker("Engine", selection: controller.binding(\.speech.engine)) {
                ForEach(EnginePreference.allCases, id: \.self) { preference in
                    Text(verbatim: Self.title(for: preference)).tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Speech engine")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Using now:")
                        .foregroundStyle(.secondary)
                    Text(verbatim: summary.name)
                        .bold()
                }
                if !summary.reason.isEmpty {
                    SettingsCaption(summary.reason, isError: summary.isProblem)
                }
            }
            .accessibilityElement(children: .combine)
        } header: {
            SettingsSectionTitle("Engine")
        } footer: {
            SettingsCaption(Self.explanation(for: speech.engine))
        }
    }

    // MARK: Language

    private func languageSection(_ speech: SpeechSettings) -> some View {
        let identifiers = SpeechLanguages.identifiers(
            for: resolution, capabilities: capabilities, selected: speech.localeIdentifier)
        return Section {
            Picker("Language", selection: controller.binding(\.speech.localeIdentifier)) {
                Text(verbatim: SpeechLanguages.systemDefaultTitle).tag(String?.none)
                ForEach(identifiers, id: \.self) { identifier in
                    Text(verbatim: SpeechLanguages.title(for: identifier)).tag(String?.some(identifier))
                }
            }
            .accessibilityLabel("Language")
        } header: {
            SettingsSectionTitle("Language")
        } footer: {
            SettingsCaption("The languages the engine in use can understand.")
        }
    }

    // MARK: Local models

    private func sizeSection() -> some View {
        Section {
            Picker("Size", selection: controller.binding(\.speech.localModelSize)) {
                ForEach(LocalModelSize.allCases, id: \.self) { size in
                    Text(verbatim: "\(Self.title(for: size)) · \(Self.memoryText(for: size))").tag(size)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Local model size")
        } header: {
            SettingsSectionTitle("Local model size")
        } footer: {
            SettingsCaption("Balanced hears more accurately. Light is easier on memory and battery.")
        }
    }

    private func modelsSection() -> some View {
        let inUse = ModelRowState.modelInUse(by: controller.state)
        return Section {
            ForEach(Self.models, id: \.self) { model in
                ModelRow(
                    model: model,
                    state: ModelRowState.of(
                        model, installed: controller.installedModels, downloads: controller.modelDownloads,
                        inUse: inUse),
                    message: actions.messages[model],
                    download: { actions.download(model, using: controller) },
                    cancel: { actions.cancel(model, using: controller) },
                    delete: { actions.delete(model, using: controller) })
            }
        } header: {
            SettingsSectionTitle("Models")
        } footer: {
            SettingsCaption(
                "A small speech detector (\(ModelRow.size(of: .vad))) downloads with the first model.")
        }
    }

    // MARK: Words

    static func title(for preference: EnginePreference) -> String {
        switch preference {
        case .automatic: "Automatic"
        case .apple: "Apple only"
        case .localModel: "Local model"
        }
    }

    static func explanation(for preference: EnginePreference) -> String {
        switch preference {
        case .automatic: "Uses Apple's on-device speech when it knows your language, and the local model when it doesn't."
        case .apple: "Uses only Apple's on-device speech. It may not know every language."
        case .localModel: "Uses a model downloaded to this Mac. It knows more languages and uses more memory."
        }
    }

    static func title(for size: LocalModelSize) -> String {
        switch size {
        case .light: "Light"
        case .balanced: "Balanced"
        }
    }

    /// What the engine needs in memory, as measured with the real models.
    static func memoryEstimateMB(for size: LocalModelSize) -> Int {
        ModelCatalog.ramEstimateMB(size)
    }

    static func memoryText(for size: LocalModelSize) -> String {
        "≈\(memoryEstimateMB(for: size)) MB memory"
    }

    /// The line under the engine buttons: what is in use, and why.
    struct Summary: Equatable {
        var name: String
        var reason: String
        var isProblem = false
    }

    static func summary(for resolution: EngineResolution?, preference: EnginePreference) -> Summary {
        guard let resolution else { return Summary(name: "Checking…", reason: "") }
        switch resolution {
        case .unavailable(let reason):
            return Summary(name: "None", reason: "\(reason) Try Automatic or Local model.", isProblem: true)
        case .engine(let engine, let locale):
            let language = SpeechLanguages.title(for: locale)
            let isLocal = engine == .whisperLight || engine == .whisperBalanced
            let reason =
                switch preference {
                case .automatic where isLocal: "Apple speech can't do \(language) on this Mac, so the local model is used."
                case .automatic: "Apple speech supports \(language) on this Mac."
                case .apple: "You chose Apple only. Language: \(language)."
                case .localModel: "You chose the local model. Language: \(language)."
                }
            return Summary(name: StatusText.engineName(engine), reason: reason)
        }
    }
}

/// The languages the Language menu offers.
enum SpeechLanguages {
    /// The languages Whisper's multilingual models know: the local model's list.
    static let whisperCodes: [String] =
        """
        en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml \
        cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am \
        yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su
        """
        .split(whereSeparator: \.isWhitespace).map(String.init)

    /// "System default · English (United States)": the language the Mac is set to.
    static var systemDefaultTitle: String {
        let name = title(for: Locale.current.identifier)
        return name.isEmpty ? "System default" : "System default · \(name)"
    }

    /// The language's name in the user's own language: "German (Germany)". A setting after an "@" in the identifier (a
    /// region override like "@rg=inzzzz", which the engines ignore too) is left out.
    static func title(for identifier: String) -> String {
        let language = String(identifier.prefix { $0 != "@" })
        return Locale.current.localizedString(forIdentifier: language) ?? language
    }

    /// The languages of the engine family in use, by name; the one that is chosen is always among them. While the
    /// engine is not known yet, or none can be had, they are all the languages Apple's engines know.
    static func identifiers(
        for resolution: EngineResolution?, capabilities: EngineCapabilities?, selected: String?
    ) -> [String] {
        var identifiers: [String]
        switch resolution {
        case .engine(.appleSpeechTranscriber, _): identifiers = capabilities?.speechTranscriberLocales ?? []
        case .engine(.appleDictationTranscriber, _): identifiers = capabilities?.dictationTranscriberLocales ?? []
        case .engine(.appleSFSpeech, _): identifiers = capabilities?.sfSpeechOnDeviceLocales ?? []
        case .engine(.whisperLight, _), .engine(.whisperBalanced, _): identifiers = whisperCodes
        case .unavailable, nil:
            identifiers =
                (capabilities.map {
                    Set($0.speechTranscriberLocales).union($0.dictationTranscriberLocales).union($0.sfSpeechOnDeviceLocales)
                } ?? []).sorted()
        }
        if let selected, !selected.isEmpty, !identifiers.contains(selected) { identifiers.append(selected) }
        return identifiers.sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending }
    }
}

/// Asks this Mac what its speech recognition can do the first time, and gives the same answer after that, so that
/// opening the Speech pane again does not ask again (the answer does not change while the app runs).
private actor SpeechCapabilitiesCache {
    static let shared = SpeechCapabilitiesCache()

    private var cached: EngineCapabilities?

    func capabilities() async -> EngineCapabilities {
        if let cached { return cached }
        let probed = await EngineResolver.probeCapabilities()
        cached = probed
        return probed
    }
}

private struct SpeechCapabilitiesKey: EnvironmentKey {
    static var defaultValue: @Sendable () async -> EngineCapabilities {
        { await SpeechCapabilitiesCache.shared.capabilities() }
    }
}

extension EnvironmentValues {
    /// Asks this Mac what speech recognition it has, for the Language menu. Renders and tests give their own answer.
    var speechCapabilities: @Sendable () async -> EngineCapabilities {
        get { self[SpeechCapabilitiesKey.self] }
        set { self[SpeechCapabilitiesKey.self] = newValue }
    }
}
