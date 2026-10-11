import Foundation
import NameAlertCore

/// A file the local speech engine needs: one of the whisper models, or the voice activity detector.
///
/// The raw values are the IDs used in the spec.
public enum WhisperModel: String, Codable, Sendable, CaseIterable {
    case lightEnglish = "whisper.light.en", lightMultilingual = "whisper.light.multi"
    case balancedEnglish = "whisper.balanced.en", balancedMultilingual = "whisper.balanced.multi"
    case vad = "vad.silero"
}

/// Where a model file comes from, and what it must be once it is here.
public struct ModelDescriptor: Sendable, Equatable {
    public let model: WhisperModel
    /// The name of the file in the models folder.
    public let fileName: String
    /// The exact size of the file.
    public let bytes: Int64
    /// The SHA-256 of the file, as 64 lowercase hex digits.
    public let sha256: String
    public let url: URL

    public init(model: WhisperModel, fileName: String, bytes: Int64, sha256: String, url: URL) {
        self.model = model
        self.fileName = fileName
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
    }
}

/// The models NameAlert can download.
///
/// Every file is pinned. It is fetched from one fixed revision of its repository, never from the latest one, and its
/// size and SHA-256 are checked after the download (see `ModelManager`). The values are the table in spec section 8.6.
public enum ModelCatalog {
    /// All four whisper models live in one folder of one revision.
    private static let whisperFolder =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"

    public static func descriptor(_ model: WhisperModel) -> ModelDescriptor {
        switch model {
        case .lightEnglish:
            whisper(
                model, "ggml-tiny.en-q5_1.bin", bytes: 32_166_155,
                sha256: "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b")
        case .lightMultilingual:
            whisper(
                model, "ggml-tiny-q5_1.bin", bytes: 32_152_673,
                sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7")
        case .balancedEnglish:
            whisper(
                model, "ggml-base.en-q5_1.bin", bytes: 59_721_011,
                sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f")
        case .balancedMultilingual:
            whisper(
                model, "ggml-base-q5_1.bin", bytes: 59_707_625,
                sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898")
        case .vad:
            ModelDescriptor(
                model: model, fileName: "ggml-silero-v5.1.2.bin", bytes: 885_098,
                sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
                url: url(
                    "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"
                ))
        }
    }

    /// The whisper model for a size and a language: the English-only model for English, the multilingual one for
    /// every other language.
    ///
    /// The language is what comes before the first "-", "_" or "@" in the identifier, in any case, so "en-US",
    /// "en_GB" and "en_US@rg=inzzzz" are all English.
    public static func model(size: LocalModelSize, localeIdentifier: String) -> WhisperModel {
        let language = localeIdentifier.prefix { $0 != "-" && $0 != "_" && $0 != "@" }.lowercased()
        switch (size, language == "en") {
        case (.light, true): return .lightEnglish
        case (.light, false): return .lightMultilingual
        case (.balanced, true): return .balancedEnglish
        case (.balanced, false): return .balancedMultilingual
        }
    }

    /// About how much memory the engine needs at this size, in megabytes, as measured with the real models. The UI
    /// shows it next to the download size.
    public static func ramEstimateMB(_ size: LocalModelSize) -> Int {
        switch size {
        case .light: 170
        case .balanced: 260
        }
    }

    // MARK: Building descriptors

    private static func whisper(
        _ model: WhisperModel, _ fileName: String, bytes: Int64, sha256: String
    ) -> ModelDescriptor {
        ModelDescriptor(
            model: model, fileName: fileName, bytes: bytes, sha256: sha256, url: url(whisperFolder + fileName))
    }

    /// The addresses above are fixed text, so a bad one is a mistake in this file; the catalog test catches it.
    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("Not a URL in the model catalog: \(string)") }
        return url
    }
}
