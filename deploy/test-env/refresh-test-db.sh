#!/usr/bin/env bash
# deploy/test-env/refresh-test-db.sh — rebuild MokaCo_HRMS_Test from a production backup and make it
# safe in the same run, so there is never a moment when the test API could start on raw production
# settings.
#
#   sudo deploy/test-env/refresh-test-db.sh                  # newest /var/opt/mssql/backup/MokaCo_HRMS_<date>.bak
#   sudo deploy/test-env/refresh-test-db.sh /path/to/x.bak   # a given backup (SQL Server must be able to read it)
#        deploy/test-env/refresh-test-db.sh --in-place       # no restore: steps 3 and 4 on the database as it is
#
# 1. stops mokaco-api-test;
# 2. restores the backup OVER MokaCo_HRMS_Test. Each file goes where the test database already keeps
#    it, or to /var/opt/mssql/data/MokaCo_HRMS_Test*.mdf/.ldf the first time; the run stops before
#    touching anything if a target file belongs to another database;
# 3. runs neutralise-test-db.sql (no mail, no WhatsApp, no terminals, no website bookings);
# 4. gives the mokaco_api_test login db_owner in the copy (README step 2 creates the login).
# It does NOT start the test API. The only database it restores, alters or opens is MokaCo_HRMS_Test.
#
# SQL connection: SQLCMDSERVER / SQLCMDUSER / SQLCMDPASSWORD from the environment, as in tests/qa
# (defaults 127.0.0.1 and sa; sudo drops them, so the password is usually asked for). RESTORE needs sa.
set -euo pipefail

TEST_DB=MokaCo_HRMS_Test
TEST_LOGIN=mokaco_api_test
TEST_UNIT=mokaco-api-test
BACKUP_DIR=/var/opt/mssql/backup
DATA_DIR=/var/opt/mssql/data
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "refresh-test-db: $*" >&2; exit 1; }
q() { printf '%s' "${1//\'/\'\'}"; }   # a value inside N'...'
sql() { "$SQLCMD" -S "$SQLCMDSERVER" -U "$SQLCMDUSER" -C -I -b "$@"; }
rows() { sql -h -1 -W -s '|' -d master -Q "SET NOCOUNT ON; $1"; }

in_place=0
backup=""
case "${1:-}" in
  --in-place) in_place=1 ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  *) backup="${1:-}" ;;
esac

if [ $in_place -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "run it with sudo: it stops $TEST_UNIT and lists $BACKUP_DIR."
  if [ -z "$backup" ]; then
    # [0-9]: production's dated backups only, never a MokaCo_HRMS_Test_... file. Plain dated
    # names, so ls -t is safe here.
    # shellcheck disable=SC2012
    backup="$(ls -1t "$BACKUP_DIR"/MokaCo_HRMS_[0-9]*.bak 2>/dev/null | head -n 1 || true)"
  fi
  [ -n "$backup" ] && [ -f "$backup" ] || die "no backup found (looked for ${1:-$BACKUP_DIR/MokaCo_HRMS_<date>.bak})."
fi

export SQLCMDSERVER="${SQLCMDSERVER:-127.0.0.1}" SQLCMDUSER="${SQLCMDUSER:-sa}"
if [ -z "${SQLCMDPASSWORD:-}" ]; then
  read -rsp "SQL password for $SQLCMDUSER: " SQLCMDPASSWORD; echo
fi
export SQLCMDPASSWORD

if [ $in_place -eq 1 ]; then
  [ "$(rows "SELECT CASE WHEN DB_ID(N'$TEST_DB') IS NULL THEN 0 ELSE 1 END;")" = "1" ] \
    || die "$TEST_DB does not exist; run without --in-place to restore it from a backup."
else
  # --- Where each file of the backup goes -----------------------------------------------------
  existing="$(rows "SELECT name, physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$TEST_DB');")"
  others="$(rows "SELECT physical_name FROM sys.master_files WHERE database_id <> ISNULL(DB_ID(N'$TEST_DB'), 0);")"
  filelist="$(rows "RESTORE FILELISTONLY FROM DISK = N'$(q "$backup")';")"

  moves=()
  data=0
  logs=0
  while IFS='|' read -r logical _physical type _rest; do
    [ -n "$logical" ] || continue
    target="$(awk -F'|' -v n="$logical" '$1 == n { print $2; exit }' <<< "$existing")"
    if [ -z "$target" ]; then
      case "$type" in
        D) data=$((data + 1)); target="$DATA_DIR/$TEST_DB$([ $data -eq 1 ] && echo .mdf || echo "_$data.ndf")" ;;
        L) logs=$((logs + 1)); target="$DATA_DIR/${TEST_DB}_log$([ $logs -eq 1 ] || echo "_$logs").ldf" ;;
        *) die "file $logical has type '$type'; this script handles data and log files only." ;;
      esac
    fi
    if grep -qixF -- "$target" <<< "$others"; then
      die "$target belongs to another database. Nothing was changed."
    fi
    moves+=("MOVE N'$(q "$logical")' TO N'$(q "$target")'")
  done <<< "$filelist"
  [ ${#moves[@]} -gt 0 ] || die "could not read the file list of $backup."

  echo "Backup:  $backup"
  printf '  %s\n' "${moves[@]}"
  read -rp "Replace $TEST_DB with this backup? Everything in $TEST_DB is lost. [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "cancelled. Nothing was changed."

  # --- 1. Stop the test API -------------------------------------------------------------------
  if systemctl is-active --quiet "$TEST_UNIT"; then
    systemctl stop "$TEST_UNIT"
    echo "Stopped $TEST_UNIT."
  fi

  # --- 2. Restore -------------------------------------------------------------------------------
  # OFFLINE rather than SINGLE_USER: nothing can slip into an offline database between the ALTER
  # and the RESTORE, and RESTORE ... REPLACE overwrites an offline database as it is.
  moves_sql="$(IFS=,; echo "${moves[*]}")"
  sql -d master -Q "IF DB_ID(N'$TEST_DB') IS NOT NULL ALTER DATABASE [$TEST_DB] SET OFFLINE WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$TEST_DB] FROM DISK = N'$(q "$backup")' WITH $moves_sql, REPLACE, RECOVERY, STATS = 25;" \
    || die "the restore failed; $TEST_DB may be left offline or restoring. Fix the cause above and run this script again."
fi

# --- 3. Neutralise ---------------------------------------------------------------------------------
sql -W -d "$TEST_DB" -i "$HERE/neutralise-test-db.sql"

# --- 4. The test API's own login --------------------------------------------------------------------
sql -d "$TEST_DB" -Q "IF SUSER_ID(N'$TEST_LOGIN') IS NULL
    PRINT N'Login $TEST_LOGIN does not exist yet: create it (README step 2), then run this script again.';
ELSE
BEGIN
    IF USER_ID(N'$TEST_LOGIN') IS NULL CREATE USER [$TEST_LOGIN] FOR LOGIN [$TEST_LOGIN];
    ELSE ALTER USER [$TEST_LOGIN] WITH LOGIN = [$TEST_LOGIN];   -- re-map if the login was re-created
    ALTER ROLE db_owner ADD MEMBER [$TEST_LOGIN];
    PRINT N'$TEST_LOGIN is db_owner in $TEST_DB.';
END"

if [ $in_place -eq 1 ]; then
  echo "Done. $TEST_DB is neutralised in place."
else
  echo "Done. $TEST_DB is a neutralised copy of $(basename "$backup")."
fi
echo "Start the test API with: sudo systemctl start $TEST_UNIT"
