#!/usr/bin/env bash
# Restore the latest rpi4 off-site snapshot into an x86_64 VM and probe the services.
# usage: run.sh [flake-path]
# env: RESTIC_REPOSITORY, RESTIC_PASSWORD (or RESTIC_PASSWORD_FILE), optional
#      NTFY_URL, DR_KANIDM_USER, FORGEJO_TOKEN, PAPERLESS_TOKEN (live counts to compare)
# needs: restic, jq, curl, nix, /dev/kvm
set -euo pipefail

flake=$(realpath "${1:-.}")
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
ntfy=${NTFY_URL:-https://ntfy.lab/dr-drill}

work=$(mktemp -d "${TMPDIR:-/tmp}/dr-drill.XXXXXX")
# restored dirs keep their 0500/0700 modes
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
report=$work/report.txt
: > "$report"

say() { echo "$*" | tee -a "$report"; }
post() {
  curl -s --max-time 20 -H "Title: $1" -H "Priority: $2" --data-binary "@$report" "$ntfy" > /dev/null || true
}
fail() {
  say "FAIL: $*"
  post "DR drill failed" high
  exit 1
}

say "DR drill $(date -Is) repo=$RESTIC_REPOSITORY"

restic check --read-data-subset=5% > "$work/check.log" 2>&1 || { tail -n 20 "$work/check.log" >> "$report"; fail "restic check"; }
snap=$(restic snapshots --latest 1 --json | jq -r 'last | "\(.short_id) \(.time)"')
[ -n "$snap" ] && [ "$snap" != "null null" ] || fail "no snapshots in repository"
say "snapshot: $snap"

restic restore latest --target "$work/restore" > "$work/restore.log" 2>&1 || { tail -n 20 "$work/restore.log" >> "$report"; fail "restic restore"; }

driver=$(nix build --no-link --print-out-paths --impure -f "$flake/ci/dr-drill" driver --argstr flakePath "$flake") || fail "building VM driver"

vm_ok=0
(
  cd "$work"
  TMPDIR=$work DR_RESTORE_DIR=$work/restore DR_REPORT=$work/vm.json \
    "$driver/bin/nixos-test-driver" > "$work/driver.log" 2>&1
) || vm_ok=1

[ -f "$work/vm.json" ] || { tail -n 30 "$work/driver.log" >> "$report"; fail "VM did not produce a report"; }

jq -r '.probes | to_entries[] | "\(if .value.ok then "ok  " else "FAIL" end) \(.key)"' "$work/vm.json" | tee -a "$report"
jq -r '.counts | to_entries[] | "count \(.key)=\(.value)"' "$work/vm.json" | tee -a "$report"

# a restored service with zero rows while the live Pi has data means the backup is hollow
compare() {
  local name=$1 live=$2 vm
  vm=$(jq -r ".counts.$name // \"null\"" "$work/vm.json")
  say "live $name=$live (vm=$vm)"
  if [ "$live" -gt 0 ] 2> /dev/null && { [ "$vm" = null ] || [ "$vm" -eq 0 ]; }; then
    vm_ok=1
    say "FAIL $name empty after restore"
  fi
}
if [ -n "${FORGEJO_TOKEN:-}" ]; then
  live=$(curl -s -D - -o /dev/null -H "Authorization: token $FORGEJO_TOKEN" 'https://git.lab/api/v1/repos/search?limit=1' | tr -d '\r' | awk -F': ' 'tolower($1)=="x-total-count"{print $2}')
  compare forgejo_repos "${live:-0}"
fi
if [ -n "${PAPERLESS_TOKEN:-}" ]; then
  live=$(curl -s -H "Authorization: Token $PAPERLESS_TOKEN" 'https://docs.lab/api/documents/?page_size=1' | jq -r '.count // 0')
  compare paperless_documents "$live"
fi

if [ "$vm_ok" -ne 0 ]; then
  tail -n 15 "$work/driver.log" >> "$report"
  fail "service probes"
fi
say "PASS"
post "DR drill passed" default
