import Foundation
@testable import NameAlertCore  // the word list and the vowel-keeping key are internal
import Testing

@Suite("BalancedGuards")
struct BalancedGuardsTests {
    @Test func commonWordsLoaded() {
        #expect(CommonWords.contains("share"))
        #expect(!CommonWords.contains("bhala"))
    }

    @Test(arguments: ["the", "make", "seven", "names", "stack", "grand", "brain", "than"])
    func everydayWordsAreInTheList(word: String) {
        #expect(CommonWords.contains(word))
    }

    @Test(arguments: ["bala", "bhala", "balla", "baala", "jhon", "sara", "pryanka", "krishna", "standups", "", "A", "Share"])
    func namesAndOddSpellingsAreNotInTheList(word: String) {
        #expect(!CommonWords.contains(word))
    }

    /// The list holds only what the generator keeps: lowercase a to z, at least two letters. It is read from the
    /// bundled file, so this also checks the file.
    @Test func listIsLowercaseLettersOnly() throws {
        let url = try #require(CommonWords.bundledFile("common-words-en", extension: "txt"))
        let words = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        #expect(words.count > 30_000)
        #expect(words.allSatisfy { $0.utf8.count >= 2 && $0.utf8.allSatisfy { (0x61...0x7A).contains($0) } })
        #expect(words == words.sorted(), "sorted")
        #expect(Set(words).count == words.count, "no repeats")
    }

    @Test func licenseTravelsWithTheList() throws {
        let url = try #require(CommonWords.bundledFile("SCOWL-LICENSE", extension: "txt"))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.contains("Kevin Atkinson"))
        #expect(text.contains("Permission to use, copy, modify, distribute and sell these word"))
    }

    /// Steps 1 to 5 of the key: spellings of one name still agree, a different vowel no longer does.
    @Test(arguments: [
        ("bala", "bala"), ("bhala", "bala"), ("balla", "bala"), ("baala", "bala"),
        ("john", "jon"), ("jhon", "jon"), ("seth", "set"), ("mike", "mike"), ("make", "make"),
        ("priya", "pria"), ("a1b", "a1b"), ("", ""),
    ])
    func keyThatKeepsVowels(token: String, expected: String) {
        #expect(NameKey.key(token, keepVowels: true) == expected)
    }

    @Test(arguments: ["bala", "priyanka", "chris", "Müller", "alex", "zoe", "42"])
    func theKeyThatFoldsVowelsIsTheUsualOne(token: String) {
        #expect(NameKey.key(token, keepVowels: false) == NameKey.key(token))
    }

    @Test func vowelsDecideBetweenShortNamesAndWordsThatSoundLikeThem() {
        for (term, heard) in [("mike", "make"), ("luke", "like"), ("nina", "nine"), ("jane", "june")] {
            #expect(NameKey.key(term) == NameKey.key(heard), "same key once the vowels are folded: \(term) \(heard)")
            #expect(NameKey.key(term, keepVowels: true) != NameKey.key(heard, keepVowels: true), "\(term) \(heard)")
        }
    }
}
