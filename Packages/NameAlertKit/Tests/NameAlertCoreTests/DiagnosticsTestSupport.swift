import Foundation
@testable import NameAlertCore

enum DiagnosticsFixtures {
    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// A MetricKit-shaped crash. `frames` are (binary, offset, address) from the innermost frame outward.
    static func crashJSON(
        frames: [(String, Int, Int)],
        extraThreads: Int = 0,
        exceptionType: Int = 1,
        signal: Int = 6,
        note: String = ""
    ) -> Data {
        func tree(_ frames: ArraySlice<(String, Int, Int)>) -> [String: Any] {
            guard let first = frames.first else { return [:] }
            var node: [String: Any] = [
                "binaryName": first.0, "offsetIntoBinaryTextSegment": first.1, "address": first.2
            ]
            let rest = frames.dropFirst()
            if !rest.isEmpty { node["subFrames"] = [tree(rest)] }
            return node
        }
        var stacks: [[String: Any]] = [["threadAttributed": true, "callStackRootFrames": [tree(frames[...])]]]
        for index in 0..<extraThreads {
            stacks.append(["callStackRootFrames": [tree([("other", index, 0)][...])]])
        }
        let object: [String: Any] = [
            "diagnosticMetaData": [
                "exceptionType": exceptionType, "signal": signal, "appVersion": "1.2", "terminationReason": note
            ],
            "callStackTree": ["callStacks": stacks, "callStackPerThread": false]
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static let environment = ProblemReportEnvironment(
        appVersion: "1.0", build: "7", macOSVersion: "26.0", macModel: "Mac16,1", architecture: "arm64",
        engine: "apple", locale: "en_US@rg=gbzzzz", listeningSource: "system"
    )
}
