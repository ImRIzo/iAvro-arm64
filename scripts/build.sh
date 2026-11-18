#!/bin/bash
# Build "Avro Keyboard.app" for Apple Silicon (arm64) with the Command Line Tools only.
#
# Usage:
#   scripts/build.sh              build build/Avro Keyboard.app
#   scripts/build.sh --install    + install to ~/Library/Input Methods
#   scripts/build.sh --pkg        + build/dist/AvroKeyboard-<ver>.pkg
#   scripts/build.sh --dist       + .pkg, .zip and SHA256SUMS.txt in build/dist (used by CI)
#
# Environment:
#   AVRO_VERSION   override CFBundleShortVersionString (e.g. 2.1.0; CI sets it from the tag)
#   AVRO_BUILD     override CFBundleVersion (CI sets the run number)
#   MACOSX_DEPLOYMENT_TARGET   default 13.0

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
DIST_DIR="${BUILD_DIR}/dist"
APP_NAME="Avro Keyboard"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
USER_INSTALL_DIR="${HOME}/Library/Input Methods"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
PLIST_SRC="${ROOT}/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST_SRC}")"
VERSION="${AVRO_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_SRC}")}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${AVRO_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_SRC}")}"

DO_INSTALL=0; DO_PKG=0; DO_DIST=0
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    --pkg)     DO_PKG=1 ;;
    --dist)    DO_PKG=1; DO_DIST=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Build-folder copies must not stay registered, or System Settings lists duplicates.
unregister() { "${LSREG}" -u "$1" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- checks
[[ "$(uname -s)" == "Darwin" ]] || { echo "error: build on macOS." >&2; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || echo "warning: host is $(uname -m); building arm64 anyway." >&2
xcrun --find swiftc >/dev/null 2>&1 || { echo "error: run  xcode-select --install" >&2; exit 1; }

SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_VER="$("${SWIFTC}" --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
echo "==> Avro Keyboard ${VERSION} (${BUILD_NUMBER}) — swiftc ${SWIFT_VER:-?}"
case "${SWIFT_VER}" in 5.[0-9]) echo "error: need Swift 5.10+" >&2; exit 1 ;; esac

# ---------------------------------------------------------------- compile
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES}"

echo "==> Compiling (arm64, macOS ${DEPLOYMENT_TARGET}+)"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done \
  < <(find "${ROOT}/Sources" -name '*.swift' -print0 | sort -z)

"${SWIFTC}" \
  -sdk "${SDK}" \
  -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
  -module-name AvroKeyboard \
  -O -whole-module-optimization \
  -framework Cocoa -framework InputMethodKit -framework SwiftUI \
  -o "${MACOS_DIR}/${APP_NAME}" \
  "${SOURCES[@]}"

# ---------------------------------------------------------------- bundle
echo "==> Assembling bundle"
cp "${PLIST_SRC}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :LSMinimumSystemVersion ${DEPLOYMENT_TARGET}" \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
  "${CONTENTS}/Info.plist"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null
printf 'APPL????' > "${CONTENTS}/PkgInfo"

for f in regex.json data.json autodict.plist preferences.plist; do
  cp "${ROOT}/$f" "${RESOURCES}/"
done
cp -R "${ROOT}/Credits.rtfd" "${ROOT}/English.lproj" "${RESOURCES}/"
cp "${ROOT}/Images.xcassets/MenuIcon.imageset/final16flat2.png" "${RESOURCES}/MenuIcon.png"

# Binary dictionary (words + suffixes) — the only dictionary file shipped.
# Regenerate if missing, or older than the source DB or the generator.
if [[ ! -f "${ROOT}/avrodict.bin" || "${ROOT}/database.db3" -nt "${ROOT}/avrodict.bin" \
      || "${ROOT}/scripts/make-dict.py" -nt "${ROOT}/avrodict.bin" ]]; then
  echo "    generating avrodict.bin"
  python3 "${ROOT}/scripts/make-dict.py" "${ROOT}/database.db3" "${ROOT}/avrodict.bin"
fi
cp "${ROOT}/avrodict.bin" "${RESOURCES}/"

ICONSET="${BUILD_DIR}/AppIcon.iconset"
SRC_ICON="${ROOT}/Images.xcassets/AppIcon.appiconset/avro512x512.png"
mkdir -p "${ICONSET}"
for sz in 16 32 128 256; do
  sips -z "$sz" "$sz"         "${SRC_ICON}" --out "${ICONSET}/icon_${sz}x${sz}.png"    >/dev/null
  sips -z $((sz*2)) $((sz*2)) "${SRC_ICON}" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
done
sips -z 512 512 "${SRC_ICON}" --out "${ICONSET}/icon_512x512.png" >/dev/null
iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns" 2>/dev/null \
  || sips -s format icns "${SRC_ICON}" --out "${RESOURCES}/AppIcon.icns" >/dev/null
rm -rf "${ICONSET}"

echo "==> Ad-hoc signing"
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
codesign --force --sign - --timestamp=none "${APP_BUNDLE}"
codesign --verify --strict "${APP_BUNDLE}"
unregister "${APP_BUNDLE}"
lipo -info "${MACOS_DIR}/${APP_NAME}"

# ---------------------------------------------------------------- pkg
if [[ $DO_PKG -eq 1 ]]; then
  mkdir -p "${DIST_DIR}"
  PKG="${DIST_DIR}/AvroKeyboard-${VERSION}.pkg"
  STAGE="${BUILD_DIR}/pkgroot"
  COMP_PLIST="${BUILD_DIR}/component.plist"
  echo "==> ${PKG}"
  rm -rf "${STAGE}"; mkdir -p "${STAGE}"
  cp -R "${APP_BUNDLE}" "${STAGE}/"
  # Hand-written so pkgbuild never "relocates" the bundle to another copy on disk.
  cat > "${COMP_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key><true/>
		<key>BundleIsRelocatable</key><false/>
		<key>BundleIsVersionChecked</key><false/>
		<key>BundleOverwriteAction</key><string>upgrade</string>
		<key>RootRelativeBundlePath</key><string>${APP_NAME}.app</string>
	</dict>
</array>
</plist>
PLIST
  pkgbuild --root "${STAGE}" --component-plist "${COMP_PLIST}" \
    --install-location "/Library/Input Methods" --scripts "${ROOT}/scripts/pkg" \
    --identifier "${BUNDLE_ID}.pkg" --version "${VERSION}" "${PKG}"
  unregister "${STAGE}/${APP_NAME}.app"
  rm -rf "${STAGE}" "${COMP_PLIST}"
fi

# ---------------------------------------------------------------- dist
if [[ $DO_DIST -eq 1 ]]; then
  ZIP="${DIST_DIR}/AvroKeyboard-${VERSION}.zip"
  echo "==> ${ZIP}"
  ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP}"
  (cd "${DIST_DIR}" && shasum -a 256 ./*.pkg ./*.zip | sed 's| \./| |' > SHA256SUMS.txt && cat SHA256SUMS.txt)
fi

# ---------------------------------------------------------------- install
if [[ $DO_INSTALL -eq 1 ]]; then
  echo "==> Installing to ${USER_INSTALL_DIR}"
  mkdir -p "${USER_INSTALL_DIR}"
  killall "${APP_NAME}" 2>/dev/null || true
  sleep 0.5
  rm -rf "${USER_INSTALL_DIR}/${APP_NAME}.app"
  cp -R "${APP_BUNDLE}" "${USER_INSTALL_DIR}/"
  echo "Installed. First install: log out/in, then System Settings → Keyboard → Input Sources → + → Bangla → Avro Keyboard"
fi
