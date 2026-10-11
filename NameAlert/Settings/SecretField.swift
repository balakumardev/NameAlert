import NameAlertCore
import Observation
import SwiftUI

/// The secrets the settings write to the Keychain (the ntfy token, the webhook's signing secret and the values of its
/// headers), and what has been typed for them but not saved yet.
///
/// A secret is never read back to the screen: the model only knows whether one exists, and the field then shows
/// "Saved". Nothing here puts a secret in the configuration or in a log.
@MainActor
@Observable
final class SecretsModel {
    private let store: any SecretStore

    /// The accounts that have a secret in the store.
    private(set) var saved: Set<String> = []
    /// What has been typed for an account and not saved yet.
    var drafts: [String: String] = [:]
    /// Why the last save or clear for an account did not work, in words for the user.
    private(set) var errors: [String: String] = [:]

    init(store: any SecretStore = KeychainSecretStore()) {
        self.store = store
    }

    func isSaved(_ account: String) -> Bool {
        saved.contains(account)
    }

    /// Looks up which of `accounts` have a secret. The values are dropped at once.
    func refresh(_ accounts: [String]) {
        for account in accounts {
            if store.secret(for: account) != nil {
                saved.insert(account)
            } else {
                saved.remove(account)
            }
        }
    }

    /// Saves what has been typed for `account`, replacing the secret that was there. Surrounding spaces and line
    /// breaks (the ones that come along with a paste) are not part of it. Typing nothing keeps the secret as it is.
    func commit(_ account: String) {
        guard let typed = drafts[account] else { return }
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            drafts[account] = nil
            return
        }
        do {
            try store.setSecret(value, for: account)
            saved.insert(account)
            errors[account] = nil
            drafts[account] = nil
        } catch {
            // The draft stays, so that it can be saved again.
            errors[account] = "Couldn't save to the Keychain. \(error.localizedDescription)"
        }
    }

    /// Saves everything typed and not saved yet: what a Test button must use.
    func commitAll() {
        for account in drafts.keys.sorted() { commit(account) }
    }

    /// Deletes the secret for `account`, and whatever was typed for it.
    func clear(_ account: String) {
        drafts[account] = nil
        do {
            try store.setSecret(nil, for: account)
            saved.remove(account)
            errors[account] = nil
        } catch {
            errors[account] = "Couldn't remove it from the Keychain. \(error.localizedDescription)"
        }
    }
}

/// A password-style field for a secret. It shows "Saved" when there is one, never the secret itself, and saves what
/// is typed when the user presses Return or leaves the field. `accessory` goes after the field and its Clear button.
struct SecretField<Accessory: View>: View {
    let title: String
    let account: String
    /// What the empty field says when there is no secret yet.
    let emptyPrompt: String
    /// Whether a Clear button shows next to a saved secret.
    let allowsClear: Bool
    let accessory: Accessory

    @Environment(SecretsModel.self) private var secrets
    @FocusState private var isFocused: Bool

    init(
        title: String, account: String, emptyPrompt: String = "Optional", allowsClear: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.account = account
        self.emptyPrompt = emptyPrompt
        self.allowsClear = allowsClear
        self.accessory = accessory()
    }

    var body: some View {
        let isSaved = secrets.isSaved(account)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    SecureField(
                        title,
                        text: Binding(get: { secrets.drafts[account] ?? "" }, set: { secrets.drafts[account] = $0 }),
                        prompt: Text(isSaved ? "Saved" : emptyPrompt).foregroundStyle(.secondary)
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .focused($isFocused)
                    .onSubmit { secrets.commit(account) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { secrets.commit(account) }
                    }
                    .onDisappear { secrets.commit(account) }
                    .accessibilityLabel(title)
                    .accessibilityValue(isSaved ? "Saved" : "Not set")
                    if isSaved, allowsClear {
                        Button("Clear") { secrets.clear(account) }
                            .controlSize(.small)
                            .accessibilityLabel("Clear \(title)")
                    }
                    accessory
                }
                .frame(maxWidth: .infinity)
            }
            if let error = secrets.errors[account] {
                SettingsCaption(error, isError: true)
            }
        }
    }
}

extension SecretField where Accessory == EmptyView {
    init(title: String, account: String, emptyPrompt: String = "Optional", allowsClear: Bool = true) {
        self.init(title: title, account: account, emptyPrompt: emptyPrompt, allowsClear: allowsClear) { EmptyView() }
    }
}
