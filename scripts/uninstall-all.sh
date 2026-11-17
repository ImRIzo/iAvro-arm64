#!/bin/bash
# Completely remove EVERY Avro Keyboard copy, registration, receipt and cache,
# so System Settings stops listing duplicate "Avro Keyboard" input sources.
#
# Usage:  ./scripts/uninstall-all.sh
# Afterwards LOG OUT and log back in.

set -u
BID="com.omicronlab.inputmethod.AvroKeyboard"
APP="Avro Keyboard"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

ask() { local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]; }

echo "==> 1/7 Stopping Avro"
killall "$APP" 2>/dev/null && echo "    stopped" || echo "    not running"

echo "==> 2/7 Removing Avro from enabled/selected input sources"
# Go through cfprefsd (defaults export/import) — never edit the plist file directly.
TMP="$(mktemp -t hitoolbox)"
if defaults export com.apple.HIToolbox "$TMP" 2>/dev/null; then
  cp "$TMP" "$HOME/Desktop/HIToolbox-backup-$(date +%Y%m%d-%H%M%S).plist"
  /usr/bin/python3 - "$TMP" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
def is_avro(e):
    return isinstance(e, dict) and "omicronlab" in str(e.get("Bundle ID", "")).lower()
removed = 0
for key in ("AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"):
    if key in d and isinstance(d[key], list):
        before = len(d[key]); d[key] = [e for e in d[key] if not is_avro(e)]; removed += before - len(d[key])
# Make sure at least one keyboard layout stays enabled (ABC).
abc = {"InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 252, "KeyboardLayout Name": "ABC"}
en = d.setdefault("AppleEnabledInputSources", [])
if not any(isinstance(e, dict) and e.get("InputSourceKind") == "Keyboard Layout" for e in en):
    en.append(abc)
if not d.get("AppleSelectedInputSources"):
    d["AppleSelectedInputSources"] = [abc]
plistlib.dump(d, open(p, "wb"))
print(f"    removed {removed} Avro entries")
PY
  defaults import com.apple.HIToolbox "$TMP" && echo "    (backup saved on Desktop)"
fi
rm -f "$TMP"

echo "==> 3/7 Finding every copy of $APP.app"
PATHS=()
while IFS= read -r p; do [[ -n "$p" && -d "$p" ]] && PATHS+=("$p"); done < <(
  {
    mdfind "kMDItemCFBundleIdentifier == '$BID'" 2>/dev/null
    mdfind "kMDItemFSName == '$APP.app'" 2>/dev/null
    "$LSREG" -dump 2>/dev/null | sed -nE "s/^path:[[:space:]]+(.*${APP}\.app)( \(0x[0-9a-fA-F]+\))?$/\1/p"
    ls -d "$HOME/Library/Input Methods/$APP.app" "/Library/Input Methods/$APP.app" 2>/dev/null
  } | sort -u
)
# Also catch registrations whose folder is already gone
GHOSTS=()
while IFS= read -r p; do [[ -n "$p" && ! -d "$p" ]] && GHOSTS+=("$p"); done < <(
  "$LSREG" -dump 2>/dev/null | sed -nE "s/^path:[[:space:]]+(.*${APP}\.app)( \(0x[0-9a-fA-F]+\))?$/\1/p" | sort -u
)
if [[ ${#PATHS[@]} -eq 0 ]]; then echo "    none found on disk"; fi

echo "==> 4/7 Unregistering + deleting copies"
for p in ${PATHS[@]+"${PATHS[@]}"}; do
  "$LSREG" -u "$p" 2>/dev/null
  case "$p" in
    "$HOME/Library/Input Methods/"*) rm -rf "$p" && echo "    deleted  $p" ;;
    "/Library/Input Methods/"*)      sudo rm -rf "$p" && echo "    deleted  $p (sudo)" ;;
    *)
      if ask "    Delete build copy  $p ?"; then
        rm -rf "$p" 2>/dev/null || sudo rm -rf "$p"; echo "    deleted  $p"
      else
        echo "    kept (unregistered) $p"
      fi ;;
  esac
done
for p in ${GHOSTS[@]+"${GHOSTS[@]}"}; do "$LSREG" -u "$p" 2>/dev/null && echo "    unregistered stale $p"; done

echo "==> 5/7 Forgetting installer receipts"
for r in $(pkgutil --pkgs 2>/dev/null | grep -i -E 'omicronlab|avro'); do
  sudo pkgutil --forget "$r" >/dev/null && echo "    forgot $r"
done

echo "==> 6/7 Removing preferences & app caches"
defaults delete "$BID" 2>/dev/null && echo "    preferences removed"
rm -rf "$HOME/Library/Caches/$BID" "$HOME/Library/Saved Application State/$BID.savedState" "$HOME/Library/HTTPStorages/$BID"
AVRO_DATA="$HOME/Library/Application Support/OmicronLab/Avro Keyboard"
if [[ -d "$AVRO_DATA" ]] && ask "    Also delete learned word choices ($AVRO_DATA)?"; then
  rm -rf "$AVRO_DATA"; rmdir "$HOME/Library/Application Support/OmicronLab" 2>/dev/null; echo "    deleted"
fi

echo "==> 7/7 Clearing macOS input-source caches"
rm -f "$HOME"/Library/Caches/com.apple.IntlDataCache* 2>/dev/null
rm -f "$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"com.apple.IntlDataCache* 2>/dev/null
killall TextInputMenuAgent TextInputSwitcher 2>/dev/null
killall cfprefsd 2>/dev/null

echo
echo "Done. Now LOG OUT and log back in before installing again."
