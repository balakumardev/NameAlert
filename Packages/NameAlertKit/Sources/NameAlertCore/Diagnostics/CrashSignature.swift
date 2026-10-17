import CryptoKit
import Foundation

/// A short name for where a crash happened, so the same crash from different Macs and runs has one signature.
public enum CrashSignature {
    /// How many frames of the crashed thread's stack count.
    static let frameCount = 5

    /// The suffix of the dylib a Debug build moves the app's code into.
    private static let debugDylibSuffix = ".debug.dylib"

    /// The binary names of this app's own code: the executable, its debug dylib, and embedded frameworks.
    public static let defaultOwnBinaries: Set<String> = ownBinaryNames(
        executableURL: Bundle.main.executableURL,
        privateFrameworksURL: Bundle.main.privateFrameworksURL
    )

    /// The executable's file name, `<executable>.debug.dylib` (named whether or not it exists), any other
    /// `*.debug.dylib` beside the executable, and each `*.framework` name in `privateFrameworksURL`.
    public static func ownBinaryNames(
        executableURL: URL?,
        privateFrameworksURL: URL?,
        fileManager: FileManager = .default
    ) -> Set<String> {
        var names = Set<String>()
        if let executableURL {
            names.insert(executableURL.lastPathComponent)
            names.insert(executableURL.lastPathComponent + debugDylibSuffix)
            let siblings = try? fileManager.contentsOfDirectory(
                at: executableURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
            )
            for entry in siblings ?? [] where entry.lastPathComponent.hasSuffix(debugDylibSuffix) {
                names.insert(entry.lastPathComponent)
            }
        }
        if let privateFrameworksURL,
           let entries = try? fileManager.contentsOfDirectory(at: privateFrameworksURL, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "framework" {
                names.insert(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return names
    }

    /// The signature of `diagnosticJSON` with this app's own binaries being `defaultOwnBinaries`.
    public static func compute(diagnosticJSON: Data) -> String? {
        compute(diagnosticJSON: diagnosticJSON, ownBinaries: defaultOwnBinaries)
    }

    /// SHA-256 over `<exceptionType>|<signal>|<binary>+<offset>|...`, first 16 lowercase hex characters (a missing
    /// number is `-`). The frames are the first five of the crashed thread (`threadAttributed`, else the first)
    /// whose binary is in `ownBinaries`; with none, the first five of any binary. Offsets into the binary, never
    /// addresses, so ASLR does not change it. MetricKit nests callers in `subFrames[0]`. Nil when the data is
    /// not a JSON object.
    public static func compute(diagnosticJSON: Data, ownBinaries: Set<String>) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: diagnosticJSON) as? [String: Any] else {
            return nil
        }
        let metadata = object["diagnosticMetaData"] as? [String: Any]
        let tree = object["callStackTree"] as? [String: Any]
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first

        var frames: [(binary: String?, offset: String)] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let current = frame {
            frames.append((current["binaryName"] as? String, integer(current["offsetIntoBinaryTextSegment"])))
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }

        let own = frames.filter { frame in frame.binary.map(ownBinaries.contains) ?? false }
        let counted = (own.isEmpty ? frames : own).prefix(frameCount)

        var parts = [integer(metadata?["exceptionType"]), integer(metadata?["signal"])]
        parts += counted.map { "\($0.binary ?? "-")+\($0.offset)" }

        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func integer(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "-" }
        return String(number.int64Value)
    }
}
