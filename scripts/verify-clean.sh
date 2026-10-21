#!/usr/bin/env bash
# verify-clean.sh - simulate a clean Mac: mount the DMG, copy the app out, check
# the bundle, launch it with an empty HOME and a minimal PATH, wait for its
# health endpoint, run an optional end-to-end job, watch its network use, quit.
#
# Usage: verify-clean.sh --dmg <file.dmg> --health-path </api/health>
#          [--port-range 4700-4800 | any] [--job-cmd "<shell using $PORT>"]
#          [--forbid-file <patterns.txt>] [--allow-file <patterns.txt>]
#          [--forbid-ports 8000,8080] [--require-arch arm64] [--allow-network]
#          [--timeout 90] [--scan-max-mb 512] [--scratch <dir>] [--keep]
#          [--env KEY=VALUE]...
#
#   --health-path   path that returns HTTP 2xx once the engine is ready
#   --port-range    ports to probe for the health path (default 4700-4800);
#                   "any" probes every port the app tree listens on
#   --job-cmd       run with bash after health passes; env: PORT, BASE_URL,
#                   APP (copied .app), TEST_HOME (the empty HOME). Non-zero fails.
#   --forbid-file   extra extended regexes (one per line, # comments) that must
#                   not appear in the bundle or in any remote endpoint
#   --allow-file    extended regexes; findings ("check: path: detail") matching
#                   one are ignored (e.g. a library that must keep its .py)
#   --forbid-ports  ports the app must neither listen on nor connect to
#   --require-arch  arch every Mach-O must contain (default: this Mac's)
#   --allow-network do not fail on non-loopback connections (still logged, and
#                   forbidden patterns still fail)
#   --timeout       seconds to wait for health (default 90)
#   --scan-max-mb   skip files larger than this in the string scan (default 512)
#   --scratch       work dir (default: a new temp dir)
#   --keep          keep the scratch dir after a pass (always kept on failure)
#   --env           an extra variable for the launched app (repeatable), e.g. a
#                   flag that keeps its window off-screen during the check
#
# Default forbidden patterns: user home paths (/Users/<name>), this Mac's $HOME
# and host names, *.ts.net, private key blocks, sk-ant- / ghp_ / AKIA keys.
# The app is launched through its executable with
#   env -i HOME=<empty dir> PATH=/usr/bin:/bin:/usr/sbin:/sbin
# and is quit with SIGTERM to the launcher: every child must exit on its own.
# Not covered (needs a second Mac): Gatekeeper quarantine and translocation,
# keychain prompts, TCC prompts.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }
die() { echo "verify-clean: $*" >&2; exit 2; }

