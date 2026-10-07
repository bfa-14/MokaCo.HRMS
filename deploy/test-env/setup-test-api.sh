#!/usr/bin/env bash
# deploy/test-env/setup-test-api.sh — the test API on this VM in one run (README steps 2, 4, 5, 6).
#
#   sudo ~/test-env/setup-test-api.sh
#   sudo MPGS_TEST_PASSWORD='...' ~/test-env/setup-test-api.sh    # with the TESTMOKANDCO password
#
# Needs MokaCo_HRMS_Test (refresh-test-db.sh first). It
#   1. creates the SQL login mokaco_api_test with a generated password - it can open MokaCo_HRMS_Test
#      only - and maps it there (refresh-test-db.sh --in-place, which also re-neutralises the copy);
#   2. copies production's API build to /opt/mokaco/api-test and its front end to
#      /var/www/mokaco-web-test;
#   3. writes /etc/mokaco/api-test.env (root, 0600) ONCE: port 5079, the test database and login, its
#      own JWT key, TESTMOKANDCO. Later runs keep it, and the login's password with it;
#   4. installs mokaco-api-test.service with production's ExecStart pointed at the test folder;
#   5. starts it, and stops it again unless /health answers Staging and the log says that mail and
#      the machine pull are OFF.
# Production's service, files and settings are only read, never changed. Safe to re-run: it refreshes
# the test copy of the build and front end and restarts the test API.
#
# Without MPGS_TEST_PASSWORD the API still starts; card payments just fail on test.
set -euo pipefail

TEST_DB=MokaCo_HRMS_Test
LOGIN=mokaco_api_test
PROD_UNIT=mokaco-api
UNIT=mokaco-api-test
PROD_APP=/opt/mokaco/api
APP=/opt/mokaco/api-test
DATA=/var/lib/mokaco-test
PROD_WEB=/var/www/mokaco-web
WEB=/var/www/mokaco-web-test
ENVF=/etc/mokaco/api-test.env
RUNAS=mokaco
PROD_PORT=5078
PORT=5079
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { echo "setup-test-api: $*" >&2; exit 1; }
sql() { "$SQLCMD" -S "$SQLCMDSERVER" -U "$SQLCMDUSER" -C -I -b "$@"; }
# Replaces literal text (no regex, no & or \ surprises - the values are passwords).
fill() { awk -v from="$1" -v to_var="$2" '
  { s = $0; out = ""
    while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) ENVIRON[to_var]; s = substr(s, i + length(from)) }
    print out s }'; }

# --- what has to be there first ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run it with sudo."
for f in api-test.env.example mokaco-api-test.service refresh-test-db.sh neutralise-test-db.sql; do
  [ -f "$HERE/$f" ] || die "$HERE/$f missing: run it from the copied test-env folder."
