#!/usr/bin/env bash
#
# deploy/update-prod.sh — bring PRODUCTION up to what sync-prod.sh sent: the database first, then the API.
# Run ON THE VM, after deploy/sync-prod.sh on the laptop:
#
#   bash ~/src/MokaCo.HRMS/deploy/update-prod.sh            # the whole update
#   bash ~/src/MokaCo.HRMS/deploy/update-prod.sh --web      # the same, and deploy-web.sh after the API
#   bash ~/src/MokaCo.HRMS/deploy/update-prod.sh --check    # only says what is missing; changes nothing
#
# In this order, stopping at the first failure:
#   1. the SQL password, asked once (hidden, never stored). Refused: it stops; ask Reda, do not retry.
#   2. a backup of MokaCo_HRMS in /var/opt/mssql/backup (MokaCo_HRMS_before_update_<time>.bak).
#   3. the numbered docs/ scripts the database lacks (deploy/check-scripts.sql), applied in number
#      order with sqlcmd -I -b: the same scripts, in the same order, as the test database got. A script
#      that fails stops everything there; the API is then not deployed.
#   4. deploy-api.sh (build, install, restart); /health must then say "schema":"ok".
#   5. HSTS on the HTTPS site, and the Google gate's nginx part again if it is on (both change nothing
#      when already current). A failure here is reported; the update itself is done by then.
#   6. what tonight's leavers' sweep (01:00) will do, run in a transaction that is rolled back.
# Everything it prints also goes to ~/prod-update-<time>.log; the scripts' OWNER CHECK lines are
# repeated at the end.
#
# It does NOT touch sshd, the firewall, netplan, Bitdefender or the shared account, and never reboots.
#
set -euo pipefail
SRC="${SRC:-$HOME/src/MokaCo.HRMS}"
DB=MokaCo_HRMS
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
SERVER="${SQLCMDSERVER:-127.0.0.1}"
SQLUSER="${SQLCMDUSER:-sa}"
BACKUP_DIR="${BACKUP_DIR:-/var/opt/mssql/backup}"
PORT=5078
STAMP=$(date +%Y%m%d-%H%M)
LOG="$HOME/prod-update-$STAMP.log"
SQLLOG="$HOME/prod-update-$STAMP.sql.log"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

sql() { "$SQLCMD" -S "$SERVER" -U "$SQLUSER" -C -b "$@"; }

# Runs deploy/check-scripts.sql (read-only). Sets MISSING ("none" or the files in apply order) and BOOKING.
check_scripts() {
  local out
  out=$(sql -d "$DB" -i "$SRC/deploy/check-scripts.sql" 2>&1) || { echo "$out"; die "deploy/check-scripts.sql failed (above)"; }
  MISSING=$(sed -n 's/^Missing, in apply order: //p' <<< "$out")
  BOOKING=$(sed -n 's/.*Booking tables of the base: //p' <<< "$out")
  [[ -n "$MISSING" ]] || { echo "$out"; die "could not read the list of missing scripts (above)"; }
  grep -E 'MISSING' <<< "$out" | grep -v '^Database:' | sed 's/^/    /' || true
  echo "    missing, in apply order: $MISSING"
}

# The API on $PORT once it answers (it takes a few seconds after a restart): its /health.
api_health() {
  local health=""
  for _ in $(seq 1 15); do
    health=$(curl -s -m 5 "http://127.0.0.1:$PORT/health" || true)
    [[ "$health" == *'"schema"'* && "$health" != *'"schema":"unknown"'* ]] && break
    sleep 2
  done
  echo "$health"
}

