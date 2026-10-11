import Foundation

/// The everyday English words that Balanced matching will not take for a misheard name: "share" is a word, so it
/// is never "Shane".
///
/// The list is SCOWL (sizes 10, 20 and 35 of its english, american and british lists), keeping only entries made of
/// the lowercase letters a to z, at least two letters long. It is bundled as `common-words-en.txt`, one word per
/// line, with SCOWL's license beside it. `scripts/build_common_words.sh` builds both files.
enum CommonWords {
    /// Whether `token`, already normalized, is one of the words.
    static func contains(_ token: String) -> Bool {
        words.contains(token)
    }

    /// Read on first use, once. A `static let` is initialized exactly once, even when several threads ask at the
    /// same time.
    private static let words: Set<String> = load()

    private static func load() -> Set<String> {
        let words = readList()
        if words.isEmpty {
            // Without the list Balanced still matches, it just cannot tell an everyday word from a name. Say so once.
            Log.logger("matching").error(
                "The list of common words could not be read, so Balanced matching runs without it.")
        }
        return words
    }

    private static func readList() -> Set<String> {
        guard let url = bundledFile("common-words-en", extension: "txt"), let data = try? Data(contentsOf: url)
        else { return [] }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// A file declared as a resource of this module (the list, or its license). Depending on the toolchain,
    /// `.copy("Resources/…")` leaves the file at the top of the bundle or inside a `Resources` folder, so both are
    /// looked at.
    static func bundledFile(_ name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources")
    }
}
