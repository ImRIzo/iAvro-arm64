import Foundation

// Fast dictionary search for Avro Keyboard.
//
// The original engine compiled the phonetic regex for every keystroke and ran it
// against every word of the candidate tables (10–18k words each, ~160k total).
// Here the words are kept sorted by UTF-16 code unit, which makes the array behave
// like a trie: all words sharing a prefix are contiguous. The regex is compiled
// into an NFA, driven as a lazily-built DFA, and walked down that implicit trie —
// a whole subtree is skipped as soon as its prefix can no longer match.
// Results are identical to `^pattern$` matching with NSRegularExpression.

// MARK: - Tiny regex → Thompson NFA

struct MiniRegexUnsupported: Error {}

/// Compiles the regex subset that `RegexParser` produces: literals, `( )`, `|`,
/// `[...]` and the `?` quantifier. Anything else throws `MiniRegexUnsupported`
/// so the caller can fall back to NSRegularExpression.
final class MiniNFA {
    static let kChar: UInt8 = 0
    static let kSplit: UInt8 = 1
    static let kAccept: UInt8 = 2

    private(set) var kind: [UInt8] = []
    private(set) var classes: [[UInt16]] = []   // characters accepted by a kChar state
    private(set) var outs: [[Int]] = []         // successors (-1 = unpatched)
    private(set) var start = 0
    private(set) var accept = 0
    private var closureCache: [Int: [Int]] = [:]

    private let p: [UInt16]
    private var i = 0

    private typealias Hole = (state: Int, index: Int)
    private typealias Frag = (start: Int, holes: [Hole])

    // ASCII metacharacters
    private static let lparen: UInt16 = 0x28, rparen: UInt16 = 0x29, pipe: UInt16 = 0x7C
    private static let lbrack: UInt16 = 0x5B, rbrack: UInt16 = 0x5D, qmark: UInt16 = 0x3F
    private static let backslash: UInt16 = 0x5C, caret: UInt16 = 0x5E, dollar: UInt16 = 0x24
    private static let dot: UInt16 = 0x2E, star: UInt16 = 0x2A, plus: UInt16 = 0x2B
    private static let lbrace: UInt16 = 0x7B, rbrace: UInt16 = 0x7D, hyphen: UInt16 = 0x2D

    init(pattern: String) throws {
        p = Array(pattern.utf16)
        let f = try parseAlt()
        guard i == p.count else { throw MiniRegexUnsupported() }
        accept = newState(Self.kAccept, [], [])
        for h in f.holes { outs[h.state][h.index] = accept }
        start = f.start
    }

    /// Non-split states reachable from `state` through ε-moves (sorted).
    func closure(of state: Int) -> [Int] {
        if let cached = closureCache[state] { return cached }
        var seen = Set<Int>()
        var stack = [state]
        var result: [Int] = []
        while let s = stack.popLast() {
            guard s >= 0, seen.insert(s).inserted else { continue }
            if kind[s] == Self.kSplit {
                stack.append(contentsOf: outs[s])
            } else {
                result.append(s)
            }
        }
        result.sort()
        closureCache[state] = result
        return result
    }

    private func newState(_ k: UInt8, _ cls: [UInt16], _ o: [Int]) -> Int {
        kind.append(k)
        classes.append(cls)
        outs.append(o)
        return kind.count - 1
    }

    private func parseAlt() throws -> Frag {
        var frags = [try parseConcat()]
        while i < p.count && p[i] == Self.pipe {
            i += 1
            frags.append(try parseConcat())
        }
        if frags.count == 1 { return frags[0] }
        let s = newState(Self.kSplit, [], frags.map { $0.start })
        return (s, frags.flatMap { $0.holes })
    }

    private func parseConcat() throws -> Frag {
        var frags: [Frag] = []
        while i < p.count && p[i] != Self.pipe && p[i] != Self.rparen {
            frags.append(try parseRepeat())
        }
        guard var cur = frags.first else {
            let e = newState(Self.kSplit, [], [-1])
            return (e, [(e, 0)])
        }
        for f in frags.dropFirst() {
            for h in cur.holes { outs[h.state][h.index] = f.start }
            cur = (cur.start, f.holes)
        }
        return cur
    }

