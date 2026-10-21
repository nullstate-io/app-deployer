#!/usr/bin/env bash
# node-embed.sh - put a pinned Node runtime and a production copy of a Node app
# into an app bundle's Resources directory.
#
# Usage: node-embed.sh --node <path-to-node | version> --app-src <dir> --dest <Resources dir>
#                      [--bundle <entry.js>] [--allow-download] [--keep-ts]
#
#   --node            a node binary path, or a version (22.11.0 / v22.11.0) looked
#                     up in $NVM_DIR/versions/node (default ~/.nvm)
#   --app-src         the app's source folder (needs package.json and a lockfile)
#   --dest            Resources dir; writes <dest>/node/bin/node and <dest>/app/
#   --bundle          after install, bundle this entry (relative to --app-src)
#                     with esbuild into <dest>/app/main.js (minified); node_modules
#                     is then removed unless native addons (*.node) need it
#   --allow-download  if the version is not installed locally, fetch the official
#                     darwin tarball from nodejs.org and verify SHASUMS256.txt
#   --keep-ts         keep *.ts files (some packages ship runtime .ts; rare)
#
# The install runs in a copy (npm ci --omit=dev), never in --app-src. Pruned:
# .git, tests, docs, examples, *.map, *.ts, *.md, .github, editor configs.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "node-embed: $*" >&2; exit 1; }

NODE="" SRC="" DEST="" ENTRY="" DOWNLOAD=0 KEEP_TS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE=${2:?--node needs a value}; shift 2 ;;
    --app-src) SRC=${2:?--app-src needs a value}; shift 2 ;;
    --dest) DEST=${2:?--dest needs a value}; shift 2 ;;
    --bundle) ENTRY=${2:?--bundle needs a value}; shift 2 ;;
    --allow-download) DOWNLOAD=1; shift ;;
    --keep-ts) KEEP_TS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $NODE && -n $SRC && -n $DEST ]] || { usage >&2; exit 2; }
SRC=${SRC%/}
[[ -f $SRC/package.json ]] || die "no package.json in $SRC"
[[ -f $SRC/package-lock.json || -f $SRC/npm-shrinkwrap.json ]] \
  || die "no package-lock.json in $SRC (npm ci needs a lockfile for a pinned install)"

work=$(mktemp -d "${TMPDIR:-/tmp}/node-embed.XXXXXX")
trap 'rm -rf "$work"' EXIT

arch=$(uname -m); [[ $arch == x86_64 ]] && narch=x64 || narch=arm64

# Resolve the node binary.
if [[ -x $NODE && ! -d $NODE ]]; then
  NODE_BIN=$NODE
else
  ver=${NODE#v}
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--node is neither an executable nor a version: $NODE"
  NODE_BIN="${NVM_DIR:-$HOME/.nvm}/versions/node/v$ver/bin/node"
  if [[ ! -x $NODE_BIN ]]; then
    [[ $DOWNLOAD == 1 ]] || die "node v$ver not installed under ${NVM_DIR:-$HOME/.nvm}; pass --allow-download or a binary path"
    tarball="node-v$ver-darwin-$narch.tar.gz"
    base="https://nodejs.org/dist/v$ver"
    curl -fsSL -o "$work/$tarball" "$base/$tarball" || die "download failed: $base/$tarball"
    curl -fsSL -o "$work/SHASUMS256.txt" "$base/SHASUMS256.txt" || die "download failed: SHASUMS256.txt"
    want=$(awk -v f="$tarball" '$2 == f {print $1}' "$work/SHASUMS256.txt")
    got=$(shasum -a 256 "$work/$tarball" | awk '{print $1}')
    [[ -n $want && $want == "$got" ]] || die "checksum mismatch for $tarball"
    tar -xzf "$work/$tarball" -C "$work"
    NODE_BIN="$work/node-v$ver-darwin-$narch/bin/node"
  fi
fi
file -b "$NODE_BIN" | grep -q Mach-O || die "not a Mach-O binary: $NODE_BIN"
NODE_VER=$("$NODE_BIN" --version)
echo "node-embed: node $NODE_VER ($(lipo -archs "$NODE_BIN"))"

# npm from the same install when possible, so the lockfile is read by a matching npm.
NPM_CLI="$(cd "$(dirname "$NODE_BIN")/.." && pwd)/lib/node_modules/npm/bin/npm-cli.js"
if [[ -f $NPM_CLI ]]; then npm_cmd=("$NODE_BIN" "$NPM_CLI")
elif command -v npm >/dev/null 2>&1; then npm_cmd=(npm)
else die "npm not found next to $NODE_BIN or on PATH"; fi

# Install production deps in a copy.
mkdir -p "$work/app"
rsync -a --exclude .git --exclude node_modules --exclude .DS_Store "$SRC/" "$work/app/"
( cd "$work/app" && PATH="$(dirname "$NODE_BIN"):$PATH" \
    "${npm_cmd[@]}" ci --omit=dev --no-audit --no-fund --prefer-offline --loglevel=error ) \
  || die "npm ci failed"

if [[ -n $ENTRY ]]; then
  [[ -f $work/app/$ENTRY ]] || die "bundle entry not found: $ENTRY"
  esb=""
  if [[ -x $SRC/node_modules/.bin/esbuild ]]; then esb=$SRC/node_modules/.bin/esbuild
  elif command -v esbuild >/dev/null 2>&1; then esb=$(command -v esbuild)
  else die "--bundle needs esbuild (in $SRC/node_modules/.bin or on PATH)"; fi
  "$esb" "$work/app/$ENTRY" --bundle --platform=node --minify --legal-comments=none \
    --target="node${NODE_VER#v}" --external:'*.node' --outfile="$work/main.js" --log-level=warning \
    || die "esbuild failed"
  if find "$work/app/node_modules" -name '*.node' -type f 2>/dev/null | grep -q .; then
    echo "node-embed: native addons present; keeping node_modules beside main.js"
    find "$work/app" -mindepth 1 -maxdepth 1 ! -name node_modules ! -name package.json -exec rm -rf {} +
  else
    rm -rf "$work/app"; mkdir -p "$work/app"
    cp "$SRC/package.json" "$work/app/package.json"
  fi
  mv "$work/main.js" "$work/app/main.js"
fi

# Prune.
A="$work/app"
find "$A" -type d \( -name .git -o -name .github -o -name test -o -name tests -o -name __tests__ \
  -o -name docs -o -name doc -o -name example -o -name examples -o -name .vscode -o -name .idea \
  -o -name coverage \) -prune -exec rm -rf {} +
find "$A" -type f \( -name '*.map' -o -name '*.md' -o -name '*.markdown' -o -name '.DS_Store' \
  -o -name '.npmignore' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig*.json' \
  -o -name '*.tsbuildinfo' \) -delete
[[ $KEEP_TS == 1 ]] || find "$A" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' \) -delete
find "$A" -type d -empty -delete

mkdir -p "$DEST/node/bin"
rm -rf "$DEST/app"
cp "$NODE_BIN" "$DEST/node/bin/node"
chmod 755 "$DEST/node/bin/node"
ditto "$A" "$DEST/app"
echo "node-embed: OK $DEST/node/bin/node ($NODE_VER), $DEST/app ($(du -sh "$DEST/app" | cut -f1 | tr -d ' '))"
echo "node-embed: re-sign the bundle afterwards (sign.sh); the official node signature is replaced"