done
[ -d "$PROD_APP" ] || die "$PROD_APP not found."
[ -f "$PROD_WEB/index.html" ] || die "$PROD_WEB/index.html not found."
prod_exec=$(systemctl cat "$PROD_UNIT" 2>/dev/null | grep -E '^ExecStart=.' | tail -n 1 || true)
[ -n "$prod_exec" ] || die "could not read ExecStart from $PROD_UNIT.service."
exec_line=${prod_exec//$PROD_APP\//$APP\/}
exec_line=${exec_line//:$PROD_PORT/:$PORT}
[[ "$exec_line" == *"$APP/"* ]] || die "production's ExecStart does not run from $PROD_APP/ ($prod_exec); set the test unit by hand."

export SQLCMDSERVER="${SQLCMDSERVER:-127.0.0.1}" SQLCMDUSER="${SQLCMDUSER:-sa}"
if [ -z "${SQLCMDPASSWORD:-}" ]; then
  read -rsp "SQL password for $SQLCMDUSER: " SQLCMDPASSWORD; echo
fi
export SQLCMDPASSWORD

[ "$(sql -h -1 -W -d master -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$TEST_DB') IS NULL THEN 0 ELSE 1 END;")" = "1" ] \
  || die "$TEST_DB does not exist: run refresh-test-db.sh first."

tmp=$(mktemp)
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT

# --- 1. the SQL login -----------------------------------------------------------------------------
new_pw=""
if [ -f "$ENVF" ]; then
  log "keeping $ENVF, and the login's password with it"
else
  # upper, lower and digits for CHECK_POLICY; letters and digits only, so it is safe in the
  # connection string. Written to a 0600 file, never on a command line.
  new_pw="Mk$(openssl rand -hex 6)x$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)7"
  cat > "$tmp" <<EOF
IF SUSER_ID(N'$LOGIN') IS NULL
    CREATE LOGIN [$LOGIN] WITH PASSWORD = N'$new_pw', CHECK_POLICY = ON, DEFAULT_DATABASE = [$TEST_DB];
ELSE
    ALTER LOGIN [$LOGIN] WITH PASSWORD = N'$new_pw';
EOF
  log "SQL login $LOGIN (a new password, kept only in $ENVF)"
  sql -d master -i "$tmp"
  : > "$tmp"
fi

log "mapping $LOGIN in $TEST_DB, and neutralising the copy again"
"$HERE/refresh-test-db.sh" --in-place

# --- 2. the build and the front end -----------------------------------------------------------------
systemctl stop "$UNIT" 2>/dev/null || true
log "copying production's API build to $APP and front end to $WEB"
mkdir -p "$APP" "$WEB"
rsync -a --delete "$PROD_APP/" "$APP/"
rsync -a --delete "$PROD_WEB/" "$WEB/"
install -d -o "$RUNAS" -g "$RUNAS" -m 750 "$DATA" "$DATA/documents"

# --- 3. the settings, once ------------------------------------------------------------------------
if [ -n "$new_pw" ]; then
  log "writing $ENVF (root-only)"
  export SETUP_PW="$new_pw" SETUP_MPGS="${MPGS_TEST_PASSWORD:-not-set}"
  SETUP_JWT=$(openssl rand -base64 48 | tr -d '\n'); export SETUP_JWT
  fill '<password from step 2>' SETUP_PW < "$HERE/api-test.env.example" \
    | fill '<openssl rand -base64 48>' SETUP_JWT \
    | fill '<TESTMOKANDCO API password>' SETUP_MPGS > "$tmp"
  install -o root -g root -m 600 "$tmp" "$ENVF"
  : > "$tmp"
  unset SETUP_PW SETUP_JWT SETUP_MPGS new_pw
fi
grep -q "Database=$TEST_DB;User Id=$LOGIN;" "$ENVF" || die "$ENVF does not point at $TEST_DB as $LOGIN. Fix it, then run this again."
grep -q 'MPGS_MERCHANT_ID=TEST' "$ENVF" || die "$ENVF must use a TEST merchant profile (MPGS_MERCHANT_ID=TEST...)."
! grep -qE '=<' "$ENVF" || die "$ENVF still has a <placeholder>; fill it in, then run this again."

# --- 4. the unit ----------------------------------------------------------------------------------------
log "installing $UNIT.service (${exec_line#ExecStart=})"
awk -v line="$exec_line" '/^ExecStart=/ { print line; next } { print }' "$HERE/mokaco-api-test.service" > "$tmp"
install -m 644 "$tmp" "/etc/systemd/system/$UNIT.service"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1

# --- 5. start, and check before trusting it ------------------------------------------------------------
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl start "$UNIT"
log "waiting for the test API to answer and report mail and the machine pull OFF (up to 90 s)"
health="" ok=0
for _ in $(seq 1 45); do
  sleep 2
  [ -n "$health" ] || health=$(curl -s -m 3 "http://127.0.0.1:$PORT/health" || true)
  journal=$(journalctl -u "$UNIT" --since "$since" --no-pager -o cat 2>/dev/null || true)
  if [ -n "$health" ] && grep -q 'Notifications are OFF' <<< "$journal" && grep -q 'Machine pull is OFF' <<< "$journal"; then
    ok=1
    break
  fi
done

if [ $ok -ne 1 ] || ! grep -q 'Staging' <<< "$health"; then
  systemctl stop "$UNIT" || true
  journalctl -u "$UNIT" --since "$since" --no-pager -o cat | tail -n 40 >&2 || true
  die "the test API did not come up as expected (log above); it has been stopped. /health said: ${health:-nothing}"
fi

echo
echo "Test API is running: $health"
echo "Next: sudo $HERE/enable-env-switch.sh   (the login page's switch)"