    private func parseRepeat() throws -> Frag {
        var f = try parseAtom()
        if i < p.count {
            let c = p[i]
            if c == Self.qmark {
                i += 1
                if i < p.count {
                    let n = p[i]
                    if n == Self.qmark || n == Self.star || n == Self.plus || n == Self.lbrace {
                        throw MiniRegexUnsupported()
                    }
                }
                let s = newState(Self.kSplit, [], [f.start, -1])
                f = (s, f.holes + [(s, 1)])
            } else if c == Self.star || c == Self.plus || c == Self.lbrace {
                throw MiniRegexUnsupported()
            }
        }
        return f
    }

    private func parseAtom() throws -> Frag {
        let c = p[i]
        switch c {
        case Self.lparen:
            i += 1
            if i < p.count && p[i] == Self.qmark { throw MiniRegexUnsupported() }
            let f = try parseAlt()
            guard i < p.count, p[i] == Self.rparen else { throw MiniRegexUnsupported() }
            i += 1
            return f
        case Self.lbrack:
            i += 1
            if i < p.count && p[i] == Self.caret { throw MiniRegexUnsupported() }
            var set: [UInt16] = []
            while i < p.count && p[i] != Self.rbrack {
                let ch = p[i]
                if ch == Self.backslash || ch == Self.lbrack || ch == Self.hyphen {
                    throw MiniRegexUnsupported()
                }
                set.append(ch)
                i += 1
            }
            guard i < p.count, !set.isEmpty else { throw MiniRegexUnsupported() }
            i += 1
            let s = newState(Self.kChar, set, [-1])
            return (s, [(s, 0)])
        case Self.backslash, Self.caret, Self.dollar, Self.dot, Self.star, Self.plus,
             Self.qmark, Self.lbrace, Self.rbrace, Self.rbrack, Self.rparen, Self.pipe:
            throw MiniRegexUnsupported()
        default:
            // Surrogates would need code-point semantics inside classes; keep it simple.
            if c >= 0xD800 && c <= 0xDFFF { throw MiniRegexUnsupported() }
            i += 1
            let s = newState(Self.kChar, [c], [-1])
            return (s, [(s, 0)])
        }
    }
}

// MARK: - Lazily built DFA

/// Subset construction done on demand: each DFA state is a set of NFA states,
/// created only when the trie walk actually reaches it.
final class LazyDFA {
    private let nfa: MiniNFA
    private var ids: [[Int]: Int32] = [:]
    private var sets: [[Int]] = []
    private var transitions: [[UInt16: Int32]] = []
    private var accepting: [Bool] = []
    private(set) var start: Int32 = 0

    init(pattern: String) throws {
        nfa = try MiniNFA(pattern: pattern)
        start = intern(nfa.closure(of: nfa.start))
    }

    @inline(__always) func isAccepting(_ state: Int32) -> Bool { accepting[Int(state)] }

    /// Next DFA state after reading `c`, or -1 if nothing can match any more.
    func step(_ state: Int32, _ c: UInt16) -> Int32 {
        let d = Int(state)
        if let t = transitions[d][c] { return t }
        var next = Set<Int>()
        for s in sets[d] where nfa.kind[s] == MiniNFA.kChar && nfa.classes[s].contains(c) {
            next.formUnion(nfa.closure(of: nfa.outs[s][0]))
        }
        let result: Int32 = next.isEmpty ? -1 : intern(next.sorted())
        transitions[d][c] = result
        return result
    }

    private func intern(_ set: [Int]) -> Int32 {
        if let id = ids[set] { return id }
        let id = Int32(sets.count)
        ids[set] = id
        sets.append(set)
        transitions.append([:])
        accepting.append(set.contains(nfa.accept))
        return id
    }
}

// MARK: - Sorted word table (implicit trie)

/// Immutable list of words stored as one flat UTF-16 buffer, sorted by code unit
/// and de-duplicated. Safe to read from any thread.
final class WordTable: @unchecked Sendable {
    let units: [UInt16]
    let offsets: [UInt32]   // count + 1 entries; word k = units[offsets[k] ..< offsets[k+1]]

    var count: Int { offsets.count - 1 }

    init(units: [UInt16], offsets: [UInt32]) {
        self.units = units
        self.offsets = offsets
    }

