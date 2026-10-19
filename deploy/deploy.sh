#!/usr/bin/env bash
# deploy/deploy.sh — one click: deploy according to the branch you are on. Run ON THE LAPTOP, VPN on;
# VS Code runs it as the task "Deploy (dev → test, main → production)" (Ctrl+Shift+B).
#
#   on dev   -> TEST:        sync-test.sh, then deploy-test.sh on the VM (test API + test front end)
#   on main  -> PRODUCTION:  asks you to type "yes", then sync-prod.sh, deploy-api.sh, deploy-web.sh
#   anything else -> refuses
#
#   bash deploy/deploy.sh         # API and front end
#   bash deploy/deploy.sh api     # API only
#   bash deploy/deploy.sh web     # front end only
#
# The branch is read from the repo it is run in (the folder open in VS Code). What gets deployed is
# what is PUSHED on that branch, in both repos - so it stops first if either repo has commits on that
# branch that are not pushed, or this repo has changes not committed: they would silently be left out.
# The VM runs the deploy scripts from the code it was just sent, so they are always this branch's.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # the folder holding both repos
VM="${VM:-mokanco-vm}"

die() { echo "deploy: $*" >&2; exit 1; }

what="${1:-all}"
case "$what" in all|api|web) ;; *) echo "usage: $0 [api|web]" >&2; exit 2 ;; esac

repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "run it inside MokaCo.HRMS or mokaco-web-mantine."
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
case "$branch" in
  dev)  side="TEST" ;;
  main) side="PRODUCTION" ;;
  *)    die "you are on '$branch'. Switch to dev (test) or main (production) to deploy." ;;
esac

# --- nothing left out: everything on $branch is committed and pushed ----------------------------------
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
  die "$(basename "$repo") has changes that are not committed. Commit and push them (or stash them) first."
fi
for r in MokaCo.HRMS mokaco-web-mantine; do
  dir="$ROOT/$r"
  [ -d "$dir/.git" ] || die "$dir not found (both repos must sit side by side)."
  git -C "$dir" fetch -q origin
  if git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
     && git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    ahead=$(git -C "$dir" rev-list --count "origin/$branch..$branch")
    [ "$ahead" -eq 0 ] || die "$r has $ahead commit(s) on $branch that are not pushed. git push first."
  fi
done

echo "==> $side deploy ($what) from branch $branch"

if [ "$side" = "TEST" ]; then
  bash "$HERE/sync-test.sh" dev
  arg=""; [ "$what" = all ] || arg="$what"
  ssh -t "$VM" "bash ~/src-test/MokaCo.HRMS/deploy/test-env/deploy-test.sh $arg"
  exit 0
fi

read -rp "Deploy main to PRODUCTION, where people are working? Type yes: " answer
[ "$answer" = "yes" ] || die "cancelled. Nothing was sent."
bash "$HERE/sync-prod.sh"
case "$what" in
  api) remote='bash ~/src/MokaCo.HRMS/deploy/deploy-api.sh' ;;
  web) remote='bash ~/src/MokaCo.HRMS/deploy/deploy-web.sh' ;;
  all) remote='bash ~/src/MokaCo.HRMS/deploy/deploy-api.sh && bash ~/src/MokaCo.HRMS/deploy/deploy-web.sh' ;;
esac
ssh -t "$VM" "$remote"