main() {
  set -euo pipefail          # again: main runs on the left of the pipe below, after set +e
  local mode="${1:-}"
  case "$mode" in ''|--web|--check) ;; *) echo "usage: bash $0 [--web | --check]" >&2; exit 2 ;; esac

  log "production update ($(cat "$SRC/.deployed-from" 2>/dev/null || echo "no .deployed-from: run deploy/sync-prod.sh on the laptop first"))"
  [[ -f "$SRC/deploy/check-scripts.sql" ]] || die "$SRC/deploy/check-scripts.sql missing: run deploy/sync-prod.sh on the laptop first"
  echo "    log: $LOG"

  # ---- 1. the SQL password --------------------------------------------------------------------------
  if [[ -z "${SQLCMDPASSWORD:-}" ]]; then
    read -rsp "SQL password for $SQLUSER: " SQLCMDPASSWORD; echo
  fi
  export SQLCMDPASSWORD
  sql -Q "SET NOCOUNT ON; SELECT 1;" >/dev/null 2>&1 \
    || die "SQL Server refused the password for $SQLUSER (or is not running). Stop here and ask Reda; do not retry."
  [[ "$(sql -h -1 -W -Q "SET NOCOUNT ON; SELECT ISNULL(CONVERT(VARCHAR(10), DB_ID(N'$DB')), 'none');")" != none ]] \
    || die "there is no database $DB on this server"

  log "what the database lacks"
  check_scripts
  if [[ "$mode" == --check ]]; then
    log "the API on port $PORT"
    echo "    /health: $(curl -s -m 5 "http://127.0.0.1:$PORT/health" || echo 'no answer')"
    echo "    /api/access: HTTP $(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/api/access" || true) (401 = the new API, 404 = the old one)"
    echo "    service: $(systemctl is-active mokaco-api 2>/dev/null || true), main PID $(systemctl show -p MainPID --value mokaco-api 2>/dev/null || echo '?')"
    log "--check: nothing was changed"
    return 0
  fi
  if [[ "$MISSING" != none && "$BOOKING" != present ]]; then
    die "the booking tables of the base are missing, so the booking scripts cannot apply. Nothing was changed: send Claude the log $LOG"
  fi
  for f in $MISSING; do
    [[ "$f" == none || -f "$SRC/docs/$f" ]] || die "docs/$f is not in $SRC: run deploy/sync-prod.sh on the laptop again. Nothing was changed."
  done

  # ---- 2. backup ------------------------------------------------------------------------------------
  log "backing up $DB"
  if ! sudo test -d "$BACKUP_DIR"; then
    sudo mkdir -p "$BACKUP_DIR"
    sudo chown mssql:mssql "$BACKUP_DIR"
  fi
  local bak="$BACKUP_DIR/${DB}_before_update_$STAMP.bak"
  sql -Q "BACKUP DATABASE [$DB] TO DISK = N'$bak' WITH INIT, COMPRESSION, CHECKSUM, STATS = 25;" \
    || die "the backup failed (above). Nothing was changed."
  echo "    $bak"

  # ---- 3. the scripts -------------------------------------------------------------------------------
  if [[ "$MISSING" == none ]]; then
    log "no script to apply"
  else
    local f n=0 total
    total=$(wc -w <<< "$MISSING")
    for f in $MISSING; do
      n=$((n + 1))
      log "[$n/$total] docs/$f"
      if ! sql -I -d "$DB" -i "$SRC/docs/$f" 2>&1 | tee -a "$SQLLOG"; then
        die "docs/$f failed (the error is just above). Stopped there: the scripts after it were not applied and the API
     was not deployed. The backup is $bak. Send Claude the log: $LOG"
      fi
    done
    log "checking again"
    check_scripts
    [[ "$MISSING" == none ]] || die "still missing after applying them: $MISSING. The API was not deployed. Send Claude the log: $LOG"
  fi

  # ---- 4. the API -----------------------------------------------------------------------------------
  log "deploying the API (deploy-api.sh)"
  bash "$SRC/deploy/deploy-api.sh" \
    || die "deploy-api.sh failed (above). The database is updated; the API that was running before keeps running. Send Claude the log: $LOG"
  local health access
  health=$(api_health)
  echo "    /health: $health"
  case "$health" in
    *'"schema":"ok"'*) ;;
    *'"schema":"behind"'*) die "the new API says scripts are missing (above). Send Claude the log: $LOG" ;;
    *'"schema"'*) warn "the new API could not check the scripts yet; it will again on the next /health" ;;
    *) die "the API answering on $PORT is not the new one (no \"schema\" in /health). Send Claude the log: $LOG" ;;
  esac
  access=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/api/access" || true)
  [[ "$access" == 401 ]] || die "/api/access answers HTTP $access, expected 401 (the new API asking for a sign-in). Send Claude the log: $LOG"
  echo "    /api/access: HTTP 401 (the new API)"

  if [[ "$mode" == --web ]]; then
    log "deploying the website (deploy-web.sh)"
    bash "$SRC/deploy/deploy-web.sh" || die "deploy-web.sh failed (above). The database and the API are updated. Send Claude the log: $LOG"
  fi

  # ---- 5. nginx: HSTS, the Google gate --------------------------------------------------------------
  log "HSTS on the HTTPS site (enable-tls.sh, HSTS only)"
  HSTS_ONLY=1 bash "$SRC/deploy/enable-tls.sh" || warn "the HSTS step failed (above). The update itself is done; send Claude the log."
  local gate gate_mode
  gate=$(bash "$SRC/deploy/enable-google-gate.sh" --status 2>&1 || true)
  sed 's/^/    /' <<< "$gate"
  gate_mode=$(sed -n 's/^Google sign-in gate in nginx: \(--test\|--all\)\..*/\1/p' <<< "$gate" | head -1)
  if [[ -n "$gate_mode" ]]; then
    log "the Google gate is on ($gate_mode): writing this version's nginx part"
    sudo bash "$SRC/deploy/enable-google-gate.sh" "$gate_mode" || warn "enable-google-gate.sh $gate_mode failed (above); it puts everything back on failure. Send Claude the log."
  fi

  # ---- 6. tonight's leavers' sweep ------------------------------------------------------------------
  log "tonight's leavers' sweep (01:00), run now in a transaction that is rolled back: nothing is changed"
  local preview
  read -r -d '' preview <<'SQL' || true
