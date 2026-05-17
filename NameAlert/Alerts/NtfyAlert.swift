import Foundation

/// Pushes a notification to a phone via ntfy.sh (or a self-hosted ntfy instance).
struct NtfyAlert: Alert {
    let id = "ntfy"
    let displayName = "ntfy.sh Push"

    /// Server base URL, e.g. "https://ntfy.sh".
    let server: String
    /// Topic name (the path component after the server URL).
    let topic: String
    /// Optional bearer token for protected topics.
    let authToken: String?

    func fire(reason: Hit) async {
        guard !topic.isEmpty,
              var components = URLComponents(string: server) else { return }
        let basePath = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = basePath + topic
        guard let url = components.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Heard \(reason.keyword)", forHTTPHeaderField: "Title")
        req.setValue("urgent", forHTTPHeaderField: "Priority")
        req.setValue("bell", forHTTPHeaderField: "Tags")
        if let token = authToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = reason.matchedText.data(using: .utf8)

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("NtfyAlert HTTP \(http.statusCode)")
            }
        } catch {
            NSLog("NtfyAlert failed: \(error.localizedDescription)")
        }
    }
}
