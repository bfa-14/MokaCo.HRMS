#!/usr/bin/env bash
# deploy/google-gate-emergency-off.sh — turn the Google sign-in gate off without the web app, on the VM.
#
# For when nobody gets past the gate page (Google down, a deleted client ID, the admins' Gmail gone).
# Sets GoogleSignInRequired = '0' in core.SETTING. The API reads it again within 20 seconds, and the
# HRMS then opens with its normal login. nginx keeps its part, which does nothing while the switch is
# off; to remove that too: sudo bash deploy/enable-google-gate.sh --off.
# Refuses when docs/97 is not applied to that database: the API then cannot read its settings and
# keeps the gate closed whatever they say, so only enable-google-gate.sh --off helps.
# Turn it back on from Settings -> Google sign-in (Test Google sign-in first).
#
#   bash deploy/google-gate-emergency-off.sh          # production, MokaCo_HRMS
#   bash deploy/google-gate-emergency-off.sh --test   # the test copy, MokaCo_HRMS_Test
#
# SQL connection: SQLCMDSERVER / SQLCMDUSER / SQLCMDPASSWORD from the environment, as in tests/qa
# (defaults 127.0.0.1 and sa); the password is asked for once when it is not set.
set -euo pipefail

DB=MokaCo_HRMS
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"

die() { echo "google-gate-emergency-off: $*" >&2; exit 1; }

case "${1:-}" in
  "")     ;;
  --test) DB=MokaCo_HRMS_Test ;;
  *)      echo "usage: $0 [--test]" >&2; exit 2 ;;
esac

export SQLCMDSERVER="${SQLCMDSERVER:-127.0.0.1}" SQLCMDUSER="${SQLCMDUSER:-sa}"
if [ -z "${SQLCMDPASSWORD:-}" ]; then
  read -rsp "SQL password for $SQLCMDUSER: " SQLCMDPASSWORD; echo
fi
export SQLCMDPASSWORD

echo "== GoogleSignInRequired = '0' in $DB"
"$SQLCMD" -S "$SQLCMDSERVER" -U "$SQLCMDUSER" -C -I -b -d "$DB" -h -1 -W -Q "
SET NOCOUNT ON;
IF DB_NAME() <> N'$DB' THROW 50000, N'google-gate-emergency-off.sh: not connected to $DB. Nothing changed.', 1;
-- Without 97 the API cannot read its settings and keeps the gate CLOSED: a 0 here would not help.
IF OBJECT_ID(N'security.usp_Gate_GetState', N'P') IS NULL
    THROW 50000, N'google-gate-emergency-off.sh: docs/97_google_signin_gate.sql is not applied to $DB. An API with the gate then cannot read its settings and keeps the gate closed. Apply 97, or take the gate out of nginx: sudo bash deploy/enable-google-gate.sh --off. Nothing changed.', 1;
DECLARE @Was NVARCHAR(200) = (SELECT SettingValue FROM core.SETTING WHERE SettingKey = 'GoogleSignInRequired');
IF @Was IS NULL
BEGIN
    PRINT N'There is no GoogleSignInRequired setting in $DB, which counts as off. Nothing changed.';
    RETURN;
END
UPDATE core.SETTING SET SettingValue = N'0', ModifiedAt = SYSUTCDATETIME(), ModifiedBy = NULL
WHERE SettingKey = 'GoogleSignInRequired';
SELECT CONCAT(N'GoogleSignInRequired in $DB: was ''', @Was, N''', now ''', SettingValue, N''' (', CONVERT(VARCHAR(19), ModifiedAt, 120), N' UTC).')
FROM core.SETTING WHERE SettingKey = 'GoogleSignInRequired';
" || die "sqlcmd stopped (see above)."

echo "The HRMS opens with its normal login within 20 seconds."
echo "Check: curl -s http://127.0.0.1:$([ "$DB" = MokaCo_HRMS ] && echo 5078 || echo 5079)/api/gate/config   (\"required\":false)"
