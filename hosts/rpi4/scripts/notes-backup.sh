#!/usr/bin/env bash
# nightly age-encrypted snapshot of the notes vault, pushed to a private github repo.
# needs: git age zstd tar openssh. env: VAULT, STATE, RECIPIENT, REPO
set -euo pipefail
export GIT_SSH_COMMAND="ssh -i $STATE/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$STATE/known_hosts"
cd "$STATE"
[ -d repo/.git ] || git clone "$REPO" repo
cd repo
git config user.name "rpi4 notes-backup"
git config user.email "notes-backup@rpi4.lab"
git pull -q --rebase || true

day=$(date +%F)
snap="snap-$day.tar.zst.age"
if [ ! -e "$snap" ]; then
  tar -C "$VAULT" --exclude=./.stfolder --exclude=./.stversions --exclude=./.trash -cf - . | zstd -q -19 | age -r "$RECIPIENT" -o "$snap"
fi

# keep 14 dailies and 8 weekly (sunday) snapshots
for f in snap-*.tar.zst.age; do
  d=${f#snap-}; d=${d%.tar.zst.age}
  age_days=$(( ( $(date +%s) - $(date -d "$d" +%s) ) / 86400 ))
  if [ "$age_days" -le 14 ]; then continue; fi
  if [ "$(date -d "$d" +%u)" = 7 ] && [ "$age_days" -le 56 ]; then continue; fi
  git rm -q -f "$f"
done

git add -A
git diff --cached --quiet || git commit -q -m "snapshot $day"
git push -q origin HEAD
echo "ok $snap"
