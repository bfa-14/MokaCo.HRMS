#!/usr/bin/env bash
# deploy/test-env/update-test.sh - bring the TEST side up to the code in ~/src-test, in one command.
# The test-side sibling of deploy/update-prod.sh. Run ON THE VM as yourself:
#
#   bash ~/src-test/MokaCo.HRMS/deploy/test-env/update-test.sh           # missing scripts, then API + front end
#   bash ~/src-test/MokaCo.HRMS/deploy/test-env/update-test.sh --fresh   # FIRST a fresh copy of the live database, then the same
#   bash ~/src-test/MokaCo.HRMS/deploy/test-env/update-test.sh --check   # only says what is missing; changes nothing
#
# WHY IT EXISTS. deploy-test.sh stops the test API when the test database lacks a script the new code calls -
# rightly, but that leaves the test login answering "502" until somebody works out WHICH scripts, in which order.
# This does the working out: it asks the test database itself (deploy/check-scripts.sql) and applies exactly what is
# missing, in number order, through apply-sql-test.sh (which can only ever touch MokaCo_HRMS_Test), then deploys.
#
# What it does, in order, and it stops at the first thing that goes wrong:
#   1. the SQL password, asked once (hidden, never stored). Refused: it stops; ask Reda, do not retry.
#   --fresh only: a backup of the live database taken NOW (COPY_ONLY: it changes nothing in production), restored
#      OVER MokaCo_HRMS_Test by refresh-test-db.sh - which asks before replacing, and makes the copy safe in the same
#      run (no mail, no WhatsApp, no terminals, no website bookings). Everything that was in the test database is
#      replaced. The backup file is removed afterwards.
#   2. which numbered docs/ scripts MokaCo_HRMS_Test lacks (read-only).
#   3. those scripts, in number order, on the TEST database only.
#   4. deploy-test.sh: the test API and the test front end (refresh-test-db.sh leaves the test API stopped; this
#      is what starts it again).
# Production is only ever READ, and only by --fresh (the backup): its data, its service and its folders are never
# changed. Everything printed is also kept in ~/test-update-<date>.log; when it stops, the reason is in the last
# lines on the screen.
set -euo pipefail

SRC="${SRC:-$HOME/src-test/MokaCo.HRMS}"
HERE="$SRC/deploy/test-env"
DB=MokaCo_HRMS_Test
PROD_DB="${PROD_DB:-MokaCo_HRMS}"
BACKUP_DIR="${BACKUP_DIR:-/var/opt/mssql/backup}"
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
SERVER="${SQLCMDSERVER:-127.0.0.1}"
SQLUSER="${SQLCMDUSER:-sa}"
STAMP=$(date +%Y%m%d-%H%M)
LOG="$HOME/test-update-$STAMP.log"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

sql() { "$SQLCMD" -S "$SERVER" -U "$SQLUSER" -C -b "$@"; }

# Runs deploy/check-scripts.sql against the TEST database (read-only). Sets MISSING: "none", or the files in apply order.
check_scripts() {
  local out
  out=$(sql -d "$DB" -i "$SRC/deploy/check-scripts.sql" 2>&1) || { echo "$out"; die "deploy/check-scripts.sql failed (above)"; }
  # The script names the database it ran in: anything but the test database stops everything here.
  grep -q "^Database: $DB\." <<< "$out" || { echo "$out" | tail -n 5; die "the check did not run in $DB. Nothing was changed."; }
  MISSING=$(sed -n 's/^Missing, in apply order: //p' <<< "$out")
  [[ -n "$MISSING" ]] || { echo "$out"; die "could not read the list of missing scripts (above)"; }
  echo "    missing, in apply order: $MISSING"
}

