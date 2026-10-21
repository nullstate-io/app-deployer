#!/usr/bin/env bash
# python-strip-source.sh - compile Python trees to sourceless .pyc and delete the source.
#
# Usage: python-strip-source.sh --python <bundled python3> [--keep <glob>]... <dir>...
#
#   --python   the interpreter that will run the code (the bundled one: the
#              .pyc magic number must match it exactly)
#   --keep     a path glob (relative to each dir, e.g. 'site-packages/foo/*.py')
#              whose .py files stay, for the rare library that reads its own
#              source at runtime (inspect.getsource, torch.jit.script). Repeatable.
#   <dir>      trees to process: the bundled runtime (Resources/python) and the
#              app's own code (Resources/app)
#
# What it does, per dir:
#   1. compileall -b (legacy layout): foo.py -> foo.pyc beside it, which Python
#      imports without the source. Invalidation mode unchecked-hash, so a
#      sourceless file is never "stale".
#   2. deletes every .py (except --keep), .pyi, .pyx, .pxd, __pycache__,
#      tests/ and test/ package folders inside site-packages, and the C
#      sources/headers wheels ship (*.dist-info/RECORD is left alone: harmless).
#   3. fails if any .py is left outside --keep.
# Then smoke-test the app with the bundled interpreter (imports can only be
# proven by running them), and sign afterwards (this changes files).
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "python-strip-source: $*" >&2; exit 1; }

PY="" KEEP=() DIRS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --python) PY=${2:?}; shift 2 ;;
    --keep) KEEP+=("${2:?}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown argument: $1" ;;
    *) DIRS+=("$1"); shift ;;
  esac
done
[[ -n $PY && ${#DIRS[@]} -gt 0 ]] || { usage >&2; exit 2; }
[[ -x $PY ]] || die "$PY is not executable"

kept() {   # is $1 (relative path) protected by a --keep glob?
  local rel=$1 g
  for g in ${KEEP[@]+"${KEEP[@]}"}; do
    # shellcheck disable=SC2053
    [[ $rel == $g ]] && return 0
  done
  return 1
}

for dir in "${DIRS[@]}"; do
  dir=${dir%/}
  [[ -d $dir ]] || die "no such dir: $dir"
  echo "python-strip-source: compiling $dir"
  # -q quiet, -f force, -j0 all cores, -b legacy .pyc beside the source
  # -s/-p: the file names recorded in the bytecode (tracebacks, warnings) are
  # "<dir name>/..." instead of the build machine's absolute path
  "$PY" -E -s -W ignore -m compileall -q -f -b -j0 --invalidation-mode unchecked-hash \
    -s "$dir" -p "$(basename "$dir")" "$dir" >/dev/null \
    || echo "python-strip-source: warning: some files did not compile (py2-only test data, templates); they are deleted below" >&2
  n=0
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    if kept "$rel"; then continue; fi
    # a file that did not compile was never importable (templates, py2 fixtures)
    rm -f "$f"; n=$((n + 1))
  done < <(find "$dir" -type f -name '*.py' -print0)
  find "$dir" -type d -name '__pycache__' -prune -exec rm -rf {} +
  find "$dir" -type f \( -name '*.pyi' -o -name '*.pyx' -o -name '*.pxd' -o -name '*.pxi' \
    -o -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -delete
  find "$dir" -type f -name 'py.typed' -delete
  # test packages inside site-packages (never imported by an app)
  while IFS= read -r -d '' t; do
    rel=${t#"$dir"/}
    kept "$rel/x.py" && continue
    rm -rf "$t"
  done < <(find "$dir" -path '*site-packages/*' -type d \( -name tests -o -name test -o -name testing_data -o -name SelfTest \) -prune -print0)
  find "$dir" -type d -empty -delete 2>/dev/null || true
  left=$(find "$dir" -type f -name '*.py' | while read -r f; do kept "${f#"$dir"/}" || echo "$f"; done | head -5)
  [[ -z $left ]] || die "source left in $dir: $left"
  echo "python-strip-source: $dir: removed $n .py files"
done