DMG="" HEALTH="" RANGE="4700-4800" JOB="" FORBID_FILE="" ALLOW_FILE="" FORBID_PORTS=""
REQ_ARCH="" ALLOW_NET=0 TIMEOUT=90 SCAN_MAX_MB=512 SCRATCH="" KEEP=0 EXTRA_ENV=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG=${2:?--dmg needs a value}; shift 2 ;;
    --health-path) HEALTH=${2:?--health-path needs a value}; shift 2 ;;
    --port-range) RANGE=${2:?--port-range needs a value}; shift 2 ;;
    --job-cmd) JOB=${2:?--job-cmd needs a value}; shift 2 ;;
    --forbid-file) FORBID_FILE=${2:?--forbid-file needs a value}; shift 2 ;;
    --allow-file) ALLOW_FILE=${2:?--allow-file needs a value}; shift 2 ;;
    --forbid-ports) FORBID_PORTS=${2:?--forbid-ports needs a value}; shift 2 ;;
    --require-arch) REQ_ARCH=${2:?--require-arch needs a value}; shift 2 ;;
    --allow-network) ALLOW_NET=1; shift ;;
    --timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
    --scan-max-mb) SCAN_MAX_MB=${2:?--scan-max-mb needs a value}; shift 2 ;;
    --scratch) SCRATCH=${2:?--scratch needs a value}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --env) EXTRA_ENV+=("${2:?--env needs KEY=VALUE}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $DMG && -n $HEALTH ]] || { usage >&2; exit 2; }
[[ -f $DMG ]] || die "DMG not found: $DMG"
[[ $HEALTH == /* ]] || HEALTH="/$HEALTH"
[[ -z $FORBID_FILE || -f $FORBID_FILE ]] || die "forbid file not found: $FORBID_FILE"
[[ -z $ALLOW_FILE || -f $ALLOW_FILE ]] || die "allow file not found: $ALLOW_FILE"
if [[ $RANGE != any ]]; then
  [[ $RANGE =~ ^([0-9]+)-([0-9]+)$ ]] || die "--port-range must be LOW-HIGH or any"
  PLO=${BASH_REMATCH[1]} PHI=${BASH_REMATCH[2]}
fi
REQ_ARCH=${REQ_ARCH:-$(uname -m)}
export LC_ALL=C
SAFE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [[ -z $SCRATCH ]]; then SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/verify-clean.XXXXXX")
else mkdir -p "$SCRATCH"; SCRATCH=$(cd "$SCRATCH" && pwd); fi
LOG="$SCRATCH/logs"; MNT="$SCRATCH/mnt"; TEST_HOME="$SCRATCH/home"
rm -rf "$LOG" "$TEST_HOME" "$SCRATCH/Applications"
mkdir -p "$LOG" "$MNT" "$TEST_HOME" "$SCRATCH/Applications"
REPORT="$LOG/report.txt"; : > "$REPORT"
FAILS=0 APP_PID="" SAMPLER_PID="" MOUNTED=0

say() { echo "verify-clean: $*" | tee -a "$REPORT"; }
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; FAILS=$((FAILS + 1)); }
note() { say "INFO $*"; }

# Findings are "check: path: detail"; drop the ones the allow file covers.
{
  echo '^string: .*: /Users/Shared$'
  [[ -n $ALLOW_FILE ]] && grep -Ev '^[[:space:]]*(#|$)' "$ALLOW_FILE"
  true
} > "$LOG/allow.txt"
allowed() { grep -Evf "$LOG/allow.txt" || true; }

tree_pids() { # $1 root pid -> root and all descendants, one per line
  local p=$1 c
  kill -0 "$p" 2>/dev/null && echo "$p"
  for c in $(pgrep -P "$p" 2>/dev/null || true); do tree_pids "$c"; done
}
pid_csv() { tr '\n' ',' | sed 's/,$//'; }

cleanup() {
  [[ -n $SAMPLER_PID ]] && kill "$SAMPLER_PID" 2>/dev/null || true
  if [[ -n $APP_PID ]] && kill -0 "$APP_PID" 2>/dev/null; then
    for p in $(tree_pids "$APP_PID"); do kill -9 "$p" 2>/dev/null || true; done
  fi
  [[ $MOUNTED == 1 ]] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

re_escape() { sed -E 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$1"; }

# Forbidden patterns: defaults + this Mac's identity + the caller's file.
{
  echo '/Users/[A-Za-z0-9._-]+'
  echo '[A-Za-z0-9-]+[.]ts[.]net'
  echo 'PRIVATE KEY-----'
  echo 'sk-ant-[A-Za-z0-9_-]{8,}'
  echo 'ghp_[A-Za-z0-9]{20,}'
  echo 'AKIA[0-9A-Z]{16}'
  re_escape "$HOME"
  for h in "$(scutil --get LocalHostName 2>/dev/null || true)" "$(hostname -s 2>/dev/null || true)"; do
    [[ ${#h} -ge 6 && $h != localhost ]] && re_escape "$h"
  done
  [[ -n $FORBID_FILE ]] && grep -Ev '^[[:space:]]*(#|$)' "$FORBID_FILE"
  true
} | sort -u > "$LOG/forbidden.txt"

say "scratch $SCRATCH"
say "dmg $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"

# 1. Mount and copy.
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MNT" -quiet || die "could not attach $DMG"
MOUNTED=1
listing=$(ls -A "$MNT" | grep -vxE '\.fseventsd|\.Trashes|\.Spotlight-V100' || true)
apps=$(grep -E '\.app$' <<<"$listing" || true)
[[ $(wc -l <<<"$apps" | tr -d ' ') == 1 && -n $apps ]] || die "DMG must hold exactly one .app (found: $(tr '\n' ' ' <<<"$listing"))"
others=$(grep -vxF -e "$apps" -e Applications <<<"$listing" || true)
if [[ -z $others && -L $MNT/Applications ]]; then pass "dmg layout: $apps + Applications link"
else fail "dmg layout: extra entries or no Applications link: $(tr '\n' ' ' <<<"$listing")"; fi
APP="$SCRATCH/Applications/$apps"
ditto "$MNT/$apps" "$APP"
hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 && MOUNTED=0
EXE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null) \
  || die "no CFBundleExecutable in Info.plist"
EXE="$APP/Contents/MacOS/$EXE_NAME"
[[ -x $EXE ]] || die "executable missing: $EXE"
note "app $(basename "$APP") $(du -sh "$APP" | cut -f1 | tr -d ' '), version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"

# 2. Source files.
find "$APP" \( -type d -name .git -o -type f \( -name '*.py' -o -name '*.pyx' -o -name '*.ts' -o -name '*.tsx' \
  -o -name '*.map' -o -name '.DS_Store' \) \) -print | sed 's|^|source: |' | allowed > "$LOG/source.txt"
if [[ -s $LOG/source.txt ]]; then fail "source files: $(wc -l < "$LOG/source.txt" | tr -d ' ') (see $LOG/source.txt)"; head -5 "$LOG/source.txt"
else pass "source files: none"; fi

# 3. Forbidden strings (binary-safe).
find "$APP" -type f -size +"${SCAN_MAX_MB}"M -print > "$LOG/scan-skipped.txt"
find "$APP" -type f ! -size +"${SCAN_MAX_MB}"M -print0 \
  | xargs -0 grep -EaoH -f "$LOG/forbidden.txt" -- 2>/dev/null \
  | sort -u | sed -E 's|^([^:]*):(.*)$|string: \1: \2|' | allowed > "$LOG/strings.txt" || true
[[ -s $LOG/scan-skipped.txt ]] && note "string scan skipped $(wc -l < "$LOG/scan-skipped.txt" | tr -d ' ') file(s) over ${SCAN_MAX_MB} MB (see $LOG/scan-skipped.txt)"
if [[ -s $LOG/strings.txt ]]; then fail "forbidden strings: $(wc -l < "$LOG/strings.txt" | tr -d ' ') (see $LOG/strings.txt)"
  head -5 "$LOG/strings.txt"
else pass "forbidden strings: none"; fi

# 4. Mach-O files: arch and link closure.
SEP=$'\x1f'
find "$APP" -type f -print0 | xargs -0 file -N -F "$SEP" | grep -F "$SEP" \
  | awk -F"$SEP" '$2 ~ /Mach-O/ && $2 !~ /object|dSYM/ {print $1}' > "$LOG/macho.txt" || true
nmacho=$(wc -l < "$LOG/macho.txt" | tr -d ' ')
: > "$LOG/arch.txt"; : > "$LOG/links.txt"
while IFS= read -r f; do
  a=$(lipo -archs "$f" 2>/dev/null || echo unknown)
  echo "$a" >> "$LOG/arch.txt"
  grep -qw -- "$REQ_ARCH" <<<"$a" || echo "arch: $f: has [$a], lacks $REQ_ARCH" >> "$LOG/arch-missing.txt"
  # Linked libraries outside the OS and the bundle.
  # Dependency lines start with a tab (a fat file has one header line per
  # arch, and paths may contain spaces); a dylib's own install name is no
  # dependency.
  # (one install name per arch in a fat file)
  self_id=$(otool -D "$f" 2>/dev/null | grep -v ':$' || true)
  otool -L "$f" 2>/dev/null | grep -E $'^\t' | sed -E $'s/^\t//; s/ \\(compatibility version.*$//' \
    | { if [[ -n $self_id ]]; then grep -vxF -- "$self_id"; else cat; fi; } \
    | grep -Ev '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' \
    | sed "s|^|link: $f: |" >> "$LOG/links.txt" || true
  # Absolute rpaths that point outside the bundle.
  otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/ {r=1} r && $1 == "path" {print $2; r=0}' \
    | grep -Ev '^(@loader_path|@executable_path|/usr/lib|/System)' \
    | sed "s|^|rpath: $f: |" >> "$LOG/links.txt" || true
done < "$LOG/macho.txt"
note "mach-o files: $nmacho; arch sets: $(sort "$LOG/arch.txt" | uniq -c | sed -E 's/^ *([0-9]+) (.*)$/[\2] x\1/' | paste -sd ' ' -)"
note "main executable: $(file -b "$EXE" | cut -c1-120)"
allowed < "$LOG/links.txt" | sort -u > "$LOG/links-bad.txt"
if [[ -s $LOG/links-bad.txt ]]; then fail "link closure: $(wc -l < "$LOG/links-bad.txt" | tr -d ' ') external dylib/rpath reference(s) (see $LOG/links-bad.txt)"
  head -5 "$LOG/links-bad.txt"
else pass "link closure: only /usr/lib, /System and bundle-relative"; fi
touch "$LOG/arch-missing.txt"
allowed < "$LOG/arch-missing.txt" > "$LOG/arch-bad.txt"
if [[ -s $LOG/arch-bad.txt ]]; then fail "arch: $(wc -l < "$LOG/arch-bad.txt" | tr -d ' ') Mach-O file(s) lack $REQ_ARCH (see $LOG/arch-bad.txt)"
else pass "arch: every Mach-O has $REQ_ARCH"; fi

# 5. Signature.
if codesign --verify --strict --deep --verbose=2 "$APP" > "$LOG/codesign.txt" 2>&1; then
  sig=$(codesign -dv "$APP" 2>&1 | grep -E '^(Signature|Authority|TeamIdentifier)=' | head -3 | tr '\n' ' ')
  pass "codesign verify ($sig)"
else fail "codesign verify (see $LOG/codesign.txt)"; tail -3 "$LOG/codesign.txt"; fi
spctl -a -vv -t exec "$APP" > "$LOG/spctl.txt" 2>&1 \
  && note "gatekeeper: accepted" \
  || note "gatekeeper: $(head -1 "$LOG/spctl.txt" | sed 's|^.*: ||') (expected without notarization; users need Control-click > Open)"

# 6. Launch with a clean environment.
listeners() { # pids csv -> "addr:port" per listening TCP socket
  [[ -n $1 ]] || return 0
  lsof -nP -a -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u || true
}
sample_loop() { # background: record every socket of the app tree
  while kill -0 "$APP_PID" 2>/dev/null; do
    pids=$(tree_pids "$APP_PID" | pid_csv)
    if [[ -n $pids ]]; then
      { echo "# $(date +%H:%M:%S) pids $pids"; lsof -nP -a -p "$pids" -i 2>/dev/null | tail -n +2 || true; } >> "$LOG/lsof.txt"
    fi
    sleep 0.5
  done
}
note "launch: env -i HOME=$TEST_HOME PATH=$SAFE_PATH $EXE"
( cd "$TEST_HOME" && exec env -i HOME="$TEST_HOME" PATH="$SAFE_PATH" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$EXE" ) \
  > "$LOG/app-stdout.log" 2> "$LOG/app-stderr.log" &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true   # no job-control notice when it is terminated
: > "$LOG/lsof.txt"
sample_loop & SAMPLER_PID=$!
disown "$SAMPLER_PID" 2>/dev/null || true

PORT="" t0=$(date +%s)
while [[ -z $PORT ]]; do
  kill -0 "$APP_PID" 2>/dev/null || { fail "launch: the app exited during startup (see $LOG/app-stderr.log)"; tail -20 "$LOG/app-stderr.log"; break; }
  pids=$(tree_pids "$APP_PID" | pid_csv)
  for l in $(listeners "$pids"); do
    p=${l##*:}
    [[ $RANGE == any ]] || { [[ $p -ge $PLO && $p -le $PHI ]] || continue; }
    if curl -fsS -m 3 -o "$LOG/health.txt" "http://127.0.0.1:$p$HEALTH" 2>/dev/null; then PORT=$p; break; fi
  done
  [[ -n $PORT ]] && break
  if (( $(date +%s) - t0 >= TIMEOUT )); then
    fail "health: no answer on $HEALTH within ${TIMEOUT}s (listeners: $(listeners "$pids" | tr '\n' ' '))"; break
  fi
  sleep 0.5
done

if [[ -n $PORT ]]; then
  pass "health: http://127.0.0.1:$PORT$HEALTH after $(( $(date +%s) - t0 ))s: $(head -c 120 "$LOG/health.txt" | tr '\n' ' ')"
  # 7. Optional end-to-end job.
  if [[ -n $JOB ]]; then
    jt=$(date +%s)
    if ( cd "$SCRATCH" && PORT="$PORT" BASE_URL="http://127.0.0.1:$PORT" APP="$APP" TEST_HOME="$TEST_HOME" \
         bash -c "$JOB" ) > "$LOG/job.log" 2>&1; then
      pass "job: ok in $(( $(date +%s) - jt ))s: $(tail -1 "$LOG/job.log" | cut -c1-160)"
    else
      fail "job: exit $? (see $LOG/job.log)"; tail -10 "$LOG/job.log"
    fi
  else
    note "job: none given (--job-cmd); only health was exercised"
  fi
  sleep 1
fi

# 8. Quit: SIGTERM the launcher; every child must exit by itself.
pids_before=$(tree_pids "$APP_PID")
note "process tree at quit: $(tr '\n' ' ' <<<"$pids_before")"
kill -TERM "$APP_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
  alive=""; for p in $pids_before; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
  [[ -z $alive ]] && break
  sleep 0.5
done
if [[ -n $alive ]]; then
  fail "quit: still running 10s after SIGTERM:$alive ($(ps -o comm= -p "$(tr ' ' ',' <<<"${alive# }")" 2>/dev/null | tr '\n' ' '))"
  for p in $alive; do kill -9 "$p" 2>/dev/null || true; done
else pass "quit: launcher and all children exited"; fi
kill "$SAMPLER_PID" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$SAMPLER_PID" 2>/dev/null || break; sleep 0.1; done
SAMPLER_PID=""

# 9. Network evidence.
nsamples=$(grep -c '^# ' "$LOG/lsof.txt" || true)
# lsof columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [STATE]
awk '!/^#/ && NF >= 9 {print $8, $9, $10}' "$LOG/lsof.txt" | sort -u > "$LOG/sockets.txt"
is_loop() { [[ $1 =~ ^(127\.[0-9.]+|\[::1\]|localhost|\*):[0-9*]+$ ]]; }
: > "$LOG/net-bad.txt"
while read -r proto name state; do
  [[ -z ${name:-} ]] && continue
  if [[ $name == *"->"* ]]; then local_ep=${name%%->*}; remote=${name#*->}; else local_ep=$name; remote=""; fi
  if [[ $state == "(LISTEN)" && ! $local_ep =~ ^(127\.[0-9.]+|\[::1\]): ]]; then
    echo "net: listen on non-loopback $local_ep ($proto)" >> "$LOG/net-bad.txt"
  fi
  if [[ -n $remote ]] && ! is_loop "$remote"; then
    if grep -Eqf "$LOG/forbidden.txt" <<<"$remote"; then echo "net: forbidden remote $remote ($proto)" >> "$LOG/net-bad.txt"
    elif [[ $ALLOW_NET == 0 ]]; then echo "net: non-loopback remote $remote ($proto $state)" >> "$LOG/net-bad.txt"
    else echo "net: allowed remote $remote ($proto $state)" >> "$LOG/net-allowed.txt"; fi
  fi
  if [[ -n $FORBID_PORTS ]]; then
    for fp in ${FORBID_PORTS//,/ }; do
      for ep in "$local_ep" "$remote"; do
        [[ -n $ep && ${ep##*:} == "$fp" ]] && echo "net: forbidden port $fp in $name ($proto)" >> "$LOG/net-bad.txt"
      done
    done
  fi
done < "$LOG/sockets.txt"
allowed < "$LOG/net-bad.txt" | sort -u > "$LOG/net-fail.txt"
if [[ -s $LOG/net-fail.txt ]]; then fail "network: $(wc -l < "$LOG/net-fail.txt" | tr -d ' ') issue(s) in $nsamples samples (see $LOG/net-fail.txt)"; head -5 "$LOG/net-fail.txt"
else pass "network: $nsamples lsof samples, $(wc -l < "$LOG/sockets.txt" | tr -d ' ') distinct sockets, loopback only$([[ -s $LOG/net-allowed.txt ]] && echo ' (plus allowed remotes, see net-allowed.txt)')"; fi

# 10. Sizes and verdict.
note "sizes: dmg $(du -h "$DMG" | cut -f1 | tr -d ' '), app $(du -sh "$APP" | cut -f1 | tr -d ' ')"
note "not verified here (needs a second Mac): Gatekeeper quarantine/translocation, keychain prompts, TCC prompts"
if [[ $FAILS == 0 ]]; then
  say "RESULT PASS (report $REPORT)"
  if [[ $KEEP == 0 ]]; then
    rm -rf "$SCRATCH/Applications" "$TEST_HOME"
    say "removed the app copy and test HOME; logs kept in $LOG (use --keep to keep everything)"
  else say "kept $SCRATCH"; fi
  exit 0
fi
say "RESULT FAIL: $FAILS check(s) (scratch kept: $SCRATCH)"
exit 1
