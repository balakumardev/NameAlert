import Foundation

/// A rough "how does it sound" key for a name, tuned for names across languages. Spellings that sound alike
/// share a key: Bala, Bhala and Balla are all `b*l*`; Priyanka and Pryanka are `pr*nk*`.
public enum NameKey {
    /// The key for one word. Pass a word that is already normalized; case, accents and width are folded anyway.
    ///
    /// 1. Fold to lowercase without accents and keep letters only.
    /// 2. Replace digraphs (`ph` `bh` `dh` `th` `kh` `gh` `jh` `ch` `sh` `ck` `qu`), then `x` with `ks`.
    /// 3. Map `c q z w y` to `k k s v i`.
    /// 4. Drop every `h` except a first letter.
    /// 5. Collapse runs of the same letter.
    /// 6. Keep the first letter and turn each later run of vowels into one `*`.
    ///
    /// Only ASCII letters take part in steps 2 to 6. Letters of other scripts keep their marks (the vowel signs
    /// of Devanagari, say) and are otherwise left as they are. A word with a digit in it has no sound to
    /// compare, so it is returned as it came.
    public static func key(_ token: String) -> String {
        if token.unicodeScalars.contains(where: isNumber) { return token }

        let letters = Array(TextNormalizer.fold(token).unicodeScalars.filter(isLetterOrMark))  // step 1
        let digraphsReplaced = replaceDigraphs(in: letters)  // step 2
        let respelled = digraphsReplaced.map(soundAlike)  // step 3
        let withoutInnerH = dropInnerH(in: respelled)  // step 4
        let collapsed = collapseRuns(in: withoutInnerH)  // step 5
        return String(maskVowels(in: collapsed))  // step 6
    }

    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return (0x30...0x39).contains(scalar.value) }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// A letter, or a mark that follows one. Folding has already removed the accents of Latin, Greek and Cyrillic,
    /// so the marks left are ones a script needs to spell its words.
    private static func isLetterOrMark(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return (0x61...0x7A).contains(scalar.value) }  // already lowercased
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isVowel(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a", "e", "i", "o", "u": true
        default: false
        }
    }

    /// Each pair is read left to right and replaced by one letter; the other letters stay.
    private static let digraphs: [(first: Unicode.Scalar, second: Unicode.Scalar, replacement: Unicode.Scalar)] = [
        ("p", "h", "f"), ("b", "h", "b"), ("d", "h", "d"), ("t", "h", "t"), ("k", "h", "k"),
        ("g", "h", "g"), ("j", "h", "j"), ("c", "h", "c"), ("s", "h", "s"), ("c", "k", "k"), ("q", "u", "k"),
    ]

    private static func replaceDigraphs(in letters: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(letters.count + 1)
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            if index + 1 < letters.count,
                let digraph = digraphs.first(where: { $0.first == letter && $0.second == letters[index + 1] })
            {
                result.append(digraph.replacement)
                index += 2
            } else if letter == "x" {
                result.append(contentsOf: ["k", "s"])
                index += 1
            } else {
                result.append(letter)
                index += 1
            }
        }
        return result
    }

    private static func soundAlike(_ letter: Unicode.Scalar) -> Unicode.Scalar {
        switch letter {
        case "c", "q": "k"
        case "z": "s"
        case "w": "v"
        case "y": "i"
        default: letter
        }
    }

    private static func dropInnerH(in letters: [Unicode.Scalar]) -> [Unicode.Scalar] {
        letters.enumerated().filter { $0.offset == 0 || $0.element != "h" }.map(\.element)
    }

    private static func collapseRuns(in letters: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        for letter in letters where result.last != letter { result.append(letter) }
        return result
    }

    private static func maskVowels(in letters: [Unicode.Scalar]) -> String.UnicodeScalarView {
        var result = String.UnicodeScalarView()
        for (index, letter) in letters.enumerated() {
            if index > 0, isVowel(letter) {
                if result.last != "*" { result.append("*") }
            } else {
                result.append(letter)
            }
        }
        return result
    }
}
