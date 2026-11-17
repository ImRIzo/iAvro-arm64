"""Reference implementation (Python) of the dictionary engine in Sources/Services/DictionaryEngine.swift:
RegexParser port + regex -> NFA -> lazy DFA + sorted-array (implicit trie) walk."""
import json, sqlite3, re, bisect

SUFFIX = "(্[যবম])?(্?)([ৃঁ]?)"

class RegexParser:
    def __init__(self, path):
        d = json.load(open(path, encoding="utf-8"))
        self.vowel, self.cons, self.cs = d["vowel"], d["consonant"], d["casesensitive"]
        self.pat = {p["find"]: p for p in d["patterns"]}
        self.maxlen = len(d["patterns"][0]["find"])
    @staticmethod
    def small(c): return chr(ord(c)+32) if 'A' <= c <= 'Z' else c
    def ins(self, s, c): return self.small(c) in s
    def clean(self, s):
        return "".join(self.small(c) for c in s if not self.ins(self.cs, c))
    def parse(self, s):
        if not s: return s
        f = self.clean(s); n = len(f); out = []; cur = 0
        isV = lambda c: self.ins(self.vowel, c); isC = lambda c: self.ins(self.cons, c)
        isP = lambda c: not (isV(c) or isC(c))
        while cur < n:
            start = cur; matched = False; cl = self.maxlen
            while cl > 0 and not matched:
                end = start + cl
                if end <= n and f[start:end] in self.pat:
                    p = self.pat[f[start:end]]
                    for rule in p["rules"]:
                        ok = True
                        for m in rule["matches"]:
                            typ, sc = m["type"], m["scope"]
                            neg = str(m.get("negative", "NO")).upper() in ("YES", "TRUE")
                            chk = end if typ == "suffix" else start - 1
                            inb = 0 <= chk < n
                            if sc == "punctuation":
                                cond = (chk < 0 and typ == "prefix") or (chk >= n and typ == "suffix") or (inb and isP(f[chk]))
                            elif sc == "vowel":
                                cond = ((chk >= 0 and typ == "prefix") or (chk < n and typ == "suffix")) and inb and isV(f[chk])
                            elif sc == "consonant":
                                cond = ((chk >= 0 and typ == "prefix") or (chk < n and typ == "suffix")) and inb and isC(f[chk])
                            elif sc == "number":
                                cond = False
                            elif sc == "exact":
                                v = m.get("value", "")
                                s_, e_ = (end, end+len(v)) if typ == "suffix" else (start-len(v), start)
                                if s_ >= 0 and e_ <= n: res = (f[s_:e_] == v) != neg
                                else: res = neg
                                if not res: ok = False
                                if not ok: break
                                continue
                            if not (cond != neg): ok = False
                            if not ok: break
                        if ok:
                            out.append(rule["replace"] + SUFFIX); cur = end - 1; matched = True; break
                    if not matched:
                        out.append(p["replace"] + SUFFIX); cur = end - 1; matched = True
                cl -= 1
            if not matched: out.append(f[cur])
            cur += 1
        return "".join(out)

# ---------------- tiny regex: literal, (), |, [...], ? -----------------
class Unsupported(Exception): pass

