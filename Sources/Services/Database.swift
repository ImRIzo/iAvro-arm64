import Foundation
import os
import SQLite3

/// Dictionary of Bangla words. Immutable after init, so `find(term:)` may be
/// called from any thread (the controller runs it on a background queue).
final class Database: @unchecked Sendable {
    static let shared = Database()

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.omicronlab.avro", category: "Database")

    /// Set with: defaults write com.omicronlab.inputmethod.AvroKeyboard VerifyDictionaryEngine -bool YES
    /// Every lookup is then also run through the old NSRegularExpression scan and compared.
    static let verifyDefaultsKey = "VerifyDictionaryEngine"

    private static let tableNames = [
        "A", "AA", "B", "BH", "C", "CH", "D", "Dd", "Ddh", "Dh",
        "E", "G", "Gh", "H", "I", "II", "J", "JH", "K", "KH",
        "Khandatta", "L", "M", "N", "NGA", "NN", "NYA", "O", "OI",
        "OU", "P", "PH", "R", "RR", "RRH", "RRI", "S", "SH", "SS",
        "T", "TH", "TT", "TTH", "U", "UU", "Y", "Z"
    ]

    private let tables: [String: WordTable]
    private let suffixes: [String: String]

    private init() {
        let started = ContinuousClock.now
        guard let filePath = Bundle.main.path(forResource: "database", ofType: "db3") else {
            fatalError("database.db3 not found in bundle")
        }

        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(filePath, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let dbHandle = dbPointer else {
            fatalError("Failed to open database.db3")
        }
        defer { sqlite3_close(dbHandle) }

        var source = "avrodict.bin"
        if let url = Bundle.main.url(forResource: "avrodict", withExtension: "bin"),
           let loaded = DictionaryFile.load(url),
           Self.tableNames.allSatisfy({ loaded[$0.lowercased()] != nil }) {
            self.tables = loaded
        } else {
            // Fallback: read SQLite and sort in memory (slower start-up, same results).
            source = "database.db3"
            var loaded: [String: WordTable] = [:]
            for name in Self.tableNames {
                loaded[name.lowercased()] = WordTable(words: Self.loadTable(name: name, from: dbHandle))
            }
            self.tables = loaded
        }
        self.suffixes = Self.loadSuffixTable(from: dbHandle)

        let words = tables.values.reduce(0) { $0 + $1.count }
        Self.log.info("Dictionary loaded from \(source, privacy: .public): \(words) words in \((ContinuousClock.now - started).milliseconds, format: .fixed(precision: 1)) ms")
    }

    private static func loadTable(name: String, from dbHandle: OpaquePointer) -> [String] {
        var items: [String] = []
        let query = "SELECT Words FROM \(name)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, query, -1, &stmt, nil) == SQLITE_OK else { return items }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                items.append(String(cString: cString))
            }
        }
        return items
    }

    private static func loadSuffixTable(from dbHandle: OpaquePointer) -> [String: String] {
        var result: [String: String] = [:]
        let query = "SELECT English, Bangla FROM Suffix"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, query, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let eng = sqlite3_column_text(stmt, 0), let bng = sqlite3_column_text(stmt, 1) {
                result[String(cString: eng)] = String(cString: bng)
            }
        }
        return result
    }

    /// All dictionary words matching the phonetic pattern of `term`.
    func find(term: String) -> [String] {
        guard let lmc = term.lowercased().first else { return [] }
        let names = Self.tableLookup[lmc] ?? []
        guard !names.isEmpty else { return [] }

        let started = ContinuousClock.now
        let pattern = RegexParser.shared.parse(term)
        var result = Set<String>()
        var engine = "trie"

        if let dfa = try? LazyDFA(pattern: pattern) {
            for name in names {
                tables[name]?.search(dfa, into: &result)
            }
        } else {
            engine = "regex-fallback"
            result = legacyFind(pattern: pattern, tableNames: names)
        }

        Self.log.debug("find \(term, privacy: .public) [\(engine, privacy: .public)] → \(result.count) words, \((ContinuousClock.now - started).milliseconds, format: .fixed(precision: 2)) ms")

        if engine == "trie", UserDefaults.standard.bool(forKey: Self.verifyDefaultsKey) {
            let refStart = ContinuousClock.now
            let reference = legacyFind(pattern: pattern, tableNames: names)
            let refMs = (ContinuousClock.now - refStart).milliseconds
            if reference == result {
                Self.log.info("verify \(term, privacy: .public): OK (\(result.count) words; old engine took \(refMs, format: .fixed(precision: 2)) ms)")
            } else {
                let missing = reference.subtracting(result).prefix(5).joined(separator: " ")
                let extra = result.subtracting(reference).prefix(5).joined(separator: " ")
                Self.log.error("verify \(term, privacy: .public): MISMATCH missing=[\(missing, privacy: .public)] extra=[\(extra, privacy: .public)]")
            }
        }
        return Array(result)
    }

    /// The original algorithm, kept for verification and benchmarking (`make check`).
    func findUsingRegex(term: String) -> [String] {
        guard let lmc = term.lowercased().first, let names = Self.tableLookup[lmc] else { return [] }
        return Array(legacyFind(pattern: RegexParser.shared.parse(term), tableNames: names))
    }

    /// The original algorithm: run `^pattern$` against every word.
    private func legacyFind(pattern: String, tableNames: [String]) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$") else { return [] }
        var suggestions = Set<String>()
        for name in tableNames {
            guard let table = tables[name] else { continue }
            for k in 0..<table.count {
                let word = table.word(at: k)
                let range = NSRange(location: 0, length: (word as NSString).length)
                if regex.firstMatch(in: word, range: range) != nil {
                    suggestions.insert(word)
                }
            }
        }
        return suggestions
    }

    func banglaForSuffix(_ suffix: String) -> String? {
        suffixes[suffix]
    }

    private static let tableLookup: [Character: [String]] = [
        "a": ["a", "aa", "e", "oi", "o", "nya", "y"],
        "b": ["b", "bh"],
        "c": ["c", "ch", "k"],
        "d": ["d", "dh", "dd", "ddh"],
        "e": ["i", "ii", "e", "y"],
        "f": ["ph"],
        "g": ["g", "gh", "j"],
        "h": ["h"],
        "i": ["i", "ii", "y"],
        "j": ["j", "jh", "z"],
        "k": ["k", "kh"],
        "l": ["l"],
        "m": ["h", "m"],
        "n": ["n", "nya", "nga", "nn"],
        "o": ["a", "u", "uu", "oi", "o", "ou", "y"],
        "p": ["p", "ph"],
        "q": ["k"],
        "r": ["rri", "h", "r", "rr", "rrh"],
        "s": ["s", "sh", "ss"],
        "t": ["t", "th", "tt", "tth", "khandatta"],
        "u": ["u", "uu", "y"],
        "v": ["bh"],
        "w": ["o"],
        "x": ["e", "k"],
        "y": ["i", "y"],
        "z": ["h", "j", "jh", "z"],
    ]
}
