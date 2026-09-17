#!/usr/bin/env bash
# X3 (cultures) and A13 (machine pull worker): starts a SECOND copy of the already-built
# API on 127.0.0.1:5079 under the en-GB culture with its console log captured to
# tests/qa/api-engb.log, starts the fake ZK terminal, enables pulling on the QA device,
# waits for one pull cycle, compares date parsing between the en-US instance (:5078)
# and the en-GB instance (:5079), then stops everything and disables the QA pull again.
set -u
QA="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$QA/../.." && pwd)"
LOG="$QA/api-engb.log"
export SQLCMDPASSWORD="${SQLCMDPASSWORD:-p@ssW0rd}"
SQL="sqlcmd -S localhost -U sa -C -I -h -1 -W -d MokaCo_HRMS"
qsql() { $SQL -Q "SET NOCOUNT ON; $1" | tr -d '\r'; }
record() { # id case expected actual pass(0/1)
  local p=FAIL; [ "$5" = "1" ] && p=PASS
  echo "$p | $1 | $2 | expected=$3 | actual=$4"
  local e=${3//\'/\'\'}; local a=${4//\'/\'\'}; local c=${2//\'/\'\'}
  qsql "EXEC dbo.QA_Check N'$1', N'$c', N'$e', N'$a', $5" >/dev/null
}

DLL="$ROOT/MokaCo.HRMS.API/bin/Debug/net10.0/MokaCo.HRMS.API.dll"
if [ ! -f "$DLL" ]; then record A13 "second API instance available" "built DLL" "missing $DLL" 0; exit 0; fi

qsql "UPDATE attendance.DEVICE SET PullEnabled = 1 WHERE SerialNumber = 'QA-DEVICE-001'" >/dev/null
node "$QA/fake-zk.mjs" 43700 > "$QA/fake-zk.log" 2>&1 & ZK=$!
( cd "$ROOT/MokaCo.HRMS.API" && LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 \
  ASPNETCORE_ENVIRONMENT=Development ASPNETCORE_URLS=http://127.0.0.1:5079 dotnet "$DLL" > "$LOG" 2>&1 ) & API2=$!

up=0
for i in $(seq 1 60); do curl -s -m 2 -o /dev/null http://127.0.0.1:5079/health && { up=1; break; }; sleep 1; done
if [ "$up" != "1" ]; then
  record A13 "second API instance (en-GB, :5079) starts" "healthy within 60 s" "not reachable; log tail: $(tail -c 300 "$LOG" | tr '\n' ' ')" 0
  kill $API2 $ZK 2>/dev/null; qsql "UPDATE attendance.DEVICE SET PullEnabled = 0 WHERE SerialNumber = 'QA-DEVICE-001'" >/dev/null; exit 0
fi

# ---- A13: wait for the pull cycle (20 s startup delay + the real device's 4 s timeout + the QA device) ----
for i in $(seq 1 90); do grep -q "Machine pull cycle" "$LOG" && break; sleep 1; done
QALINE=$(grep -E "Machine pull — QA Device" "$LOG" | head -1 | tr -d '\r' | sed 's/^ *//' | cut -c1-250)
CYCLE=$(grep -E "Machine pull cycle" "$LOG" | head -1 | tr -d '\r' | sed 's/^ *//' | cut -c1-200)
ERRS=$(grep -c -E "Unhandled exception|fail: |crit: " "$LOG")
PULLED=$(qsql "SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG r JOIN attendance.DEVICE d ON d.DeviceId = r.DeviceId WHERE d.SerialNumber = 'QA-DEVICE-001' AND r.[Source] = 'Pull'")
if echo "$QALINE" | grep -q "pulled 1 new punch"; then p=1; else p=0; fi
record A13 "machine pull worker (MachinePullEnabled=1, dummy device on 127.0.0.1:43700): cycle runs without exceptions and logs the 'pulled N' line" \
  "log line 'Machine pull — QA Device (127.0.0.1): pulled 1 new punch(es) of 1 read ...', 0 exceptions, 1 Pull row" \
  "line='${QALINE:-none}'; cycle='${CYCLE:-none}'; exceptions=$ERRS; Pull rows=$PULLED" $p
WARN=$(grep -E "MachinePullAutoProcess is ON" "$LOG" | head -1 | tr -d '\r' | sed 's/^ *//' | cut -c1-160)
[ -n "$WARN" ] && echo "NOTE | A13: $WARN"

# ---- X3: cultures ----
TOK1=$(curl -s -X POST http://localhost:5078/api/auth/login -H 'Content-Type: application/json' -d '{"username":"qa.hr","password":"QaPass!2026"}' | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
TOK2=$(curl -s -X POST http://127.0.0.1:5079/api/auth/login -H 'Content-Type: application/json' -d '{"username":"qa.hr","password":"QaPass!2026"}' | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
E1=$(qsql "SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1'")
count() { # base token query
  curl -s -m 10 "$1/api/attendance?$3&employeeId=$E1" -H "Authorization: Bearer $2" | grep -o '"attendanceId"' | wc -l
}
ISO_US=$(count http://localhost:5078 "$TOK1" "from=2026-08-03&to=2026-08-05")
ISO_GB=$(count http://127.0.0.1:5079 "$TOK2" "from=2026-08-03&to=2026-08-05")
DM_US=$(count http://localhost:5078 "$TOK1" "from=03/08/2026&to=05/08/2026")
DM_GB=$(count http://127.0.0.1:5079 "$TOK2" "from=03/08/2026&to=05/08/2026")
MD_US=$(count http://localhost:5078 "$TOK1" "from=08/03/2026&to=08/05/2026")
MD_GB=$(count http://127.0.0.1:5079 "$TOK2" "from=08/03/2026&to=08/05/2026")
p=0; [ "$ISO_US" = "3" ] && [ "$ISO_GB" = "3" ] && p=1
record X3a "ISO dates (what the web app sends: yyyy-MM-dd) are read the same under en-US and en-GB" "3 records on both instances" "en-US=$ISO_US en-GB=$ISO_GB" $p
p=0; [ "$DM_US" = "$DM_GB" ] && [ "$MD_US" = "$MD_GB" ] && p=1
record X3b "slash dates in query strings (dd/MM vs MM/dd) are interpreted the same under both cultures" "same count on both instances for 03/08/2026 and for 08/03/2026" "dd/MM: en-US=$DM_US en-GB=$DM_GB; MM/dd: en-US=$MD_US en-GB=$MD_GB" $p
# JSON body date (roster day) on the en-GB instance, then read it back
PUTCODE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:5079/api/roster/day -H "Authorization: Bearer $TOK2" -H 'Content-Type: application/json' \
  -d "{\"employeeId\":$E1,\"workDate\":\"2026-09-10\",\"shiftId\":$(qsql "SELECT ShiftId FROM attendance.SHIFT WHERE Name=N'Morning'"),\"isRestDay\":false}")
GOT=$(qsql "SELECT CONVERT(VARCHAR(10), WorkDate, 23) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = $E1 AND WorkDate = '2026-09-10'")
p=0; [ "$GOT" = "2026-09-10" ] && p=1
record X3c "a JSON body date (2026-09-10) posted to the en-GB instance lands on the right day" "row on 2026-09-10" "PUT status $PUTCODE; stored=$GOT" $p
qsql "DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = $E1 AND WorkDate = '2026-09-10'" >/dev/null

kill $API2 2>/dev/null; sleep 1; pkill -f "MokaCo.HRMS.API.dll" 2>/dev/null; kill $ZK 2>/dev/null
qsql "UPDATE attendance.DEVICE SET PullEnabled = 0 WHERE SerialNumber = 'QA-DEVICE-001'" >/dev/null
echo "NOTE | X3/A13: second API instance stopped; its log is tests/qa/api-engb.log"
