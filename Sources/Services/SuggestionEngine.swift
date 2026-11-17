import Foundation

@MainActor
final class SuggestionEngine {
    static let shared = SuggestionEngine()

    private init() {}

    /// - Parameter dictionaryWords: dictionary matches for the term, or nil when the
    ///   (background) lookup hasn't finished yet. A list built without dictionary
    ///   words is provisional and is not cached.
    func getList(
        _ term: String,
        dictionaryWords: (String) -> [String]? = { Database.shared.find(term: $0) }
    ) -> [String] {
        guard !term.isEmpty else { return [] }

        var suggestions: [String] = []
        var suggestionSet: Set<String> = []
        let parsedString = AvroParser.shared.parse(term)

        if UserDefaults.standard.bool(for: .includeDictionary) {
            // Check phonetic cache first
            if let cached = CacheManager.shared.array(forKey: term), !cached.isEmpty {
                suggestions.append(contentsOf: cached)
                suggestionSet.formUnion(cached)
            } else {
                // AutoCorrect suggestions
                let autoCorrect = AutoCorrect.shared.find(term)
                if let ac = autoCorrect {
                    suggestions.append(ac)
                    suggestionSet.insert(ac)
                }

                // Dictionary suggestions sorted by Levenshtein distance
                if let dicList = dictionaryWords(term) {
                    if let ac = autoCorrect, dicList.contains(ac) {
                        suggestions.removeAll { $0 == ac }
                        suggestionSet.remove(ac)
                    }

                    let sorted = Self.sortedByDistance(dicList, to: parsedString)
                    suggestions.append(contentsOf: sorted)
                    suggestionSet.formUnion(sorted)

                    CacheManager.shared.setArray(suggestions, forKey: term)
                }
            }

            // Suffix-based suggestions
            var alreadySelected = false
            CacheManager.shared.removeAllBase()
            for i in stride(from: term.count - 1, through: 1, by: -1) {
                let suffixIndex = term.index(term.startIndex, offsetBy: i)
                let suffixStr = String(term[suffixIndex...]).lowercased()
                guard let suffix = Database.shared.banglaForSuffix(suffixStr) else { continue }

                let base = String(term[..<suffixIndex])
                guard let cached = CacheManager.shared.array(forKey: base) else { continue }

                var selected: String?
                if !alreadySelected {
                    selected = CacheManager.shared.string(forKey: base)
                }

                for item in cached {
                    // Skip AutoCorrect English entry
                    if base == item || item.isEmpty { continue }

                    let cutPos = item.index(before: item.endIndex)
                    let itemRMC = String(item[cutPos...])
                    let suffixLMC = String(suffix.prefix(1))

                    let word: String
                    if isVowel(itemRMC) && isKar(suffixLMC) {
                        word = "\(item)\u{09DF}\(suffix)"
                    } else if itemRMC == "\u{09CE}" {
                        word = "\(item[..<cutPos])\u{09A4}\(suffix)"
                    } else if itemRMC == "\u{0982}" {
                        word = "\(item[..<cutPos])\u{0999}\(suffix)"
                    } else {
                        word = "\(item)\(suffix)"
                    }

                    // Reverse suffix caching
                    CacheManager.shared.setBase([base, item], forKey: word)

                    if !suggestionSet.contains(word) {
                        if !alreadySelected, let sel = selected, item == sel {
                            if CacheManager.shared.string(forKey: term) == nil {
                                CacheManager.shared.setString(word, forKey: term)
                            }
                            alreadySelected = true
                        }
                        suggestions.append(word)
                        suggestionSet.insert(word)
                    }
                }
            }
        }

        if !suggestionSet.contains(parsedString) {
            suggestions.append(parsedString)
        }

        return suggestions
    }

    /// Compute each distance once (the old comparator recomputed it on every
    /// comparison); ties are broken alphabetically so the order is stable.
    private static func sortedByDistance(_ words: [String], to target: String) -> [String] {
        words
            .map { (word: $0, distance: target.levenshteinDistance(to: $0)) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.word < $1.word }
            .map(\.word)
    }

    private static let karSet: Set<Character> = [
        "\u{09BE}", "\u{09BF}", "\u{09C0}", "\u{09C1}", "\u{09C2}",
        "\u{09C3}", "\u{09C7}", "\u{09C8}", "\u{09CB}", "\u{09CC}", "\u{09C4}"
    ]

    private static let vowelSet: Set<Character> = [
        "\u{0985}", "\u{0986}", "\u{0987}", "\u{0988}", "\u{0989}",
        "\u{098A}", "\u{098B}", "\u{098F}", "\u{0990}", "\u{0993}",
        "\u{0994}", "\u{098C}", "\u{09E1}", "\u{09BE}", "\u{09BF}",
        "\u{09C0}", "\u{09C1}", "\u{09C2}", "\u{09C3}", "\u{09C7}",
        "\u{09C8}", "\u{09CB}", "\u{09CC}"
    ]

    private func isKar(_ letter: String) -> Bool {
        guard let char = letter.first else { return false }
        return Self.karSet.contains(char)
    }

    private func isVowel(_ letter: String) -> Bool {
        guard let char = letter.first else { return false }
        return Self.vowelSet.contains(char)
    }
}
