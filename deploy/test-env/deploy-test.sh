#!/usr/bin/env bash
# deploy/test-env/deploy-test.sh — build what deploy/sync-test.sh sent and put it on the TEST side only.
# Run ON THE VM as yourself (it asks sudo for the installs), after sync-test.sh on the laptop:
#
#   bash ~/test-env/deploy-test.sh         # API and front end
#   bash ~/test-env/deploy-test.sh api     # API only
#   bash ~/test-env/deploy-test.sh web     # front end only
#
# Builds from ~/src-test - never ~/src - into /opt/mokaco/api-test and /var/www/mokaco-web-test, and
# restarts mokaco-api-test. Production's service, folders and database are not touched. A new
# docs/*.sql for the test database goes through apply-sql-test.sh.
#
# When it is right on test: ask for it to be merged into main, then deploy production as usual
# (sync-to-vm.sh, deploy-api.sh, deploy-web.sh).
set -euo pipefail

SRC=$HOME/src-test
APP=/opt/mokaco/api-test
WEB=/var/www/mokaco-web-test
UNIT=mokaco-api-test
RUNAS=mokaco
PORT=5079

log() { printf '==> %s\n' "$*"; }
die() { echo "deploy-test: $*" >&2; exit 1; }
from() { cat "$SRC/$1/.deployed-from" 2>/dev/null || echo "an unknown commit"; }

what="${1:-all}"
case "$what" in all|api|web) ;; *) echo "usage: $0 [api|web]" >&2; exit 2 ;; esac

systemctl cat "$UNIT" >/dev/null 2>&1 || die "$UNIT.service is not installed: run setup-test-api.sh first."

# --- the API ---------------------------------------------------------------------------------------
if [ "$what" != web ]; then
  [ -f "$SRC/MokaCo.HRMS/MokaCo.HRMS.API/MokaCo.HRMS.API.csproj" ] \
    || die "$SRC/MokaCo.HRMS not found: run deploy/sync-test.sh on the laptop first."
  DOTNET=$(command -v dotnet) || die "dotnet is not on PATH."

  log "API from $(from MokaCo.HRMS): publishing"
  PUB=$(mktemp -d)
  { "$DOTNET" publish "$SRC/MokaCo.HRMS/MokaCo.HRMS.API" -c Release -o "$PUB" --nologo -v q 2>&1 || true; } \
    | grep -vE '^\s*$' | tail -n 8 || true
  [ -f "$PUB/MokaCo.HRMS.API.dll" ] || die "publish produced no MokaCo.HRMS.API.dll (errors above). The test API was not touched."

  log "installing to $APP and restarting $UNIT"
  since=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl stop "$UNIT"
  sudo rsync -a --delete "$PUB/" "$APP/"
  rm -rf "$PUB"
  # as deploy-api.sh: owner root, group $RUNAS read-only, nobody else
  sudo chown -R root:"$RUNAS" "$APP"
  sudo chmod 750 "$APP"
  sudo chmod -R g+rX,o-rwx "$APP"
  sudo systemctl start "$UNIT"

  log "waiting for the test API (up to 90 s)"
  health="" ok=0
  for _ in $(seq 1 45); do
    sleep 2
    [ -n "$health" ] || health=$(curl -s -m 3 "http://127.0.0.1:$PORT/health" || true)
    journal=$(sudo journalctl -u "$UNIT" --since "$since" --no-pager -o cat 2>/dev/null || true)
    if [ -n "$health" ] && grep -q 'Notifications are OFF' <<< "$journal" && grep -q 'Machine pull is OFF' <<< "$journal"; then
      ok=1
      break
    fi
  done
  if [ $ok -ne 1 ] || ! grep -q 'Staging' <<< "$health"; then
    sudo systemctl stop "$UNIT" || true
    sudo journalctl -u "$UNIT" --since "$since" --no-pager -o cat | tail -n 40 >&2 || true
    die "the new test API did not come up as expected (log above); it has been stopped. /health said: ${health:-nothing}"
  fi
  echo "    $health"
fi

# --- the front end ----------------------------------------------------------------------------------
if [ "$what" != api ]; then
  [ -f "$SRC/mokaco-web-mantine/package.json" ] \
    || die "$SRC/mokaco-web-mantine not found: run deploy/sync-test.sh on the laptop first."
  command -v node >/dev/null || die "node is not installed on this VM."

  log "front end from $(from mokaco-web-mantine): building"
  cd "$SRC/mokaco-web-mantine"
  npm ci --no-audit --no-fund 2>&1 | tail -n 3
  rm -rf dist
  # empty on purpose, as in deploy-web.sh: the app calls a relative /api on its own address
  VITE_API_BASE_URL='' npm run build 2>&1 | tail -n 15
  [ -f dist/index.html ] || die "the build produced no dist/index.html (errors above). The test front end was not touched."
  # a test front end without the switch would leave everyone who opens it stuck in test
  grep -rqF '/env/prod' dist/assets \
    || die "this build has no Test environment switch; on test it would leave no way back. Nothing published."

  log "publishing to $WEB"
  NEW="$WEB.new" OLD="$WEB.old"
  sudo rm -rf "$NEW" "$OLD"
  sudo cp -a dist "$NEW"
  sudo chown -R www-data:www-data "$NEW"
  if [ -d "$WEB" ]; then sudo mv "$WEB" "$OLD"; fi
  sudo mv "$NEW" "$WEB"
  sudo rm -rf "$OLD"
fi

echo
echo "Test side updated. Open https://hrms.mokanco.com.lb/login with the Test environment switch on."
