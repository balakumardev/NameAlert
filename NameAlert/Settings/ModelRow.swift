import Foundation
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import Observation
import SwiftUI

/// Where a local speech model stands.
enum ModelRowState: Equatable {
    case notInstalled
    /// Coming in; the number is how far, from 0 to 1.
    case downloading(Double)
    /// On this Mac. `inUse` is true while listening uses it, so it cannot be deleted.
    case installed(inUse: Bool)

    static func of(
        _ model: WhisperModel, installed: Set<WhisperModel>, downloads: [WhisperModel: Double], inUse: WhisperModel?
    ) -> ModelRowState {
        if let fraction = downloads[model] { return .downloading(fraction) }
        if installed.contains(model) { return .installed(inUse: inUse == model) }
        return .notInstalled
    }

    /// The model the speech engine that is listening has loaded, if it is a local one.
    static func modelInUse(by state: ListeningState) -> WhisperModel? {
        guard case .listening(let info) = state else { return nil }
        let size: LocalModelSize
        switch info.engine {
        case .whisperLight: size = .light
        case .whisperBalanced: size = .balanced
        case .appleSpeechTranscriber, .appleDictationTranscriber, .appleSFSpeech: return nil
        }
        return ModelCatalog.model(size: size, localeIdentifier: info.localeIdentifier)
    }
}

/// One local speech model in the list: its name and download size, and what can be done with it: download it, cancel
/// the download, or delete it (after a question).
struct ModelRow: View {
    let model: WhisperModel
    let state: ModelRowState
    /// Why the last download or delete did not work, in words for the user.
    var message: String?
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        let name = Self.name(for: model)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                    Text(verbatim: Self.detail(for: model, state: state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing(name: name)
            }
            if let message {
                SettingsCaption(message, isError: true)
            }
        }
        .confirmationDialog(
            "Delete the \(name) model?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download it again later.")
        }
    }

    @ViewBuilder
    private func trailing(name: String) -> some View {
        switch state {
        case .notInstalled:
            Button("Download", action: download)
                .accessibilityLabel("Download the \(name) model, \(Self.size(of: model))")
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .accessibilityLabel("Downloading the \(name) model")
                    .accessibilityValue(StatusText.percent(fraction))
                Text(verbatim: StatusText.percent(fraction))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Cancel", action: cancel)
                    .accessibilityLabel("Cancel the download of the \(name) model")
            }
        case .installed(let inUse):
            HStack(spacing: 8) {
                Label {
                    Text("Installed")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.callout)
                Button("Delete") { isConfirmingDelete = true }
                    .disabled(inUse)
                    .help(inUse ? "Pause listening to delete this model." : "Delete this model")
                    .accessibilityLabel("Delete the \(name) model")
            }
        }
    }

    // MARK: Words

    /// "Light · English", "Balanced · Multilingual".
    static func name(for model: WhisperModel) -> String {
        switch model {
        case .lightEnglish: "Light · English"
        case .lightMultilingual: "Light · Multilingual"
        case .balancedEnglish: "Balanced · English"
        case .balancedMultilingual: "Balanced · Multilingual"
        case .vad: "Speech detector"
        }
    }

    /// The download size in whole megabytes: "32 MB".
    static func size(of model: WhisperModel) -> String {
        let megabytes = max(1, Int((Double(ModelCatalog.descriptor(model).bytes) / 1_000_000).rounded()))
        return "\(megabytes) MB"
    }

    /// Under the name: the size, and that the model is in use.
    static func detail(for model: WhisperModel, state: ModelRowState) -> String {
        if case .installed(inUse: true) = state { return "\(size(of: model)) · In use" }
        return size(of: model)
    }
}

/// The downloads and deletions the Speech settings started, and what went wrong with them.
@MainActor
@Observable
final class ModelActions {
    /// Why the last download or delete of a model did not work.
    private(set) var messages: [WhisperModel: String] = [:]

    @ObservationIgnored private var downloads: [WhisperModel: Task<Void, Never>] = [:]

    func download(_ model: WhisperModel, using controller: ListeningController) {
        guard downloads[model] == nil else { return }
        messages[model] = nil
        downloads[model] = Task { [weak self] in
            do {
                try await controller.downloadModel(model)
            } catch is CancellationError {
                // Cancelled: what arrived is kept, and the next download goes on from there.
            } catch {
                self?.messages[model] = Self.message(for: error)
            }
            self?.downloads[model] = nil
        }
    }

    /// Stops a download. One this screen started is cancelled and keeps what has arrived; one that listening started
    /// (a local model is chosen and not installed yet) can only be stopped by removing the model.
    func cancel(_ model: WhisperModel, using controller: ListeningController) {
        messages[model] = nil
        if let task = downloads[model] {
            task.cancel()
        } else {
            Task { [weak self] in
                do {
                    try await controller.deleteModel(model)
                } catch {
                    self?.messages[model] = Self.message(for: error)
                }
            }
        }
    }

    func delete(_ model: WhisperModel, using controller: ListeningController) {
        messages[model] = nil
        Task { [weak self] in
            do {
                try await controller.deleteModel(model)
            } catch {
                self?.messages[model] = Self.message(for: error)
            }
        }
    }

    /// What to tell the user about a failed download or delete.
    static func message(for error: any Error) -> String {
        // `ListeningControllerError.modelInUse` already says what to do ("Pause listening or pick another model…").
        if let error = error as? ModelError {
            switch error {
            case .insufficientSpace(let required, let available):
                let needed = required.formatted(.byteCount(style: .file))
                let free = available.formatted(.byteCount(style: .file))
                return "Not enough free space: it needs \(needed) and \(free) is free."
            case .checksumMismatch, .sizeMismatch:
                return "The download was damaged and was removed. Try again."
            case .httpStatus(let status):
                return "The download server answered with HTTP \(status). Try again later."
            }
        }
        return error.localizedDescription
    }
}
