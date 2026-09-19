#!/usr/bin/env bash
# tests/qa2/run.sh — runs the QA2 scenario suite and writes tests/qa2/last-run.log.
# Prerequisites: SQL Server reachable with the credentials of tests/qa/.env (or SQLCMDSERVER / SQLCMDUSER /
# SQLCMDPASSWORD in the environment — see tests/qa/env.sh), sqlcmd, node >= 22. The API on :5078 is needed
# only for the API and WEB stages (the WEB stage also needs the web dev server on :5173 and google-chrome);
# without them those stages are reported as skipped.
# The full sqlcmd output (result sets included) goes to last-run.full.log; last-run.log keeps the PASS / FAIL /
# NOTE / error lines and the summary.
set -u
QA2="$(cd "$(dirname "$0")" && pwd)"
. "$QA2/../qa/env.sh"
SQL="sqlcmd -S $SQLCMDSERVER -U $SQLCMDUSER -C -I -d MokaCo_HRMS -W -s |"
LOG="$QA2/last-run.log"; FULL="$QA2/last-run.full.log"
: > "$LOG"; : > "$FULL"
step() { echo | tee -a "$LOG" "$FULL" >/dev/null; echo "=============== $1 ($(date '+%F %T')) ===============" | tee -a "$LOG" "$FULL"; }
runsql() { $SQL -i "$1" 2>&1 | tee -a "$FULL" | grep -E "^(PASS|FAIL|NOTE) \||^Msg [0-9]+|QA2 (SEED|CLEANUP) DONE" | tee -a "$LOG"; }

step "0. cleanup of any previous QA2 run"
$SQL -i "$QA2/cleanup.sql" >> "$FULL" 2>&1

step "1. seed"
runsql "$QA2/seed.sql"

n=2
for f in "$QA2"/cases/*.sql; do
  step "$n. $(basename "$f")"
  runsql "$f"
  n=$((n+1))
done

if [ -f "$QA2/api-tests.mjs" ]; then
  step "$n. API"
  if curl -s -m 3 -o /dev/null "${QA_API:-http://localhost:5078}/health"; then
    node "$QA2/api-tests.mjs" 2>&1 | tee -a "$FULL" | grep -E "^(PASS|FAIL|NOTE) \|" | tee -a "$LOG"
  else
    echo "NOTE | API stage skipped: ${QA_API:-http://localhost:5078} is not reachable" | tee -a "$LOG" "$FULL"
  fi
  n=$((n+1))
fi

if [ -f "$QA2/ui-tests.mjs" ]; then
  step "$n. WEB (part E)"
  if curl -s -m 3 -o /dev/null "${QA_API:-http://localhost:5078}/health"; then
    node "$QA2/ui-tests.mjs" 2>&1 | tee -a "$FULL" | grep -E "^(PASS|FAIL|NOTE) \|" | tee -a "$LOG"
  else
    echo "NOTE | WEB stage skipped: ${QA_API:-http://localhost:5078} is not reachable" | tee -a "$LOG" "$FULL"
  fi
  n=$((n+1))
fi

step "$n. summary"
$SQL -h -1 -Q "SET NOCOUNT ON; SELECT CONCAT('TOTAL checks=', COUNT(*), ' passed=', SUM(CAST(Pass AS INT)), ' failed=', SUM(1 - CAST(Pass AS INT))) FROM dbo.QA2_RESULT; SELECT CONCAT('FAILED: ', Id) FROM dbo.QA2_RESULT WHERE Pass = 0 ORDER BY Seq" 2>&1 | tee -a "$LOG" "$FULL"

step "$((n+1)). cleanup"
runsql "$QA2/cleanup.sql"