    /// Build from an unsorted list (used when avrodict.bin is missing).
    convenience init(words: [String]) {
        let arrays = Set(words.lazy.filter { !$0.isEmpty }.map { Array($0.utf16) })
            .sorted { $0.lexicographicallyPrecedes($1) }
        var u: [UInt16] = []
        var o: [UInt32] = [0]
        for a in arrays {
            u.append(contentsOf: a)
            o.append(UInt32(u.count))
        }
        self.init(units: u, offsets: o)
    }

    func word(at k: Int) -> String {
        String(decoding: units[Int(offsets[k])..<Int(offsets[k + 1])], as: UTF16.self)
    }

    /// Adds every word fully matched by `dfa` to `result`.
    func search(_ dfa: LazyDFA, into result: inout Set<String>) {
        guard count > 0 else { return }
        var found: [Int] = []
        let total = count
        units.withUnsafeBufferPointer { u in
            offsets.withUnsafeBufferPointer { o in
                func length(_ k: Int) -> Int { Int(o[k + 1]) - Int(o[k]) }
                func char(_ k: Int, _ depth: Int) -> UInt16 { u[Int(o[k]) + depth] }

                // Words in lo..<hi share their first `depth` code units.
                func walk(_ lo: Int, _ hi: Int, _ depth: Int, _ state: Int32) {
                    var i = lo
                    // Words that end exactly here sort first.
                    while i < hi && length(i) == depth {
                        if dfa.isAccepting(state) { found.append(i) }
                        i += 1
                    }
                    while i < hi {
                        let c = char(i, depth)
                        // first index in i..<hi whose next code unit is > c
                        var a = i + 1
                        var b = hi
                        while a < b {
                            let m = (a + b) >> 1
                            if char(m, depth) <= c { a = m + 1 } else { b = m }
                        }
                        let next = dfa.step(state, c)
                        if next >= 0 { walk(i, a, depth + 1, next) }
                        i = a
                    }
                }
                walk(0, total, 0, dfa.start)
            }
        }
        for k in found { result.insert(word(at: k)) }
    }
}

// MARK: - avrodict.bin loader

/// Reads the pre-sorted dictionary produced by scripts/make-dict.py.
/// Returns nil on any format problem so the caller can fall back to SQLite.
enum DictionaryFile {
    static func load(_ url: URL) -> [String: WordTable]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: WordTable]? in
            var p = 0
            func u32() -> UInt32? {
                guard p + 4 <= raw.count else { return nil }
                var v: UInt32 = 0
                withUnsafeMutableBytes(of: &v) {
                    $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[p..<(p + 4)]))
                }
                p += 4
                return UInt32(littleEndian: v)
            }
            guard raw.count >= 8, raw[0] == 0x41, raw[1] == 0x56, raw[2] == 0x44, raw[3] == 0x31 else {
                return nil
            }
            p = 4
            guard let tableCount = u32() else { return nil }
            var tables: [String: WordTable] = [:]
            for _ in 0..<tableCount {
                guard p < raw.count else { return nil }
                let nameLen = Int(raw[p])
                p += 1
                guard p + nameLen <= raw.count else { return nil }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[p..<(p + nameLen)]), as: UTF8.self)
                p += nameLen
                p = (p + 3) & ~3
                guard let wordCount = u32(), let unitCount = u32() else { return nil }
                let offsetBytes = (Int(wordCount) + 1) * 4
                let unitBytes = Int(unitCount) * 2
                guard p + offsetBytes + unitBytes <= raw.count else { return nil }

                var offsets = [UInt32](repeating: 0, count: Int(wordCount) + 1)
                offsets.withUnsafeMutableBytes {
                    $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[p..<(p + offsetBytes)]))
                }
                p += offsetBytes
                var units = [UInt16](repeating: 0, count: Int(unitCount))
                if unitBytes > 0 {
                    units.withUnsafeMutableBytes {
                        $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[p..<(p + unitBytes)]))
                    }
                }
                p += unitBytes
                p = (p + 3) & ~3

                // Validate so a corrupt file can never cause out-of-bounds reads.
                guard offsets.first == 0, offsets.last == unitCount else { return nil }
                for k in 0..<Int(wordCount) where offsets[k] >= offsets[k + 1] { return nil }
                tables[name] = WordTable(units: units, offsets: offsets)
            }
            return tables
        }
    }
}
