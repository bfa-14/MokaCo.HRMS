#!/usr/bin/env bash
# tests/qa/run.sh — runs the whole QA suite and writes tests/qa/last-run.log.
# Prerequisites: SQL Server on localhost (sa), API on http://localhost:5078,
# web dev server on http://localhost:5173 (for ui-tests), sqlcmd, node >= 22, google-chrome.
# Set SQLCMDPASSWORD to override the development password.
set -u
QA="$(cd "$(dirname "$0")" && pwd)"
export SQLCMDPASSWORD="${SQLCMDPASSWORD:-p@ssW0rd}"
SQL="sqlcmd -S localhost -U sa -C -I -d MokaCo_HRMS -W -s |"
LOG="$QA/last-run.log"
: > "$LOG"
step() { echo | tee -a "$LOG"; echo "=============== $1 ($(date '+%F %T')) ===============" | tee -a "$LOG"; }
runsql() { $SQL -i "$1" 2>&1 | tee -a "$LOG"; }

step "0. cleanup of any previous QA run"
runsql "$QA/cleanup.sql" | grep -E "PASS|FAIL|DONE|Msg" >/dev/null

step "1. seed"
runsql "$QA/seed.sql"

step "2. rosters (SQL)"
runsql "$QA/cases/01_rosters.sql"

step "3. API phase 1 (roster approval, leaves, exit permission, deputy rules, permissions)"
node "$QA/api-tests.mjs" phase1 2>&1 | tee -a "$LOG"

step "4. attendance processing and checks (SQL)"
runsql "$QA/cases/02_attendance.sql"

step "5. API phase 2 (exit variance decisions, manual correction, payroll API rules, bookings)"
node "$QA/api-tests.mjs" phase2 2>&1 | tee -a "$LOG"

step "6. leaves (SQL)"
runsql "$QA/cases/03_leaves.sql"

step "7. payroll (SQL, rolled-back transaction)"
runsql "$QA/cases/04_payroll.sql"

step "8. bookings (SQL)"
runsql "$QA/cases/05_bookings.sql"

step "9. cross-cutting (SQL)"
runsql "$QA/cases/06_crosscutting.sql"

step "10. browser checks (R6, X4, X5)"
node "$QA/ui-tests.mjs" 2>&1 | tee -a "$LOG"

step "11. cultures and machine pull (second API instance, en-GB)"
bash "$QA/culture-and-pull.sh" 2>&1 | tee -a "$LOG"

step "12. summary"
$SQL -Q "SET NOCOUNT ON; SELECT CASE WHEN Pass = 1 THEN 'PASS' ELSE 'FAIL' END AS Result, Id, [Case], Expected, Actual FROM dbo.QA_RESULT ORDER BY Seq" 2>&1 | tee -a "$LOG" > /dev/null
$SQL -h -1 -Q "SET NOCOUNT ON; SELECT CONCAT('TOTAL checks=', COUNT(*), ' passed=', SUM(CAST(Pass AS INT)), ' failed=', SUM(1 - CAST(Pass AS INT))) FROM dbo.QA_RESULT" 2>&1 | tee -a "$LOG"
$SQL -h -1 -Q "SET NOCOUNT ON; SELECT CONCAT('FAILED: ', Id, ' | ', [Case]) FROM dbo.QA_RESULT WHERE Pass = 0 ORDER BY Seq" 2>&1 | tee -a "$LOG"

step "13. cleanup and real-data count comparison"
runsql "$QA/cleanup.sql"
echo "log written to $LOG"