class NFA:
    # state kinds: ('c', set_or_char, out) ; ('e', [outs]) ; ('acc',)
    def __init__(self, pattern):
        self.kind = []; self.cls = []; self.out = []
        self.p = pattern; self.i = 0
        s, ends = self.alt()
        if self.i != len(self.p): raise Unsupported("trailing")
        acc = self.new('acc', None, [])
        for e in ends: self.patch(e, acc)
        self.start = s; self.acc = acc
        self.closure = [self._close(x) for x in range(len(self.kind))]
    def new(self, k, cls, outs):
        self.kind.append(k); self.cls.append(cls); self.out.append(outs); return len(self.kind)-1
    def patch(self, hole, target):
        st, idx = hole; self.out[st][idx] = target
    # fragments: (start, [holes]) ; hole = (state, index into out list)
    def alt(self):
        frags = [self.concat()]
        while self.i < len(self.p) and self.p[self.i] == '|':
            self.i += 1; frags.append(self.concat())
        if len(frags) == 1: return frags[0]
        s = self.new('e', None, [f[0] for f in frags])
        return s, [h for f in frags for h in f[1]]
    def concat(self):
        frags = []
        while self.i < len(self.p) and self.p[self.i] not in '|)':
            frags.append(self.repeat())
        if not frags:
            e = self.new('e', None, [None]); return e, [(e, 0)]
        s, holes = frags[0]
        for f in frags[1:]:
            for h in holes: self.patch(h, f[0])
            holes = f[1]
        return s, holes
    def repeat(self):
        f = self.atom()
        if self.i < len(self.p) and self.p[self.i] == '?':
            self.i += 1
            e = self.new('e', None, [f[0], None])
            f = (e, f[1] + [(e, 1)])
            if self.i < len(self.p) and self.p[self.i] in '?*+{': raise Unsupported("quant")
        elif self.i < len(self.p) and self.p[self.i] in '*+{': raise Unsupported("quant")
        return f
    def atom(self):
        c = self.p[self.i]
        if c == '(':
            self.i += 1
            if self.i < len(self.p) and self.p[self.i] == '?': raise Unsupported("group ext")
            f = self.alt()
            if self.i >= len(self.p) or self.p[self.i] != ')': raise Unsupported("paren")
            self.i += 1; return f
        if c == '[':
            self.i += 1; chars = set()
            if self.i < len(self.p) and self.p[self.i] == '^': raise Unsupported("neg class")
            while self.i < len(self.p) and self.p[self.i] != ']':
                ch = self.p[self.i]
                if ch in '\\[' or (ch == '-' and chars and self.p[self.i+1] != ']'): raise Unsupported("class")
                chars.add(ch); self.i += 1
            if self.i >= len(self.p): raise Unsupported("class end")
            self.i += 1
            s = self.new('c', frozenset(chars), [None]); return s, [(s, 0)]
        if c in '\\^$.*+?{}[]': raise Unsupported("meta " + c)
        self.i += 1
        s = self.new('c', frozenset(c), [None]); return s, [(s, 0)]
    def _close(self, x):
        seen = set(); stack = [x]
        while stack:
            y = stack.pop()
            if y is None or y in seen: continue
            seen.add(y)
            if self.kind[y] == 'e': stack.extend(self.out[y])
        return frozenset(z for z in seen if self.kind[z] != 'e')

class LazyDFA:
    def __init__(self, nfa):
        self.n = nfa; self.ids = {}; self.sets = []; self.trans = []; self.accept = []
        self.start = self.intern(nfa.closure[nfa.start])
    def intern(self, s):
        if s in self.ids: return self.ids[s]
        i = len(self.sets); self.ids[s] = i; self.sets.append(s); self.trans.append({})
        self.accept.append(self.n.acc in s); return i
    def step(self, d, c):
        t = self.trans[d]
        if c in t: return t[c]
        nxt = set()
        for st in self.sets[d]:
            if self.n.kind[st] == 'c' and c in self.n.cls[st]:
                nxt |= self.n.closure[self.n.out[st][0]]
        r = self.intern(frozenset(nxt)) if nxt else -1
        t[c] = r; return r

class SortedTable:
    def __init__(self, words):
        self.w = sorted(set(words))  # code-point order == UTF-16 order for BMP
    def search(self, dfa, stats=None):
        res = []; w = self.w
        def walk(lo, hi, depth, d):
            if stats is not None: stats[0] += 1
            i = lo
            while i < hi and len(w[i]) == depth:
                if dfa.accept[d]: res.append(w[i])
                i += 1
            while i < hi:
                c = w[i][depth]
                # first index in [i,hi) whose char at depth > c
                a, b = i, hi
                while a < b:
                    m = (a+b)//2
                    if w[m][depth] <= c: a = m+1
                    else: b = m
                nd = dfa.step(d, c)
                if nd >= 0: walk(i, a, depth+1, nd)
                i = a
        walk(0, len(w), 0, dfa.start)
        return res
