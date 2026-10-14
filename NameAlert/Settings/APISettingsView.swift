import AppKit
import NameAlertAlerts
import SwiftUI

/// Settings → Shortcuts & API: the links that control the app from outside, the actions it adds to Shortcuts, and what
/// a webhook receives, including how to check its signature.
struct APISettingsView: View {
    var body: some View {
        Form {
            urlSchemeSection
            shortcutsSection
            webhookSection
            signatureSection
        }
        .formStyle(.grouped)
    }

    // MARK: URL scheme

    private var urlSchemeSection: some View {
        Section {
            ForEach(APIReference.routes, id: \.url) { route in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: route.url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        SettingsCaption(route.summary)
                    }
                    Spacer(minLength: 8)
                    CopyButton(text: route.url, what: route.url)
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            SettingsSectionTitle("URL scheme")
        } footer: {
            SettingsCaption(
                "Open these from a script, a browser or another app. None of them changes your rules or alerts.")
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section {
            ForEach(APIReference.shortcutActions, id: \.name) { action in
                LabeledContent {
                    Text(verbatim: action.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(verbatim: action.name)
                }
                .accessibilityElement(children: .combine)
            }
            Button("Open Shortcuts") { Self.openShortcuts() }
                .accessibilityLabel("Open the Shortcuts app")
        } header: {
            SettingsSectionTitle("Shortcuts")
        } footer: {
            SettingsCaption(
                "\(AppInfo.displayName) adds these actions to Shortcuts, so you can use them in your own shortcuts, from Spotlight, or with Siri.")
        }
    }

    /// Opens the Shortcuts app.
    static func openShortcuts() {
        guard let url = URL(string: "shortcuts://") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Webhook

    private var webhookSection: some View {
        Section {
            CodeBlock(
                title: "Request", code: APIReference.requestExample(version: AppInfo.version),
                what: "the webhook request example")
            CodeBlock(
                title: "Body", code: APIReference.payloadExample(version: AppInfo.version, build: AppInfo.build),
                what: "the webhook payload example")
        } header: {
            SettingsSectionTitle("Webhook")
        } footer: {
            SettingsCaption(
                "When a rule alerts with Webhook, \(AppInfo.displayName) sends this to your address with a POST. Set it up in Alerts.")
        }
    }

    // MARK: Signature

    private var signatureSection: some View {
        Section {
            CodeBlock(title: nil, code: APIReference.signatureSnippet, what: "the signature check")
        } header: {
            SettingsSectionTitle("Check the signature")
        } footer: {
            SettingsCaption(
                "With a signing secret set, each request has an \(WebhookHeader.signature) header like t=1760175000,v1=<hex>. Sign the body exactly as you received it, before any JSON parsing.")
        }
    }
}

/// A piece of code on a gray panel: monospaced and selectable, with a button that copies it.
struct CodeBlock: View {
    let title: String?
    let code: String
    /// What the copy button copies, in words.
    let what: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .padding(.trailing, 24)  // room for the copy button
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    CopyButton(text: code, what: what)
                        .padding(6)
                }
        }
    }
}

/// What the pane tells: the links, the Shortcuts actions, and an example of what a webhook gets.
enum APIReference {
    struct Route: Equatable {
        let url: String
        let summary: String
    }

    struct ShortcutAction: Equatable {
        let name: String
        let summary: String
    }

    /// Every `takeheed://` link, in the order the pane lists them. `URLRoute(url:)` reads each one.
    static let routes: [Route] = [
        Route(url: "takeheed://start", summary: "Start listening."),
        Route(url: "takeheed://pause", summary: "Pause listening."),
        Route(url: "takeheed://toggle", summary: "Start if paused, pause if listening."),
        Route(url: "takeheed://resume", summary: "End a snooze and listen again."),
        Route(url: "takeheed://snooze?minutes=30", summary: "Snooze alerts. Minutes: 1 to 1440, 30 if left out."),
        Route(url: "takeheed://open/settings", summary: "Open Settings."),
        Route(url: "takeheed://open/history", summary: "Open History."),
        Route(url: "takeheed://open/live", summary: "Open the live transcript."),
    ]

    /// The actions in the Shortcuts app.
    static let shortcutActions: [ShortcutAction] = [
        ShortcutAction(name: "Start Listening", summary: "Start listening."),
        ShortcutAction(name: "Pause Listening", summary: "Pause listening."),
        ShortcutAction(name: "Toggle Listening", summary: "Start or pause."),
        ShortcutAction(name: "Snooze Alerts", summary: "Snooze for 1 to 1440 minutes."),
        ShortcutAction(name: "Add Keyword", summary: "Listen for a new word or phrase."),
        ShortcutAction(name: "Set Rule Enabled", summary: "Turn a rule on or off."),
        ShortcutAction(name: "Get Recent Hits", summary: "The latest mentions."),
        ShortcutAction(name: "Get Status", summary: "What \(AppInfo.displayName) is doing."),
    ]

    /// The check a receiver makes to know a request came from Takeheed.
    static let signatureSnippet = """
        expected = hex(HMAC_SHA256(secret, t + "." + raw_body))
        compare with the v1 value in \(WebhookHeader.signature)
        """

    /// The head of a webhook request: the headers it carries.
    static func requestExample(version: String) -> String {
        """
        POST https://example.com/your-hook
        Content-Type: application/json
        User-Agent: \(WebhookHeader.userAgent(version: version))
        \(WebhookHeader.event): keyword.detected
        \(WebhookHeader.signature): t=1760175000,v1=<hex>
        """
    }

    /// The body of a webhook request.
    static func payloadExample(version: String, build: String) -> String {
        """
        {
          "event": "keyword.detected",
          "version": 1,
          "id": "6F0F1A2B-…",
          "timestamp": "2026-10-11T09:30:00Z",
          "rule": { "id": "…", "name": "My name" },
          "term": "Bala",
          "matchedText": "Bala",
          "context": "…can Bala share the deck…",
          "source": "systemAudio",
          "engine": "appleSpeechTranscriber",
          "app": { "version": "\(version)", "build": "\(build)" },
          "excerpt": "…what do you think, Bala, can you share the deck…"
        }
        """
    }
}
