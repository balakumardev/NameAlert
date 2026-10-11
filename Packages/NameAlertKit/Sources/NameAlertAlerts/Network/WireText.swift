import Foundation

/// Turns text from the settings and from hits into text that can go into a request.
enum WireText {
    /// `text` without the spaces and line breaks around it, the way `ChannelSettings.isConfigured` reads it.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `value` as RFC 2047 encoded words, for a header that holds characters beyond ASCII; `nil` when it is plain
    /// ASCII and can be sent as it is.
    ///
    /// The words are base64 UTF-8, at most 75 characters each and joined by a space, which a reader joins up again.
    /// ntfy reads them in its headers. (Characters beyond ASCII cannot be sent in a header as they are: URLSession cuts
    /// the value at a curly quote, for one, over HTTP/1.1, and leaves the header out over HTTP/2.)
    static func encodedWords(_ value: String) -> String? {
        guard !value.allSatisfy(\.isASCII) else { return nil }
        // 45 bytes make 60 base64 characters; with the 12 around them, that is 72. Cut between characters only.
        let bytesPerWord = 45
        var words: [String] = []
        var chunk: [UInt8] = []
        func closeWord() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
            chunk = []
        }
        for scalar in value.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if chunk.count + bytes.count > bytesPerWord { closeWord() }
            chunk += bytes
        }
        closeWord()
        return words.joined(separator: " ")
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
