// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NameAlertKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "NameAlertKit",
            targets: ["NameAlertCore", "NameAlertAudio", "NameAlertSpeech", "NameAlertAlerts", "NameAlertRuntime"]
        ),
    ],
    targets: [
        // whisper.cpp official release xcframework (the only third-party dependency).
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),

        // Module graph: Core <- Audio, Speech, Alerts <- Runtime
        .target(
            name: "NameAlertCore",
            // The everyday-word list that Balanced matching uses, and SCOWL's license for it.
            // Regenerate both with scripts/build_common_words.sh.
            resources: [.copy("Resources/common-words-en.txt"), .copy("Resources/SCOWL-LICENSE.txt")]
        ),
        .target(name: "NameAlertAudio", dependencies: ["NameAlertCore"]),
        .target(name: "NameAlertSpeech", dependencies: ["NameAlertCore", "whisper"]),
        .target(name: "NameAlertAlerts", dependencies: ["NameAlertCore"]),
        .target(
            name: "NameAlertRuntime",
            dependencies: ["NameAlertCore", "NameAlertAudio", "NameAlertSpeech", "NameAlertAlerts"]
        ),

        // Tests also depend on sibling modules for converters and fakes.
        .testTarget(name: "NameAlertCoreTests", dependencies: ["NameAlertCore"]),
        .testTarget(name: "NameAlertAudioTests", dependencies: ["NameAlertAudio", "NameAlertCore"]),
        .testTarget(name: "NameAlertSpeechTests", dependencies: ["NameAlertSpeech", "NameAlertAudio", "NameAlertCore"]),
        .testTarget(name: "NameAlertAlertsTests", dependencies: ["NameAlertAlerts", "NameAlertCore"]),
        .testTarget(
            name: "NameAlertRuntimeTests",
            dependencies: ["NameAlertRuntime", "NameAlertAlerts", "NameAlertSpeech", "NameAlertAudio", "NameAlertCore"]
        ),
    ]
)
