#!/usr/bin/env bash
# deploy/sync-test.sh — send the code of the `test` branch to the VM, for deploy-test.sh.
# Run ON THE LAPTOP, VPN on:
#
#   bash deploy/sync-test.sh             # branch test, in both repos
#   bash deploy/sync-test.sh my-branch   # another branch
#
# It sends what is PUSHED to GitHub on that branch (git fetch + git archive), not the files in your
# working folder, so what you test is exactly what will be merged into main. A repo that has no such
# branch sends its main: a change in one repo is tested beside production's version of the other.
#
# Lands in ~/src-test on the VM (each folder replaced whole, with a .deployed-from note of the
# commit), never in ~/src: a production deploy can never pick it up.
set -euo pipefail

BRANCH="${1:-test}"
VM="${VM:-mokanco-vm}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the folder holding both repos

die() { echo "sync-test: $*" >&2; exit 1; }

for repo in MokaCo.HRMS mokaco-web-mantine; do
  dir="$ROOT/$repo"
  [ -d "$dir/.git" ] || die "$dir is not a git checkout (set the repos side by side, as in Mokaco-Project)."
  git -C "$dir" fetch -q origin
  if git -C "$dir" rev-parse -q --verify "origin/$BRANCH^{commit}" >/dev/null; then
    ref="origin/$BRANCH"
  else
    ref="origin/main"
    echo "    $repo has no branch $BRANCH on GitHub: sending its main"
  fi
  commit=$(git -C "$dir" rev-parse --short "$ref")
  echo "==> $repo  $ref ($commit)  ->  $VM:~/src-test/$repo"
  # $repo, $ref and $commit are meant to expand here, on the laptop.
  # shellcheck disable=SC2029
  git -C "$dir" archive --format=tar "$ref" \
    | ssh "$VM" "set -e; mkdir -p ~/src-test; rm -rf ~/src-test/$repo.new; mkdir ~/src-test/$repo.new
                 tar -x -C ~/src-test/$repo.new
                 echo '$ref $commit' > ~/src-test/$repo.new/.deployed-from
                 rm -rf ~/src-test/$repo; mv ~/src-test/$repo.new ~/src-test/$repo"
done

echo
echo "Now on the VM:  bash ~/test-env/deploy-test.sh      (or: ... api / ... web)"
