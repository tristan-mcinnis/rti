#!/bin/sh
# Publish scrub: no personal paths, private hosts, account ids or key material
# in tracked files.
#
# Generic patterns live here. Private tokens (client and colleague names,
# employer domains, email addresses, account ids) belong in .scrub-private
# (gitignored, one extended regex per line, matched without case) so the
# scanner never publishes what it scans for. This file is the one tracked file
# excluded from the scan: review it by hand.
#
# The House integration names (the vault and memory folders, the House server
# alias) are optional features. Exactly one file may name them: the personal
# setup notes. Everything else uses a placeholder such as <vault>.
#
# It lives in scripts/ rather than tests/ because Tests/ is the SwiftPM-style
# test folder name, and macOS file systems treat the two names as one folder.
set -e
cd "$(dirname "$0")/.."

SELF='scripts/scrub.sh'
GENERIC='/Users/tristan|tristan@innerchapter|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ghp_[A-Za-z0-9]{30,}'
HOUSE='~/vault|~/memory|vault-vps'
HOUSE_ALLOWED='^docs/personal-setup\.md$'
PRIVATE=''
if [ -f .scrub-private ]; then
  PRIVATE=$(grep -v -e '^[[:space:]]*$' -e '^#' .scrub-private | paste -sd'|' - || true)
fi

# Positive control: prove each pipeline detects a planted hit.
control=$(mktemp)
printf '/Users/tristan/leak\nssh vault-vps\n' > "$control"
if ! grep -qE "$GENERIC" "$control" || ! grep -qE "$HOUSE" "$control"; then
  echo "SCRUB_SELFTEST_FAILED"; rm -f "$control"; exit 1
fi
rm -f "$control"

tracked() { git ls-files -z | grep -zv "^${SELF}\$"; }

# Spreadsheets are zip files, so grep -I skips them. Scan their text parts too.
xlsx_text() {
  git ls-files -z '*.xlsx' | while IFS= read -r -d '' f; do
    unzip -p "$f" 2>/dev/null | grep -aE "$1" >/dev/null 2>&1 && printf '%s\n' "$f"
  done
}

hits=$( { tracked | xargs -0 grep -IlE "$GENERIC" 2>/dev/null; xlsx_text "$GENERIC"; } || true)
house=$(tracked | grep -zvE "$HOUSE_ALLOWED" | xargs -0 grep -IlE "$HOUSE" 2>/dev/null || true)
private=''
if [ -n "$PRIVATE" ]; then
  private=$( { tracked | xargs -0 grep -IliE "$PRIVATE" 2>/dev/null; } || true)
fi

if [ -n "$hits$house$private" ]; then
  echo "PRIVATE CONTENT FOUND:"
  [ -n "$hits" ] && echo "$hits"
  [ -n "$house" ] && echo "$house"
  [ -n "$private" ] && echo "$private"
  exit 1
fi
echo "SCRUB_CLEAN"
