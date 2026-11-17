// Engine check: compares the new trie/DFA dictionary search against the original
// NSRegularExpression scan on real data, and reports timings.
// Built and run by `make check` (scripts/engine-check.sh). Exit code 1 on any mismatch.

import Foundation

let common = """
ami tumi apni amar tomar bangla bhalo kemon achen achi shobai bondhu bari jabo khabo \
korchi korbo bhai bon ma baba deshe manush kotha shundor din rat shokal bikel ekhon kal \
porshu ajke kalke sathe theke jonno kintu ebong othoba jodi tahole keno kokhon kothay ke \
ki kibhabe onek kom beshi chhoto boro notun puran shoto hajar lakh koti biswobidyaloy \
shikkhok chhatro pora lekha boi kolom khata computer internet bangladesh dhaka \
chottogram rajshahi khulna sylhet prothom ditio shesh shuru Ami TUMI o a k kh ch shh rri \
oi ou ng ngk kkh chchh tth ddh rr rrh Ttha Dhaka shRi krishno lokkho shotti mittha
""".split(separator: " ").map(String.init)

// Deterministic pseudo-random terms (LCG) so runs are comparable.
var seed: UInt64 = 7
func nextRandom(_ n: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(n))
}
let letters = Array("abcdefghijklmnopqrstuvwxyzAEIOUTDSNRZ")
var terms = common
for _ in 0..<300 {
    let len = 1 + nextRandom(9)
    terms.append(String((0..<len).map { _ in letters[nextRandom(letters.count)] }))
}

func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

let loadStart = ContinuousClock.now
_ = Database.shared
print(String(format: "dictionary load: %.1f ms", ms(ContinuousClock.now - loadStart)))

var mismatches = 0
var newTimes: [Double] = []
var oldTimes: [Double] = []
for term in terms {
    let t0 = ContinuousClock.now
    let fast = Set(Database.shared.find(term: term))
    let t1 = ContinuousClock.now
    let reference = Set(Database.shared.findUsingRegex(term: term))
    let t2 = ContinuousClock.now
    newTimes.append(ms(t1 - t0))
    oldTimes.append(ms(t2 - t1))
    if fast != reference {
        mismatches += 1
        print("MISMATCH \(term): new=\(fast.count) old=\(reference.count)")
    }
}

func summary(_ name: String, _ v: [Double]) {
    let sorted = v.sorted()
    let avg = v.reduce(0, +) / Double(max(v.count, 1))
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    print(String(format: "%@ avg %.3f ms   p95 %.3f ms   max %.3f ms", name, avg, p95, sorted.last ?? 0))
}
print("terms: \(terms.count)   mismatches: \(mismatches)")
summary("new (trie+DFA):", newTimes)
summary("old (regex)   :", oldTimes)
let speedup = oldTimes.reduce(0, +) / max(newTimes.reduce(0, +), 0.000_001)
print(String(format: "speed-up: %.1fx", speedup))
exit(mismatches == 0 ? 0 : 1)
