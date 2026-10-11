import Foundation

/// Turns text from the settings and from hits into text that can go into a request.
enum WireText {
    /// `text` without the spaces and line breaks around it, the way `ChannelSettings.isConfigured` reads it.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `value` as the value of a query item. `URLQueryItem` leaves `+` as it is, and a server reads that as a space,
    /// so a phone number would lose its plus; here `+`, `&`, `=` and `;` are written out, as is everything else that
    /// is not allowed in a query.
    static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+;")
        return allowed
    }()

    /// Whether `name` can be the name of an HTTP header: letters, digits and a few signs (RFC 9110 "token").
    static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { headerNameCharacters.contains($0) }
    }

    private static let headerNameCharacters: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "!#$%&'*+-.^_`|~")
        return allowed
    }()
}
