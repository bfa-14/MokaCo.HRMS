#!/usr/bin/env bash
# deploy/sync-prod.sh — send `main` (production) to the VM, for deploy-api.sh and deploy-web.sh.
# Run ON THE LAPTOP, VPN on:
#
#   bash deploy/sync-prod.sh
#
# Always sends what is PUSHED on main (git fetch + git archive), whatever branch your working folder
# has checked out: being on dev while deploying can no longer put untested code in production.
# Replaces ~/src/MokaCo.HRMS and ~/src/mokaco-web-mantine on the VM whole (with a .deployed-from note
# of the commit); anything else in ~/src is left alone.
set -euo pipefail

VM="${VM:-mokanco-vm}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the folder holding both repos

die() { echo "sync-prod: $*" >&2; exit 1; }

for repo in MokaCo.HRMS mokaco-web-mantine; do
  dir="$ROOT/$repo"
  [ -d "$dir/.git" ] || die "$dir is not a git checkout (set the repos side by side, as in Mokaco-Project)."
  git -C "$dir" fetch -q origin
  commit=$(git -C "$dir" rev-parse --short origin/main)
  echo "==> $repo  origin/main ($commit)  ->  $VM:~/src/$repo"
  # $repo and $commit are meant to expand here, on the laptop.
  # shellcheck disable=SC2029
  git -C "$dir" archive --format=tar origin/main \
    | ssh "$VM" "set -e; mkdir -p ~/src; rm -rf ~/src/$repo.new; mkdir ~/src/$repo.new
                 tar -x -C ~/src/$repo.new
                 echo 'origin/main $commit' > ~/src/$repo.new/.deployed-from
                 rm -rf ~/src/$repo; mv ~/src/$repo.new ~/src/$repo"
done

echo
echo "Now on the VM:  bash ~/deploy-api.sh   and/or   bash ~/deploy-web.sh"
