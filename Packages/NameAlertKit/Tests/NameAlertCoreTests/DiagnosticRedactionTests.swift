import Foundation
@testable import NameAlertCore
import Testing

@Suite("DiagnosticRedaction")
struct DiagnosticRedactionTests {
    @Test func redactsUserNameCaseInsensitively() {
        #expect(DiagnosticRedaction.redactingUserPaths("/Users/jane/Library/x") == "/Users/<redacted>/Library/x")
        #expect(DiagnosticRedaction.redactingUserPaths("open /USERS/Jane now") == "open /Users/<redacted> now")
    }

    @Test func isIdempotent() {
        let once = DiagnosticRedaction.redactingUserPaths("\"/Users/jane/a\" and \\/Users\\/jane\\/b")
        #expect(DiagnosticRedaction.redactingUserPaths(once) == once)
        #expect(once.contains("<redacted>"))
        #expect(!once.contains("jane"))
    }

    @Test func handlesEscapedSlashes() {
        let out = DiagnosticRedaction.redactingUserPaths(#"{"p":"\/Users\/jane\/Library"}"#)
        #expect(out == #"{"p":"\/Users\/<redacted>\/Library"}"#)
    }

    @Test func redactsDecodedKeysAndValues() throws {
        let raw = Data(#"{"\/Users\/jane\/key":["\/Users\/jane\/v",1,true,null]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: raw)
        let expected = JSONValue.object(["/Users/<redacted>/key": .array([.string("/Users/<redacted>/v"), .int(1), .bool(true), .null])])
        #expect(DiagnosticRedaction.redact(value) == expected)
        #expect(DiagnosticRedaction.redact(DiagnosticRedaction.redact(value)) == expected)
    }
}
