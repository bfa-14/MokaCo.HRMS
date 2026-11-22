#!/usr/bin/env bash
# deploy/check-mail.sh - why did a booking e-mail go out, or not? READ-ONLY: it changes nothing.
# Run ON THE VM as yourself, from whichever copy of the code is there:
#
#   bash ~/src-test/MokaCo.HRMS/deploy/check-mail.sh          # the live database
#   bash ~/src-test/MokaCo.HRMS/deploy/check-mail.sh test     # the test database
#
# It asks for the SQL password (hidden, never stored; refused: stop and ask Reda) and prints the two mail accounts
# as HRMS reads them, the switches, what happened to the last booking messages with the mail server's own answer,
# and a verdict in plain words (deploy/check-mail.sql). No password, login or guest address is printed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
SERVER="${SQLCMDSERVER:-127.0.0.1}"
SQLUSER="${SQLCMDUSER:-sa}"

case "${1:-prod}" in
  prod) DB=MokaCo_HRMS;      UNIT=mokaco-api ;;
  test) DB=MokaCo_HRMS_Test; UNIT=mokaco-api-test ;;
  *) echo "usage: bash $0 [prod | test]" >&2; exit 2 ;;
esac

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
[[ -f "$HERE/check-mail.sql" ]] || die "$HERE/check-mail.sql is missing: run fetch-code.sh first."
[[ -x "$SQLCMD" ]] || die "$SQLCMD not found."

if [[ -z "${SQLCMDPASSWORD:-}" ]]; then
  read -rsp "SQL password for $SQLUSER: " SQLCMDPASSWORD; echo
fi
export SQLCMDPASSWORD
trap 'unset SQLCMDPASSWORD' EXIT
"$SQLCMD" -S "$SERVER" -U "$SQLUSER" -C -b -Q "SET NOCOUNT ON; SELECT 1;" >/dev/null 2>&1 \
  || die "SQL Server refused the password for $SQLUSER (or is not running). Stop here and ask Reda; do not retry."

"$SQLCMD" -S "$SERVER" -U "$SQLUSER" -C -I -b -d "$DB" -i "$HERE/check-mail.sql" \
  || die "the check failed (above). Nothing was changed."

# What the API itself last said about its mail worker (no addresses: only the ON/OFF line and the failure count).
if command -v journalctl >/dev/null 2>&1; then
  echo
  echo "== The API's mail worker ($UNIT)"
  state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
  echo "service: ${state:-unknown}"
  said=$(journalctl -u "$UNIT" --since "-24 hours" --no-pager -o cat 2>/dev/null | grep -E "Notifications are (ON|OFF)" | tail -n 1 || true)
  echo "it last said: ${said:-(nothing in the last 24 hours; that line is written when the API starts or the settings change)}"
fi
