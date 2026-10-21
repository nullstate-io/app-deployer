#!/usr/bin/env bash
# python-embed.sh - put a relocatable Python and pinned packages into an app bundle.
#
# Usage: python-embed.sh --dest <Resources/python> --requirements <pinned.txt>
#                        [--python 3.13.14] [--keep-stdlib] [--prune-extra "a b"]
#
#   --dest          where the runtime goes (created; must not exist or be empty),
#                   e.g. "My App.app/Contents/Resources/python"
#   --requirements  a fully pinned list (name==version per line), installed with
#                   --no-deps so nothing outside the list sneaks in. Make it from
#                   the dev venv: `pip freeze`, minus dev/test tools and heavy
#                   packages the app never imports (check with an import trace).
#   --python        a python-build-standalone version for `uv python install`
#                   (default 3.13). These builds are relocatable: libpython is
#                   found through @executable_path, the stdlib relative to it.
#   --keep-stdlib   skip pruning the stdlib (test, idlelib, tkinter, turtledemo,
#                   ensurepip, Tcl/Tk, headers, pkgconfig, man pages)
#   --prune-extra   more site-packages top-level names to delete after install
#                   (test-only distributions that ride along, e.g. "PyObjCTest")
#
# Needs uv (https://docs.astral.sh/uv/). Downloads only what uv does not have in
# its cache: the Python build and the wheels in the list.
# Afterwards: run python-strip-source.sh on the dest, then sign the bundle.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "python-embed: $*" >&2; exit 1; }

DEST="" REQ="" PYVER="3.13" KEEP_STDLIB=0 EXTRA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST=${2:?}; shift 2 ;;
    --requirements) REQ=${2:?}; shift 2 ;;
    --python) PYVER=${2:?}; shift 2 ;;
    --keep-stdlib) KEEP_STDLIB=1; shift ;;
    --prune-extra) EXTRA=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $DEST && -n $REQ ]] || { usage >&2; exit 2; }
[[ -f $REQ ]] || die "no requirements file at $REQ"
command -v uv >/dev/null || die "uv is not installed"
if [[ -e $DEST ]] && [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then die "$DEST is not empty"; fi

uv python install "$PYVER" >/dev/null 2>&1 || die "uv python install $PYVER failed"
SRC_PY=$(uv python find --managed-python "$PYVER" 2>/dev/null || uv python find "$PYVER")
SRC_PREFIX=$(cd "$(dirname "$SRC_PY")/.." && pwd -P)
[[ -d $SRC_PREFIX/lib ]] || die "$SRC_PREFIX does not look like a Python install"
# Relocatable = links nothing outside the OS and itself (python-build-standalone
# links libpython statically or through @executable_path / @rpath).
OUTSIDE=$(otool -L "$SRC_PY" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/|/usr/lib/|@)' || true)
[[ -z $OUTSIDE ]] || die "$SRC_PY links outside the OS ($OUTSIDE); it is not relocatable"

mkdir -p "$DEST"
ditto "$SRC_PREFIX" "$DEST"
PY="$DEST/bin/python3"
"$PY" -c 'import sys; print("python-embed: runtime", sys.version.split()[0], sys.prefix)'
MINOR=$("$PY" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
STDLIB="$DEST/lib/python$MINOR"
SITE="$STDLIB/site-packages"
rm -f "$STDLIB/EXTERNALLY-MANAGED"

# The packages: exactly the pinned list, no resolver surprises.
uv pip install --python "$PY" --no-deps --link-mode copy \
  --target "$SITE" -r "$REQ" 2>&1 | tail -3 || die "uv pip install failed"
# pip itself, when the app updates a package at runtime (pip install --target)
grep -qiE '^pip(==|$)' "$REQ" && echo "python-embed: pip is in the list"

if [[ $KEEP_STDLIB -eq 0 ]]; then
  for d in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data __phello__; do
    rm -rf "${STDLIB:?}/$d"
  done
  rm -rf "$STDLIB"/config-* "$DEST/include" "$DEST/share" "$DEST/lib/pkgconfig" \
         "$DEST"/lib/tcl* "$DEST"/lib/tk* "$DEST"/lib/itcl* "$DEST"/lib/thread* \
         "$DEST"/lib/libtcl* "$DEST"/lib/libtk* "$STDLIB"/lib-dynload/_tkinter*
  rm -f "$DEST"/bin/idle* "$DEST"/bin/pydoc* "$DEST"/bin/2to3* "$DEST"/bin/python*-config
fi
for name in $EXTRA; do rm -rf "${SITE:?}/$name"; done
# Console-script shims carry the build machine's absolute interpreter path
# (uv --target puts them in site-packages/bin), and wheels sometimes ship
# debug symbols with build paths in them.
find "$DEST/bin" -type f ! -name 'python*' -exec grep -lI '^#!/' {} + 2>/dev/null | xargs rm -f || true
rm -rf "$SITE/bin"
find "$DEST" -name '*.dSYM' -type d -prune -exec rm -rf {} +
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +

# Build-machine paths: uv records its install prefix (under the builder's home)
# in sysconfig and in libpython's install name; wheels carry their CI's
# absolute LC_RPATHs (the CI runner's home, Homebrew Cellar paths). None exist on
# the target; rewrite or drop them so nothing points outside the bundle.
grep -rlIF "$SRC_PREFIX" "$DEST" 2>/dev/null | while IFS= read -r f; do
  LC_ALL=C sed -i '' "s#$SRC_PREFIX#/install#g" "$f"
done
for lib in "$DEST"/lib/libpython*.dylib; do
  [[ -f $lib && ! -L $lib ]] || continue
  case "$(otool -D "$lib" | tail -n +2)" in @*) ;; *)
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    codesign --force -s - "$lib" >/dev/null 2>&1 ;;
  esac
done
nrp=0
while IFS= read -r -d '' f; do
  changed=0
  while IFS= read -r rp; do
    case "$rp" in @*) continue ;; esac
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null && changed=1
  done < <(otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{r=1} r&&$1=="path"{print $2; r=0}' | sort -u)
  if [[ $changed -eq 1 ]]; then codesign --force -s - "$f" >/dev/null 2>&1; nrp=$((nrp + 1)); fi
done < <(find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)
echo "python-embed: dropped absolute LC_RPATHs from $nrp libraries"

"$PY" -c 'import ssl, sqlite3, ctypes, zlib, lzma, bz2; print("python-embed: core modules ok")'
echo "python-embed: $(du -sh "$DEST" | cut -f1) in $DEST"