main() {
  set -euo pipefail          # again: main runs on the left of the pipe below
  local mode="${1:-}"
  case "$mode" in ''|--check|--fresh) ;; *) echo "usage: bash $0 [--fresh | --check]" >&2; exit 2 ;; esac

  [[ -f "$SRC/deploy/check-scripts.sql" && -f "$HERE/apply-sql-test.sh" && -f "$HERE/deploy-test.sh" ]] \
    || die "$SRC is not there or is old: run  bash ~/src-test/MokaCo.HRMS/deploy/fetch-code.sh test  first."
  [[ -x "$SQLCMD" ]] || die "$SQLCMD not found."
  echo "    test code: $(cat "$SRC/.deployed-from" 2>/dev/null || echo 'an unknown commit')"

  # ---- 1. the SQL password --------------------------------------------------------------------------
  if [[ -z "${SQLCMDPASSWORD:-}" ]]; then
    read -rsp "SQL password for $SQLUSER: " SQLCMDPASSWORD; echo
  fi
  export SQLCMDPASSWORD SQLCMDSERVER="$SERVER" SQLCMDUSER="$SQLUSER"
  sql -Q "SET NOCOUNT ON; SELECT 1;" >/dev/null 2>&1 \
    || die "SQL Server refused the password for $SQLUSER (or is not running). Stop here and ask Reda; do not retry."
  # ---- --fresh: the live database as it is now, over the test database -----------------------------------
  if [[ "$mode" == --fresh ]]; then
    [[ -f "$HERE/refresh-test-db.sh" && -f "$HERE/neutralise-test-db.sql" ]] || die "$HERE/refresh-test-db.sh is missing: run fetch-code.sh test first."
    [[ "$PROD_DB" != "$DB" ]] || die "PROD_DB is the test database itself."
    log "a backup of the live database ($PROD_DB), taken now"
    sudo test -d "$BACKUP_DIR" || sudo mkdir -p "$BACKUP_DIR"
    [[ "$(sudo stat -c %U "$BACKUP_DIR")" == mssql ]] || sudo chown mssql:mssql "$BACKUP_DIR"   # SQL Server writes it
    sudo find "$BACKUP_DIR" -maxdepth 1 -name "${PROD_DB}_fortest_*.bak" -delete   # what an interrupted run left

    # Room on the disk first: a full disk would stop production's own database. The backup is at most as big as
    # the live database, and the test database grows to its size.
    local sizes prod_mb test_mb free_mb need_mb
    sizes=$(sql -h -1 -W -s '|' -Q "SET NOCOUNT ON; SELECT
        ISNULL((SELECT SUM(CAST(size AS BIGINT)) * 8 / 1024 FROM sys.master_files WHERE database_id = DB_ID(N'$PROD_DB')), -1),
        ISNULL((SELECT SUM(CAST(size AS BIGINT)) * 8 / 1024 FROM sys.master_files WHERE database_id = DB_ID(N'$DB')), 0);") \
      || die "could not read the size of $PROD_DB (above). Nothing was changed."
    IFS='|' read -r prod_mb test_mb <<< "$(tr -d ' \r' <<< "$sizes")"
    [[ "$prod_mb" =~ ^[0-9]+$ && "$test_mb" =~ ^[0-9]+$ ]] || die "the database $PROD_DB does not exist on this server. Nothing was changed."
    free_mb=$(sudo df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    need_mb=$(( prod_mb + (prod_mb > test_mb ? prod_mb - test_mb : 0) + 512 ))
    echo "    live database: ${prod_mb} MB; free on the disk: ${free_mb} MB; needed: about ${need_mb} MB"
    [[ "$free_mb" =~ ^[0-9]+$ && "$free_mb" -ge "$need_mb" ]] \
      || die "not enough free disk space for the copy (${free_mb} MB free, about ${need_mb} MB needed). Nothing was changed. Tell Reda."

    local bak="$BACKUP_DIR/${PROD_DB}_fortest_$STAMP.bak"
    # COPY_ONLY: outside production's own backup sequence. No COMPRESSION: production is SQL Server Express.
    sql -Q "BACKUP DATABASE [$PROD_DB] TO DISK = N'$bak' WITH COPY_ONLY, INIT, CHECKSUM, STATS = 25;" \
      || die "the backup of $PROD_DB failed (above). Nothing was changed."
    sql -Q "RESTORE VERIFYONLY FROM DISK = N'$bak' WITH CHECKSUM;" \
      || { sudo rm -f "$bak"; die "the backup does not verify (above). Nothing was changed."; }

    log "restoring it over $DB and making the copy safe (refresh-test-db.sh: answer y when it asks)"
    # The SQL password goes to it through the environment, never on a command line. Where sudo may not keep an
    # environment variable, refresh-test-db.sh simply asks for the password again.
    local keep=()
    sudo --preserve-env=SQLCMDPASSWORD true 2>/dev/null && keep=(--preserve-env=SQLCMDPASSWORD,SQLCMDSERVER,SQLCMDUSER)
    if ! sudo ${keep[@]+"${keep[@]}"} bash "$HERE/refresh-test-db.sh" "$bak"; then
      sudo rm -f "$bak"
      die "refresh-test-db.sh stopped (its reason is just above). If it had already replaced $DB, the test API is stopped: run this command again. Send Claude a picture of these last lines."
    fi
    sudo rm -f "$bak"
    echo "    $DB is now a safe copy of $PROD_DB. The test API is started by the last step below."
  fi

  sql -h -1 -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$DB') IS NULL THEN 'absent' ELSE 'there' END;" | grep -q there \
    || die "the database $DB does not exist on this server: run this with --fresh to make it from the live database (deploy/test-env/README.md)."

  # ---- 2. what the test database lacks --------------------------------------------------------------
  log "which scripts $DB lacks"
  check_scripts
  if [[ "$mode" == --check ]]; then
    echo; echo "Checked only: nothing was changed."; return 0
  fi

  # ---- 3. those scripts, in order, on the TEST database only -------------------------------------------
  if [[ "$MISSING" == none ]]; then
    log "no script to apply"
  else
    local f n=0 total
    total=$(wc -w <<< "$MISSING")
    for f in $MISSING; do
      [[ -f "$SRC/docs/$f" ]] || die "docs/$f is not in $SRC: run fetch-code.sh test again. Stopped before applying it."
    done
    cd "$SRC"
    for f in $MISSING; do
      n=$((n + 1))
      log "[$n/$total] docs/$f -> $DB"
      bash "$HERE/apply-sql-test.sh" "docs/$f" \
        || die "docs/$f failed on $DB (the error is just above). Stopped there: the scripts after it were not applied and nothing was deployed. Send Claude a picture of these last lines."
    done
    log "checking again"
    check_scripts
    [[ "$MISSING" == none ]] || die "still missing after applying them: $MISSING. Nothing was deployed. Send Claude a picture of these last lines."
  fi

  # ---- 4. the test API and the test front end ---------------------------------------------------------
  log "deploying the test side (deploy-test.sh)"
  bash "$HERE/deploy-test.sh" \
    || die "deploy-test.sh stopped (its reason is just above). Send Claude a picture of these last lines."
}

set +e
main "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
unset SQLCMDPASSWORD
if [[ $status -ne 0 ]]; then
  printf '\n\033[1;31mThe test side was NOT updated.\033[0m The reason is in the lines above (also kept in %s).\n' "$LOG" >&2
fi
exit "$status"
