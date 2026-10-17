import Foundation
@testable import NameAlertCore
import Testing

@Suite("CrashSignature")
struct CrashSignatureTests {
    private let own: Set<String> = ["Takeheed", "Takeheed.debug.dylib", "NameAlertKit"]

    private func sig(_ data: Data) -> String? {
        CrashSignature.compute(diagnosticJSON: data, ownBinaries: own)
    }

    @Test func isSixteenHexAndStableAcrossASLR() throws {
        let a = DiagnosticsFixtures.crashJSON(frames: [("libsystem", 1, 0x1000), ("Takeheed", 40, 0x2000), ("Takeheed", 80, 0x3000)])
        let b = DiagnosticsFixtures.crashJSON(frames: [("libsystem", 1, 0x9000), ("Takeheed", 40, 0xA000), ("Takeheed", 80, 0xB000)])
        let s = try #require(sig(a))
        #expect(s.count == 16)
        #expect(s.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(s == sig(b))
    }

    @Test func ignoresSystemFramesButNotOwnOffsets() {
        let a = DiagnosticsFixtures.crashJSON(frames: [("libsystem", 1, 0), ("Takeheed", 40, 0)])
        let b = DiagnosticsFixtures.crashJSON(frames: [("libother", 99, 0), ("Takeheed", 40, 0)])
        let c = DiagnosticsFixtures.crashJSON(frames: [("libsystem", 1, 0), ("Takeheed", 41, 0)])
        #expect(sig(a) == sig(b))
        #expect(sig(a) != sig(c))
    }

    @Test func onlyFirstFiveOwnFramesCount() {
        let base: [(String, Int, Int)] = (0..<5).map { ("Takeheed", $0, 0) }
        let a = DiagnosticsFixtures.crashJSON(frames: base + [("Takeheed", 100, 0)])
        let b = DiagnosticsFixtures.crashJSON(frames: base + [("Takeheed", 200, 0)])
        #expect(sig(a) == sig(b))
    }

    @Test func fallsBackToAnyBinaryWhenNoOwnFrames() {
        let a = DiagnosticsFixtures.crashJSON(frames: [("libA", 1, 0), ("libB", 2, 0)])
        let b = DiagnosticsFixtures.crashJSON(frames: [("libA", 1, 0), ("libB", 3, 0)])
        #expect(sig(a) != nil)
        #expect(sig(a) != sig(b))
    }

    @Test func exceptionTypeAndSignalMatter() {
        let frames: [(String, Int, Int)] = [("Takeheed", 1, 0)]
        #expect(sig(DiagnosticsFixtures.crashJSON(frames: frames, signal: 6)) != sig(DiagnosticsFixtures.crashJSON(frames: frames, signal: 11)))
    }

    @Test func nonObjectIsNil() {
        #expect(sig(Data("[1]".utf8)) == nil)
        #expect(sig(Data("nope".utf8)) == nil)
    }

    @Test func ownBinaryNamesAcceptDebugDylibAndFrameworks() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let macOS = dir.appendingPathComponent("MacOS")
            let frameworks = dir.appendingPathComponent("Frameworks")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: frameworks.appendingPathComponent("Kit.framework"), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: macOS.appendingPathComponent("Other.debug.dylib").path, contents: Data())
            let names = CrashSignature.ownBinaryNames(
                executableURL: macOS.appendingPathComponent("Takeheed"), privateFrameworksURL: frameworks
            )
            #expect(names == ["Takeheed", "Takeheed.debug.dylib", "Other.debug.dylib", "Kit"])
        }
    }
}
