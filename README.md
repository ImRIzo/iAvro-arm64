# Avro Keyboard for macOS — Apple Silicon

Avro phonetic Bangla input method (`ami` → আমি) for M1 and newer Macs.
A maintained fork of [torifat/iAvro](https://github.com/torifat/iAvro), built with the
Command Line Tools only; Xcode is not needed.

- Native arm64, macOS 13 Ventura or later
- Faster dictionary search, faster start-up, lower memory use
- Crash fixes; `.pkg` installer, Homebrew cask, CI releases

## Install

**Homebrew**
```bash
brew install --cask ImRIzo/tap/avro-keyboard
```

**Installer:** download `AvroKeyboard-<version>.pkg` from
[Releases](https://github.com/ImRIzo/iAvro-arm64/releases) and open it.
Releases are not notarized, so macOS blocks the first open: allow it in
**System Settings → Privacy & Security → Open Anyway**.

**From source**
```bash
xcode-select --install   # once
make install             # → ~/Library/Input Methods
```

Then **log out and back in**, and add it in
**System Settings → Keyboard → Input Sources → + → Bangla → Avro Keyboard**.

## Build

| Command | Result |
|---|---|
| `make` | `build/Avro Keyboard.app` |
| `make install` | build + install for the current user |
| `make pkg` | `build/dist/AvroKeyboard-<ver>.pkg` (installs to `/Library/Input Methods`) |
| `make dist` | `.pkg` + `.zip` + `SHA256SUMS.txt` (release assets) |
| `make check` | new engine vs. original regex search on real data, with timings |
| `make reference` | the same comparison using the Python reference implementation |
| `make uninstall` | remove the app |
| `make purge` | remove every copy, registration, receipt and cache (then log out) |

Requires macOS on Apple Silicon with the Command Line Tools (Swift 5.10+).

## What's different from iAvro

Compared with upstream [`645c505`](https://github.com/torifat/iAvro/commit/645c505) (Swift 6 migration, Oct 2026):

**Build and packaging**
- No Xcode: `MainMenu.nib` replaced by code, `#Preview` macros and the `.xcodeproj` removed.
- `make` / `scripts/build.sh` build the app with `swiftc` only, ad-hoc signed, arm64-only.
- `.pkg` installer, `.zip`, Homebrew cask, GitHub Actions CI and tag-driven releases.
- `make purge` cleans up duplicate "Avro Keyboard" entries in Input Sources.

**Performance**
- **Dictionary search:** upstream ran an `NSRegularExpression` against every word of the
  candidate tables on each keystroke (10–18 k words). Words are now stored sorted by UTF-16
  code unit, so the array acts as an implicit trie. The phonetic regex is compiled into an
  NFA, driven as a lazily built DFA and walked down that trie; non-matching branches are
  skipped whole. In the reference check this visits about **470× fewer** nodes than the
  number of regex tests, with identical results (`make check` / `make reference`).
- **`avrodict.bin`:** a pre-sorted binary dictionary (words + suffixes, ~3 MB, generated from
  `database.db3` by `scripts/make-dict.py`) is the only dictionary file in the app. It is
  memory-mapped at start-up — no SQLite, no sorting. `database.db3` stays in the repo as
  the editable source; `scripts/build.sh` regenerates the `.bin` when it changes.
- **Background search:** dictionary lookups run off the main thread. A keystroke waits up
  to 12 ms for them and otherwise shows the plain conversion first; Space, Enter and number
  keys always wait for the full list.
- **Smaller fixes:** Levenshtein distances are computed once per word, not on every sort
  comparison, and ties are sorted deterministically. The cache is saved in the background,
  2 s after the last word, instead of synchronously on every word. The input-split regex
  is compiled once.
- **Memory:** about 20 MB vs. about 29 MB before these changes (Activity Monitor, while typing).

**Fixes**
- Crash on Space: a stale candidate index went out of bounds.
- Crash on emoji and other characters outside the BMP (`UInt16(_:)` overflow).
- Possible negative-length substring when caching a selected candidate.
- Space now commits the word and inserts the space itself, so the candidate window can't
  swallow it. Text falls back to `IMKInputController.client()` when the sender cast fails.

**Debugging**
```bash
log stream --level debug --predicate 'subsystem == "com.omicronlab.inputmethod.AvroKeyboard"'
# run old and new engines side by side and log mismatches:
defaults write com.omicronlab.inputmethod.AvroKeyboard VerifyDictionaryEngine -bool YES; killall "Avro Keyboard"
defaults delete com.omicronlab.inputmethod.AvroKeyboard VerifyDictionaryEngine; killall "Avro Keyboard"
```

## Troubleshooting

- **Several "Avro Keyboard" entries in Input Sources:** run `make purge`, log out and in,
  then install once.
- **The first keystroke after login is slow:** macOS starts input methods on first use; it
  is fast after that.
- **A new build is not picked up:** run `killall "Avro Keyboard"`, then switch input source
  away and back.

## Credits and license

Avro Keyboard by [OmicronLab](https://www.omicronlab.com); iAvro by Rifat Nabi, Sarim Khan,
Mehdi Hasan and contributors. Licensed under MPL 1.1; see [LICENSE.md](LICENSE.md).
