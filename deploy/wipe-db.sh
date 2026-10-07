#!/usr/bin/env bash
#
# Run ON THE VM. Empties a MokaCo HRMS database, keeping configuration and ONE login.
# Uses ~/wipe_all_data_keep_owner.sql (the procedure dbo.usp_Admin_WipeAllData).
#
#   bash ~/wipe-db.sh rehearse hadi.owner   1. SAFE: restores the newest backup into a throwaway
#                                              database MokaCo_HRMS_WipeTest, wipes THAT, shows the
#                                              result, then drops it. Production is not touched.
#   bash ~/wipe-db.sh report   hadi.owner   2. SAFE: on production, shows what WOULD be deleted/kept.
#   bash ~/wipe-db.sh execute  hadi.owner   3. REAL: fresh backup of production, stops the API,
#                                              wipes production, starts the API again.
#
# MokaCo_HRMS_Test (your test copy) is never touched by any mode.
#
set -uo pipefail
MODE=${1:-}; OWNER=${2:-}
PROD=MokaCo_HRMS
SCRATCH=MokaCo_HRMS_WipeTest
PROC_SQL=~/wipe_all_data_keep_owner.sql
BK=/var/opt/mssql/backup
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; unset SQLCMDPASSWORD; exit 1; }

[[ "$MODE" =~ ^(rehearse|report|execute)$ && -n "$OWNER" ]] || die "usage: bash ~/wipe-db.sh rehearse|report|execute <owner-username>"
[[ -f $PROC_SQL ]] || die "$PROC_SQL missing - copy it to the VM first"
read -rsp "sa password: " SQLCMDPASSWORD; echo; export SQLCMDPASSWORD
# -I = QUOTED_IDENTIFIER ON (needed for DML on tables with filtered indexes)
sql() { "$SQLCMD" -S 127.0.0.1 -U sa -C -I -b "$@"; }
sql -Q "SELECT 1" -h -1 >/dev/null || die "cannot log in as sa"
OWNER_SQL=${OWNER//\'/\'\'}

install_proc() { log "installing dbo.usp_Admin_WipeAllData in $1"; sql -d "$1" -i "$PROC_SQL" || die "install failed"; }
report()  { log "REPORT on $1 (nothing changes)"; sql -d "$1" -W -s ' | ' -Q "EXEC dbo.usp_Admin_WipeAllData @KeepUsername = N'$OWNER_SQL'"; }
execute() { log "EXECUTE on $1"; sql -d "$1" -W -s ' | ' -Q "EXEC dbo.usp_Admin_WipeAllData @KeepUsername = N'$OWNER_SQL', @ConfirmDatabase = N'$1', @Confirm = N'WIPE ALL DATA', @Execute = 1"; }
counts()  { sql -d "$1" -h -1 -W -Q "SET NOCOUNT ON;
  SELECT CONCAT('$1: users=', (SELECT COUNT(*) FROM security.[USER]),
                '  employees=', (SELECT COUNT(*) FROM hr.EMPLOYEE),
                '  requests=', (SELECT COUNT(*) FROM workflow.REQUEST_INSTANCE),
                '  attendance=', (SELECT COUNT(*) FROM attendance.ATTENDANCE_RECORD),
                '  roles=', (SELECT COUNT(*) FROM security.[ROLE]),
                '  permissions=', (SELECT COUNT(*) FROM security.PERMISSION),
                '  branches=', (SELECT COUNT(*) FROM hr.BRANCH),
                '  settings=', (SELECT COUNT(*) FROM core.SETTING))"; }
drop_proc() { sql -d "$1" -Q "DROP PROCEDURE IF EXISTS dbo.usp_Admin_WipeAllData" >/dev/null; }

case $MODE in
# -----------------------------------------------------------------------------------------
rehearse)
  # newest backup of production; find runs under sudo because the mssql folder is not readable by 'user'
  BAK=$(sudo find $BK -maxdepth 1 -name "${PROD}_*.bak" -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
  [[ -n "$BAK" ]] || die "no backup of $PROD found in $BK"
  log "restoring $BAK into throwaway $SCRATCH"
  sql -Q "IF DB_ID('$SCRATCH') IS NOT NULL BEGIN ALTER DATABASE [$SCRATCH] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$SCRATCH]; END" || die "could not drop old $SCRATCH"
  MOVES=$(sql -h -1 -W -s '|' -Q "RESTORE FILELISTONLY FROM DISK='$BAK'" | awk -F'|' -v q="'" -v d=/var/opt/mssql/data -v n="$SCRATCH" '
    $3=="D"{printf "MOVE N%s%s%s TO N%s%s/%s__%s.mdf%s, ", q,$1,q, q,d,n,$1,q}
    $3=="L"{printf "MOVE N%s%s%s TO N%s%s/%s__%s.ldf%s, ", q,$1,q, q,d,n,$1,q}')
  sql -Q "RESTORE DATABASE [$SCRATCH] FROM DISK='$BAK' WITH $MOVES RECOVERY" >/dev/null || die "restore failed"
  echo "before: $(counts $SCRATCH)"
  install_proc $SCRATCH
  report $SCRATCH
  execute $SCRATCH; rc=$?
  echo; echo "after:  $(counts $SCRATCH)"
  log "dropping throwaway $SCRATCH"
  sql -Q "ALTER DATABASE [$SCRATCH] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$SCRATCH];" >/dev/null
  [[ $rc == 0 ]] && echo "REHEARSAL OK - production untouched. Next: bash ~/wipe-db.sh report $OWNER" \
                 || echo "REHEARSAL FAILED (see the error above) - production untouched."
  ;;
# -----------------------------------------------------------------------------------------
report)
  install_proc $PROD
  report $PROD
  drop_proc $PROD
  echo "Report only - nothing changed."
  ;;
# -----------------------------------------------------------------------------------------
execute)
  echo
  echo "This DELETES all data in $PROD except configuration and the login '$OWNER'."
  read -rp "Type the database name ($PROD) to continue: " ans
  [[ "$ans" == "$PROD" ]] || die "cancelled - nothing changed"

  F=$BK/${PROD}_before_wipe_$(date -u +%Y%m%d_%H%M).bak
  log "safety backup -> $F"
  sql -Q "BACKUP DATABASE [$PROD] TO DISK='$F' WITH INIT, COPY_ONLY, CHECKSUM" >/dev/null || die "backup failed - nothing changed"
  sql -Q "RESTORE VERIFYONLY FROM DISK='$F' WITH CHECKSUM" >/dev/null || die "backup did not verify - nothing changed"
  echo "    backup verified"

  log "stopping the API (so nothing writes during the wipe)"
  sudo systemctl stop mokaco-api
  install_proc $PROD
  execute $PROD; rc=$?
  drop_proc $PROD                         # do not leave a wipe button lying around
  log "starting the API"
  sudo systemctl start mokaco-api; sleep 6
  echo "    API: $(systemctl is-active mokaco-api)  $(curl -sk -m 5 https://127.0.0.1/health -H 'Host: 82.146.175.34')"
  echo "after: $(counts $PROD)"
  if [[ $rc == 0 ]]; then
    echo "DONE. Log in as '$OWNER'. To undo: restore $F."
    echo "Old uploaded files are still in /var/lib/mokaco/documents - move them aside:"
    echo "  sudo mv /var/lib/mokaco/documents /var/lib/mokaco/documents.before_wipe && sudo install -d -o mokaco -g mokaco /var/lib/mokaco/documents"
  else
    echo "FAILED and ROLLED BACK - production is unchanged (backup also at $F)."
  fi
  ;;
esac
unset SQLCMDPASSWORD