SET NOCOUNT ON;
DECLARE @r TABLE (EmployeesApplied INT, UsersDisabled INT, UsersKept INT, BranchManagersCleared INT,
                  PinMappingsRemoved INT, StepsWaiting INT, OpenRequests INT, Summary NVARCHAR(MAX));
BEGIN TRAN;
INSERT INTO @r EXEC hr.usp_Employee_ApplyDueTerminations;
ROLLBACK;                                   -- a table variable keeps its rows through the rollback
DECLARE @line NVARCHAR(4000), @s NVARCHAR(MAX), @p INT;
SELECT @line = CONCAT(N'    leavers: ', EmployeesApplied, N'; accounts switched off: ', UsersDisabled,
                      N' (kept: ', UsersKept, N'); branch managers cleared: ', BranchManagersCleared,
                      N'; terminal PINs removed: ', PinMappingsRemoved, N'; approval steps waiting on them: ',
                      StepsWaiting, N'; their open requests: ', OpenRequests),
       @s = Summary
FROM @r;
PRINT @line;
WHILE LEN(@s) > 0                           -- one line per person
BEGIN
    SET @p = CHARINDEX(NCHAR(10), @s);
    IF @p = 0 BEGIN PRINT N'      ' + @s; BREAK; END;
    PRINT N'      ' + LEFT(@s, @p - 1);
    SET @s = SUBSTRING(@s, @p + 1, DATALENGTH(@s) / 2);
END;
SQL
  sql -d "$DB" -Q "$preview" || warn "the preview failed (above); the update itself is done. Send Claude the log."
  echo "    Anybody listed here who should keep their account: fix their termination date in HR before 01:00."

  log "OWNER CHECK lines from the scripts"
  grep -hE 'OWNER CHECK|PAID TWICE' "$SQLLOG" 2>/dev/null | sed 's/^/    /' || echo "    none"

  log "DONE: production runs $(cat "$SRC/.deployed-from" 2>/dev/null || echo '?'); the database has every script."
  echo "    /health: $health"
  echo "    Still to do in the app: regenerate each open payroll run once; Operations Managers sign out and in"
  echo "    again; review who is on tier 1 (the query at the top of docs/106_qa3_webhr.sql)."
  echo "    The whole output is in $LOG"
}

set +e
main "$@" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
unset SQLCMDPASSWORD
exit "$rc"
