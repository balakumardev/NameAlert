import Foundation

/// Scrubs what identifies the person out of diagnostic text and crash JSON: the account's short name in
/// home-folder paths. Local-only; nothing here sends anything.
public enum DiagnosticRedaction {
    /// `/Users/<name>` (or JSON-escaped `\/Users\/<name>`). The name ends at a slash, whitespace, a quote, a bracket
    /// or a backslash. Case-insensitive (APFS is). `<` and `>` end a name too, so redacted text redacts to itself.
    private static let userPath = try! NSRegularExpression(
        pattern: #"(\\?/)users(\\?/)[^/\s"'`<>()\[\]{}:;,|\\]+"#,
        options: [.caseInsensitive]
    )

    /// `text` with every `/Users/<name>` replaced by `/Users/<redacted>`. Escaped slashes stay escaped.
    public static func redactingUserPaths(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return userPath.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "$1Users$2<redacted>"
        )
    }

    /// `value` with the path redaction applied to every string, and to every object key. Redact after decoding,
    /// so a path written with escaped slashes in the raw text is still found.
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(redactingUserPaths(text))
        case .array(let items):
            return .array(items.map(redact))
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, field) in fields {
                result[redactingUserPaths(key)] = redact(field)
            }
            return .object(result)
        case .null, .bool, .int, .double:
            return value
        }
    }
}
