#!/bin/bash
# Build and run tools/engine-check: new dictionary engine vs. original regex scan.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/engine-check"
rm -rf "${OUT}"; mkdir -p "${OUT}"

python3 "${ROOT}/scripts/make-dict.py" "${ROOT}/database.db3" "${ROOT}/avrodict.bin"

# An unbundled executable looks up Bundle.main resources next to itself.
cp "${ROOT}/avrodict.bin" "${ROOT}/regex.json" "${ROOT}/data.json" "${OUT}/"

xcrun swiftc -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "arm64-apple-macosx13.0" \
  -o "${OUT}/engine-check" \
  "${ROOT}/Sources/Services/Database.swift" \
  "${ROOT}/Sources/Services/DictionaryEngine.swift" \
  "${ROOT}/Sources/Parsers/RegexParser.swift" \
  "${ROOT}/Sources/Parsers/PatternMatcher.swift" \
  "${ROOT}/Sources/Extensions/Duration+Milliseconds.swift" \
  "${ROOT}/tools/engine-check/main.swift"

"${OUT}/engine-check"
