#!/usr/bin/env bash
# make-dmg.sh - build a drag-to-Applications DMG holding one .app.
#
# Usage: make-dmg.sh --app <path.app> --out <file.dmg> [--volname NAME]
#                    [--format UDZO|ULFO|ULMO] [--fs HFS+|APFS] [--identity ID]
#
#   --app       the (already signed) .app to ship
#   --out       DMG to write; replaced if it exists
#   --volname   volume name shown in Finder (default: the app name)
#   --format    UDZO zlib, opens everywhere (default); ULFO lzfse, 10.11+;
#               ULMO lzma, 10.15+
#   --fs        file system inside the image (default HFS+)
#   --identity  also codesign the DMG with this identity (Developer ID only)
#
# The image holds only the app and an /Applications symlink. Afterwards the
# script checks the image checksum, attaches it read-only without Finder,
# checks the listing and the app signature, and prints the size.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "make-dmg: $*" >&2; exit 1; }

APP="" OUT="" VOL="" FORMAT="UDZO" FS="HFS+" IDENTITY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=${2:?--app needs a value}; shift 2 ;;
    --out) OUT=${2:?--out needs a value}; shift 2 ;;
    --volname) VOL=${2:?--volname needs a value}; shift 2 ;;
    --format) FORMAT=${2:?--format needs a value}; shift 2 ;;
    --fs) FS=${2:?--fs needs a value}; shift 2 ;;
    --identity) IDENTITY=${2:?--identity needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $APP && -n $OUT ]] || { usage >&2; exit 2; }
APP=${APP%/}
[[ -d $APP && $APP == *.app ]] || die "not an .app bundle: $APP"
case "$FORMAT" in UDZO|ULFO|ULMO) ;; *) die "unsupported format: $FORMAT" ;; esac
case "$FS" in HFS+|APFS) ;; *) die "unsupported file system: $FS" ;; esac
[[ $OUT == *.dmg ]] || OUT="$OUT.dmg"
APPNAME=$(basename "$APP")
VOL=${VOL:-${APPNAME%.app}}

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")
MNT=""
cleanup() {
  if [[ -n $MNT ]]; then hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$STAGE/root"
ditto "$APP" "$STAGE/root/$APPNAME"
xattr -dr com.apple.quarantine "$STAGE/root/$APPNAME" 2>/dev/null || true
find "$STAGE/root" -name .DS_Store -delete
ln -s /Applications "$STAGE/root/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE/root" -fs "$FS" \
  -format "$FORMAT" -ov "$OUT" || die "hdiutil create failed"

if [[ -n $IDENTITY ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$OUT" || die "signing the DMG failed"
fi

# Verify: checksum, then a read-only mount and its exact listing.
hdiutil verify -quiet "$OUT" || die "checksum verification failed"
MNT=$(mktemp -d "${TMPDIR:-/tmp}/make-dmg-mnt.XXXXXX")
hdiutil attach "$OUT" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet \
  || die "could not attach the image"

listing=$(ls -A "$MNT" | grep -vxE '\.fseventsd|\.Trashes|\.Spotlight-V100' || true)
expected=$(printf '%s\n%s' "$APPNAME" "Applications" | sort)
[[ $(sort <<<"$listing") == "$expected" ]] || die "unexpected contents: $(tr '\n' ' ' <<<"$listing")"
[[ -L $MNT/Applications && $(readlink "$MNT/Applications") == /Applications ]] \
  || die "Applications is not a symlink to /Applications"
if find "$MNT" -name .DS_Store 2>/dev/null | grep -q .; then die ".DS_Store found in image"; fi
if codesign -dv "$MNT/$APPNAME" >/dev/null 2>&1; then
  codesign --verify --strict --deep "$MNT/$APPNAME" || die "app signature invalid inside the image"
  sig="signed"
else
  sig="UNSIGNED"
  echo "make-dmg: warning: the app is not signed" >&2
fi
echo "make-dmg: volume \"$VOL\": $(tr '\n' ' ' <<<"$listing")(app $sig)"

bytes=$(stat -f %z "$OUT")
echo "make-dmg: OK $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '), $bytes bytes, $FORMAT/$FS)"
