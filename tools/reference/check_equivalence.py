"""Python reference check: the trie/DFA algorithm (engine.py) vs. a plain regex scan,
on the real regex.json + database.db3. Runs anywhere with Python 3 (used by CI on Linux).
Usage: python3 tools/reference/check_equivalence.py [repo-root]"""
import os, sys, sqlite3, re, random, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
rp = RegexParser(f"{SRC}/regex.json")
con = sqlite3.connect(f"file:{SRC}/database.db3?mode=ro", uri=True)
names = ["A","AA","B","BH","C","CH","D","Dd","Ddh","Dh","E","G","Gh","H","I","II","J","JH","K","KH","Khandatta","L","M","N","NGA","NN","NYA","O","OI","OU","P","PH","R","RR","RRH","RRI","S","SH","SS","T","TH","TT","TTH","U","UU","Y","Z"]
raw = {n.lower(): [r[0] for r in con.execute(f'SELECT Words FROM "{n}"')] for n in names}
tables = {k: SortedTable(v) for k, v in raw.items()}
lookup = {"a":["a","aa","e","oi","o","nya","y"],"b":["b","bh"],"c":["c","ch","k"],"d":["d","dh","dd","ddh"],"e":["i","ii","e","y"],"f":["ph"],"g":["g","gh","j"],"h":["h"],"i":["i","ii","y"],"j":["j","jh","z"],"k":["k","kh"],"l":["l"],"m":["h","m"],"n":["n","nya","nga","nn"],"o":["a","u","uu","oi","o","ou","y"],"p":["p","ph"],"q":["k"],"r":["rri","h","r","rr","rrh"],"s":["s","sh","ss"],"t":["t","th","tt","tth","khandatta"],"u":["u","uu","y"],"v":["bh"],"w":["o"],"x":["e","k"],"y":["i","y"],"z":["h","j","jh","z"]}

def old(term):
    lmc = term.lower()[0]
    rx = re.compile("^" + rp.parse(term) + "$")
    s = set()
    for t in lookup.get(lmc, []):
        for w in raw[t]:
            if rx.search(w): s.add(w)
    return s
def new(term, stats):
    lmc = term.lower()[0]
    dfa = LazyDFA(NFA(rp.parse(term)))
    s = set()
    for t in lookup.get(lmc, []):
        s.update(tables[t].search(dfa, stats))
    return s

common = "ami tumi apni amar tomar bangla bhalo kemon achen achi shobai bondhu bari jabo khabo korchi korbo bhai bon ma baba deshe manush kotha shundor din rat shokal bikel ekhon kal porshu ajke kalke sathe theke jonno kintu ebong othoba jodi tahole keno kokhon kothay ke ki kibhabe onek kom beshi chhoto boro notun puran shoto hajar lakh koti biswobidyaloy shikkhok chhatro pora lekha boi kolom khata computer internet bangladesh dhaka chottogram rajshahi khulna sylhet rongpur barishal mymensingh prothom ditio tritio shesh shuru Ami TUMI o a k kh ch shh rri oi ou ng ngk kkh chchh jnj tth ddh rr rrh Ttha Dhaka shRi krishno lokkho shotti mittha".split()
random.seed(7)
letters = "abcdefghijklmnopqrstuvwxyzAEIOUTDSNRZ"
rand = ["".join(random.choice(letters) for _ in range(random.randint(1,9))) for _ in range(250)]
terms = common + rand
bad = 0; to = tn = 0.0; scans = 0; nodes = [0]; unsup = 0
for term in terms:
    t0 = time.perf_counter(); a = old(term); t1 = time.perf_counter()
    try:
        b = new(term, nodes)
    except Unsupported as e:
        unsup += 1; print("UNSUPPORTED", term, e); continue
    t2 = time.perf_counter()
    to += t1 - t0; tn += t2 - t1
    scans += sum(len(raw[t]) for t in lookup.get(term.lower()[0], []))
    if a != b:
        bad += 1; print("MISMATCH", term, len(a), len(b), list(a ^ b)[:5])
print(f"terms={len(terms)} mismatches={bad} unsupported={unsup}")
print(f"regex tests old={scans}  trie nodes visited new={nodes[0]}  ratio={scans/max(nodes[0],1):.1f}x fewer")
print(f"python time old={to:.2f}s new={tn:.2f}s")
sys.exit(1 if bad else 0)
