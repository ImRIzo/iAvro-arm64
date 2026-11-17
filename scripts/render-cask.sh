#!/bin/bash
# Print the Homebrew cask for a release.
# Usage: scripts/render-cask.sh <version> <sha256-of-zip> <owner/repo>
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <version> <sha256> <owner/repo>" >&2; exit 2; }
VERSION="${1#v}" SHA256="$2" REPO="$3"
sed -e "s|@VERSION@|${VERSION}|g" -e "s|@SHA256@|${SHA256}|g" -e "s|@REPO@|${REPO}|g" \
  "$(cd "$(dirname "$0")/.." && pwd)/packaging/homebrew/avro-keyboard.rb.in"
