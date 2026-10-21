#!/usr/bin/env bash
# scan-secrets.sh - find secrets and private details in a directory tree.
#
# Usage: scan-secrets.sh [--no-gitleaks] <dir>
#
# Checks (text and binary files, .git skipped):
#   keys      private key blocks, Anthropic/OpenAI/GitHub/AWS/Slack/Google/Stripe
#             keys, JWTs, key=value assignments of long secrets
#   paths     user home paths (/Users/<name>, /home/<name>), this Mac's $HOME
#   hosts     tailnet names (*.ts.net), this Mac's host names
#   lan       private and CGNAT IPv4 addresses
#   email     email addresses
# gitleaks also runs when installed (skip with --no-gitleaks).
#
# Environment:
#   ALLOW_EMAILS   comma-separated addresses to ignore
#   ALLOW_REGEX    extended regex; finding lines ("check file:line: match")
#                  that match it are ignored
#   SCAN_EXCLUDE   comma-separated directory names to skip
#
# Exit status: 0 clean, 1 findings, 2 usage error.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; }

GITLEAKS=1 DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-gitleaks) GITLEAKS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) DIR=$1; shift ;;
  esac
done
[[ -n $DIR && -d $DIR ]] || { usage >&2; exit 2; }

export LC_ALL=C
work=$(mktemp -d "${TMPDIR:-/tmp}/scan-secrets.XXXXXX")
trap 'rm -rf "$work"' EXIT

excl=(--exclude-dir=.git)
if [[ -n ${SCAN_EXCLUDE:-} ]]; then
  IFS=',' read -r -a ex <<<"$SCAN_EXCLUDE"
  for e in "${ex[@]}"; do [[ -n $e ]] && excl+=("--exclude-dir=$e"); done
fi

# Escape a literal string for use inside an extended regex.
re_escape() { sed -E 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$1"; }

# Each pattern is written with character classes so this file never matches itself.
cat > "$work/keys" <<'EOF'
-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----
sk-ant-[A-Za-z0-9_-]{20,}
sk-(proj-|svcacct-)?[A-Za-z0-9_-]{40,}
gh[pousr]_[A-Za-z0-9]{36,}
github_pat_[A-Za-z0-9_]{40,}
(AKIA|ASIA)[0-9A-Z]{16}
xox[abeprs]-[A-Za-z0-9-]{10,}
AIza[0-9A-Za-z_-]{35}
[rs]k_live_[0-9A-Za-z]{20,}
eyJ[A-Za-z0-9_-]{10,}[.]eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}
EOF
generic='(api[_-]?key|secret|token|passwd|password|bearer)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9/+_.=-]{16,}["'"'"']'

{
  echo '/Users/[A-Za-z0-9._-]+'
  echo '/home/[a-z_][a-z0-9_-]+'
  [[ -n ${HOME:-} && $HOME != / ]] && re_escape "$HOME"
} > "$work/paths"

{
  echo '[A-Za-z0-9-]+[.]ts[.]net'
  for h in "$(scutil --get LocalHostName 2>/dev/null || true)" "$(hostname -s 2>/dev/null || true)"; do
    # Only distinctive names; a short generic one would flag everything.
    [[ ${#h} -ge 6 && $h != localhost ]] && re_escape "$h"
  done
} | sort -u > "$work/hosts"

octet='[0-9]{1,3}'
lan="(^|[^0-9.])(10[.]$octet[.]$octet[.]$octet|192[.]168[.]$octet[.]$octet|172[.](1[6-9]|2[0-9]|3[01])[.]$octet[.]$octet|100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]$octet[.]$octet)([^0-9.]|$)"
email='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.][A-Za-z]{2,}'

# run <label> <grep flags...>: grep the tree, prefix each hit with its label.
run() {
  local label=$1; shift
  grep -rEaonH "${excl[@]}" "$@" -- "$DIR" 2>/dev/null \
    | sed "s|^|$label |" >> "$work/hits" || true
}
: > "$work/hits"
run keys -f "$work/keys"
run keys -i -e "$generic"
run paths -f "$work/paths"
run hosts -i -f "$work/hosts"
run lan -e "$lan"
run email -e "$email"

# Filters: shared home, image names like icon@2x.png, allow-lists.
filters=('^paths .*:/Users/Shared$')
filters+=('^email .*@[0-9]x[.][A-Za-z]+$')
filters+=('^email .*[.](png|jpe?g|gif|svg|webp|pdf|js|mjs|css|json|html?|map)$')
if [[ -n ${ALLOW_EMAILS:-} ]]; then
  IFS=',' read -r -a al <<<"$ALLOW_EMAILS"
  for a in "${al[@]}"; do [[ -n $a ]] && filters+=("^email .*:$(re_escape "$a")$"); done
fi
[[ -n ${ALLOW_REGEX:-} ]] && filters+=("$ALLOW_REGEX")
printf '%s\n' "${filters[@]}" > "$work/allow"
# -n puts file:line:match; normalize to "label file:line: match" for reading.
grep -Evf "$work/allow" "$work/hits" | sort -u \
  | sed -E 's/^([a-z]+) ([^:]*):([0-9]+):(.*)$/\1 \2:\3: \4/' > "$work/findings" || true

# Redact key material in the printed report.
sed -E 's/^(keys .*:[0-9]+: .{8}).*/\1.../' "$work/findings" > "$work/report"

status=0
n=$(wc -l < "$work/findings" | tr -d ' ')
if [[ $n -gt 0 ]]; then
  echo "scan-secrets: $n finding(s) in $DIR"
  cat "$work/report"
  status=1
fi

if [[ $GITLEAKS == 1 ]] && command -v gitleaks >/dev/null 2>&1; then
  if gitleaks dir --help >/dev/null 2>&1; then
    gl=(gitleaks dir --no-banner --redact "$DIR")
  else
    gl=(gitleaks detect --no-git --no-banner --redact --source "$DIR")
  fi
  if ! "${gl[@]}"; then
    echo "scan-secrets: gitleaks reported findings"
    status=1
  fi
elif [[ $GITLEAKS == 1 ]]; then
  echo "scan-secrets: gitleaks not installed; built-in patterns only"
fi

[[ $status == 0 ]] && echo "scan-secrets: OK $DIR (no findings)"
exit $status
