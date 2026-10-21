#!/usr/bin/env bash
# bundle-dylibs.sh - copy a binary into a bundle with its whole non-system dylib closure.
#
# Usage: bundle-dylibs.sh --bin <binary> --dest <dir for the binary>
#                         --libs <dir for the dylibs> [--name <new file name>]
#
#   --bin    the executable to bundle (e.g. a Homebrew ffprobe; symlinks are
#            resolved)
#   --dest   where the binary goes, e.g. "App.app/Contents/Resources/bin"
#   --libs   where its dylibs go, e.g. "App.app/Contents/Frameworks/ffprobe"
#            (may be shared by several binaries: libraries already there are
#            reused)
#   --name   the binary's file name in --dest (default: its own)
#
# Walks `otool -L` breadth-first from the binary. Every dependency outside
# /System and /usr/lib (absolute paths, @rpath/..., @loader_path/...,
# @executable_path/... resolved against the original files' LC_RPATH entries)
# is copied into --libs and rewritten: the binary loads them through
# @executable_path/<relative path to --libs>, the libraries load each other
# through @loader_path. Absolute LC_RPATH entries are deleted. Every rewritten
# file is re-signed ad hoc (arm64 refuses unsigned code); sign the whole app
# afterwards with sign.sh as usual.
#
# Prefer a static build of the tool when one exists; this is for the rest.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "bundle-dylibs: $*" >&2; exit 1; }

BIN="" DEST="" LIBS="" NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --libs) LIBS=${2:?}; shift 2 ;;
    --name) NAME=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $BIN && -n $DEST && -n $LIBS ]] || { usage >&2; exit 2; }
[[ -e $BIN ]] || die "no such binary: $BIN"

realpath_() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
  || (cd "$(dirname "$1")" && echo "$(pwd -P)/$(basename "$1")"); }
relpath_() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }

SRC=$(realpath_ "$BIN")
NAME=${NAME:-$(basename "$BIN")}
mkdir -p "$DEST" "$LIBS"
DEST=$(cd "$DEST" && pwd -P)
LIBS=$(cd "$LIBS" && pwd -P)
OUT="$DEST/$NAME"
cp -f "$SRC" "$OUT"; chmod u+w,a+x "$OUT"
REL=$(relpath_ "$LIBS" "$DEST")

deps() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/{f=1} f&&/ path /{print $2; f=0}'; }
system() { [[ $1 == /System/* || $1 == /usr/lib/* ]]; }

# resolve <dep as written> <original file that loads it> -> a real file path
resolve() {
  local dep=$1 loader=$2 ldir rp cand
  ldir=$(dirname "$loader")
  case "$dep" in
    @loader_path/*) cand="$ldir/${dep#@loader_path/}" ;;
    @executable_path/*) cand="$(dirname "$SRC")/${dep#@executable_path/}" ;;
    @rpath/*)
      cand=""
      while IFS= read -r rp; do
        rp=${rp/#@loader_path/$ldir}
        rp=${rp/#@executable_path/$(dirname "$SRC")}
        if [[ -e "$rp/${dep#@rpath/}" ]]; then cand="$rp/${dep#@rpath/}"; break; fi
      done < <(rpaths "$loader"; [[ $loader != "$SRC" ]] && rpaths "$SRC")
      [[ -n $cand ]] || die "can't resolve $dep for $loader"
      ;;
    *) cand=$dep ;;
  esac
  [[ -e $cand ]] || die "missing dependency $dep (from $loader)"
  realpath_ "$cand"
}

QUEUE=$(mktemp); DONE=$(mktemp); trap 'rm -f "$QUEUE" "$DONE"' EXIT
echo "$SRC|$OUT" > "$QUEUE"
count=0
while [[ -s $QUEUE ]]; do
  line=$(head -n 1 "$QUEUE"); sed -i '' '1d' "$QUEUE"
  orig=${line%%|*}; copy=${line#*|}
  grep -qxF "$orig" "$DONE" && continue
  echo "$orig" >> "$DONE"
  if [[ $copy == "$OUT" ]]; then prefix="@executable_path/$REL"; else prefix="@loader_path"; fi
  while IFS= read -r dep; do
    system "$dep" && continue
    [[ $dep == "$(otool -D "$orig" 2>/dev/null | tail -n +2)" ]] && continue   # its own id line
    real=$(resolve "$dep" "$orig")
    base=$(basename "$real")
    if [[ ! -e "$LIBS/$base" ]]; then
      cp -f "$real" "$LIBS/$base"; chmod u+w "$LIBS/$base"
      install_name_tool -id "@loader_path/$base" "$LIBS/$base" 2>/dev/null
      count=$((count + 1))
    fi
    install_name_tool -change "$dep" "$prefix/$base" "$copy" 2>/dev/null
    echo "$real|$LIBS/$base" >> "$QUEUE"
  done < <(deps "$orig")
  while IFS= read -r rp; do
    case "$rp" in @loader_path*|@executable_path*) ;; *) install_name_tool -delete_rpath "$rp" "$copy" 2>/dev/null || true ;; esac
  done < <(rpaths "$copy")
done

for f in "$OUT" "$LIBS"/*; do codesign --force -s - "$f" >/dev/null 2>&1 || die "codesign failed on $f"; done
# nothing may still point outside the bundle or the OS
bad=$(for f in "$OUT" "$LIBS"/*; do deps "$f" | grep -vE '^(/System/|/usr/lib/|@)' | sed "s|^|$f -> |"; done || true)
[[ -z $bad ]] || die "still linked outside: $bad"
"$OUT" -version >/dev/null 2>&1 || "$OUT" --version >/dev/null 2>&1 || echo "bundle-dylibs: note: $NAME has no -version flag to smoke-test" >&2
echo "bundle-dylibs: $OUT with $count new libraries in $LIBS ($(du -sh "$LIBS" | awk '{print $1}'))"
