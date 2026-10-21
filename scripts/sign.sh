#!/usr/bin/env bash
# sign.sh - sign a .app bundle inside-out.
#
# Usage: sign.sh --app <path.app> [--identity ID] [--entitlements <file.plist>]
#                [--runtime | --no-runtime] [--no-timestamp]
#
#   --app           the bundle to sign (modified in place)
#   --identity      codesign identity: a name, a SHA-1 hash, or "-" for ad hoc.
#                   Default: the first "Developer ID Application" identity in the
#                   keychain, else ad hoc.
#   --entitlements  entitlements applied to every Mach-O executable (the launcher,
#                   a bundled interpreter, CLIs) and to the app itself
#   --runtime       enable the Hardened Runtime (default with Developer ID)
#   --no-runtime    disable it (default with ad hoc)
#   --no-timestamp  skip the secure timestamp (Developer ID only; needed offline,
#                   but notarization requires the timestamp)
#
# Order: every Mach-O file (dylibs, .so, executables) in parallel, then nested
# code bundles (.framework .app .appex .xpc .bundle .plugin that carry an
# Info.plist) deepest first, then the app. --deep is used only to verify.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "sign: $*" >&2; exit 1; }

APP="" IDENTITY="" ENTITLEMENTS="" RUNTIME="auto" TIMESTAMP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=${2:?--app needs a value}; shift 2 ;;
    --identity) IDENTITY=${2:?--identity needs a value}; shift 2 ;;
    --entitlements) ENTITLEMENTS=${2:?--entitlements needs a value}; shift 2 ;;
    --runtime) RUNTIME=1; shift ;;
    --no-runtime) RUNTIME=0; shift ;;
    --no-timestamp) TIMESTAMP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $APP ]] || { usage >&2; exit 2; }
APP=${APP%/}
[[ -d $APP && $APP == *.app ]] || die "not an .app bundle: $APP"
[[ -z $ENTITLEMENTS || -f $ENTITLEMENTS ]] || die "entitlements file not found: $ENTITLEMENTS"
if [[ -n $ENTITLEMENTS ]]; then
  plutil -lint -s "$ENTITLEMENTS" || die "entitlements file is not a valid plist"
fi

if [[ -z $IDENTITY ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Developer ID Application/ {print $2; exit}')
  IDENTITY=${IDENTITY:--}
fi
ADHOC=0; [[ $IDENTITY == "-" ]] && ADHOC=1
[[ $RUNTIME == auto ]] && { [[ $ADHOC == 1 ]] && RUNTIME=0 || RUNTIME=1; }

base=(--force --sign "$IDENTITY")
if [[ $ADHOC == 1 ]]; then
  base+=(--timestamp=none)
  echo "sign: identity ad hoc (no Developer ID found or '-' given)"
else
  [[ $TIMESTAMP == 1 ]] && base+=(--timestamp) || base+=(--timestamp=none)
  echo "sign: identity $IDENTITY"
fi
[[ $RUNTIME == 1 ]] && base+=(--options runtime)
exe=("${base[@]}")
[[ -n $ENTITLEMENTS ]] && exe+=(--entitlements "$ENTITLEMENTS")

chmod -R u+w "$APP"
xattr -cr "$APP" 2>/dev/null || true   # Finder info and resource forks break signing

work=$(mktemp -d "${TMPDIR:-/tmp}/sign.XXXXXX")
trap 'rm -rf "$work"' EXIT
SEP=$'\x1f'

# Classify every regular file with one batched `file` run.
find "$APP" -type f -print0 | xargs -0 file -N -F "$SEP" > "$work/types" || true
: > "$work/libs"; : > "$work/exes"
while IFS= read -r line; do
  [[ $line == *"$SEP"* ]] || continue
  path=${line%%"$SEP"*}; desc=${line#*"$SEP"}
  [[ $desc == *Mach-O* ]] || continue
  case "$desc" in
    *"dSYM companion"*) echo "sign: warning: dSYM shipped: $path" >&2; continue ;;
    *object*) continue ;;   # .o files cannot be signed
    *executable*) printf '%s\0' "$path" >> "$work/exes" ;;
    *) printf '%s\0' "$path" >> "$work/libs" ;;
  esac
done < "$work/types"

ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
nlibs=$(tr -cd '\0' < "$work/libs" | wc -c | tr -d ' ')
nexes=$(tr -cd '\0' < "$work/exes" | wc -c | tr -d ' ')
echo "sign: $nlibs libraries/modules, $nexes executables"

# Plain Mach-O files are leaves, so they can be signed in parallel.
if [[ $nlibs -gt 0 ]]; then
  xargs -0 -n 32 -P "$ncpu" codesign "${base[@]}" < "$work/libs" \
    || die "signing libraries failed"
fi
if [[ $nexes -gt 0 ]]; then
  xargs -0 -n 32 -P "$ncpu" codesign "${exe[@]}" < "$work/exes" \
    || die "signing executables failed"
fi

# Nested code bundles, children before parents (find -depth is post-order).
nb=0
while IFS= read -r -d '' b; do
  [[ $b == "$APP" ]] && continue
  if [[ -f $b/Contents/Info.plist || -f $b/Resources/Info.plist || -d $b/Versions ]]; then
    codesign "${base[@]}" "$b" || die "signing bundle failed: $b"
    nb=$((nb + 1))
  fi
done < <(find "$APP/Contents" -depth -type d \( -name '*.framework' -o -name '*.app' \
          -o -name '*.appex' -o -name '*.xpc' -o -name '*.bundle' -o -name '*.plugin' \) -print0)
echo "sign: $nb nested bundles"

codesign "${exe[@]}" "$APP" || die "signing the app failed"
codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | sed 's/^/sign: /'
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|Runtime|CodeDirectory)' \
  | sed 's/^/sign: /' || true
echo "sign: OK $APP"
