import Foundation

/// Triggers a free Telegram voice call via CallMeBot's TTS endpoint.
/// User must first authorize @CallMeBot_txtbot on Telegram.
struct CallMeBotAlert: Alert {
    let id = "callmebot"
    let displayName = "CallMeBot Telegram"

    /// Telegram username (with or without leading "@") or +<E.164> phone number.
    let user: String
    /// TTS message template. `{keyword}` and `{text}` are substituted.
    let messageTemplate: String
    /// Voice/locale for TTS (e.g. "en-US-Standard-B").
    let language: String

    func fire(reason: Hit) async {
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else { return }
        let userParam = trimmedUser.hasPrefix("@") || trimmedUser.hasPrefix("+")
            ? trimmedUser
            : "@" + trimmedUser

        let message = messageTemplate
            .replacingOccurrences(of: "{keyword}", with: reason.keyword)
            .replacingOccurrences(of: "{text}", with: reason.matchedText)

        var components = URLComponents(string: "https://api.callmebot.com/start.php")
        components?.queryItems = [
            URLQueryItem(name: "user", value: userParam),
            URLQueryItem(name: "text", value: message),
            URLQueryItem(name: "lang", value: language)
        ]
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("CallMeBotAlert HTTP \(http.statusCode)")
            }
        } catch {
            NSLog("CallMeBotAlert failed: \(error.localizedDescription)")
        }
    }
}
