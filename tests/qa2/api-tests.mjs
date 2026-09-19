#!/usr/bin/env node
/* ============================================================================
   tests/qa2/api-tests.mjs — the API side of the QA2 features, over HTTP against the running API
   (QA_API, default http://localhost:5078) as the qa2.* users the seed created (password QaPass!2026).
   Runs AFTER the SQL cases, on the data they left. Every check prints
       PASS|FAIL | <id> | <case> | expected=... | actual=...
   and is written to dbo.QA2_RESULT so run.sh's summary counts it.
   The SQL connection comes from tests/qa/.env or the environment (tests/qa/qa-env.mjs); nothing falls back.
   ============================================================================ */
import { execFileSync } from 'node:child_process';
import { SQLCMD_CONNECTION } from '../qa/qa-env.mjs';

const API = process.env.QA_API ?? 'http://localhost:5078';
const PW = 'QaPass!2026';

function sql(query) {
  return execFileSync('sqlcmd', [...SQLCMD_CONNECTION, '-h', '-1', '-W', '-s', '|', '-Q', 'SET NOCOUNT ON; ' + query], { encoding: 'utf8' }).trim();
}
const q = (s) => `N'${String(s ?? '').replace(/'/g, "''")}'`;
function check(id, kase, expected, actual, pass) {
  const act = String(actual).slice(0, 680);
  console.log(`${pass ? 'PASS' : 'FAIL'} | ${id} | ${kase} | expected=${expected} | actual=${act}`);
  sql(`EXEC dbo.QA2_Check ${q(id)}, ${q(kase)}, ${q(expected)}, ${q(act)}, ${pass ? 1 : 0}`);
}
const note = (t) => console.log(`NOTE | ${t}`);

const tokens = new Map();
async function login(user) {
  const r = await fetch(`${API}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: user, password: PW }) });
  const j = await r.json().catch(() => null);
  if (r.ok) tokens.set(user, j.accessToken);
  return r.status;
}
async function api(user, method, path, body) {
  const headers = {};
  if (user) headers.Authorization = `Bearer ${tokens.get(user)}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(`${API}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: r.status, json, text };
}
const iso = (d) => d.toISOString().slice(0, 10);
const plusDays = (n) => { const d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() + n); return d; };
const nextWeekday = (from, isoDow) => { const d = new Date(from); while (((d.getDay() + 6) % 7) + 1 !== isoDow) d.setDate(d.getDate() + 1); return d; };

const id = (name) => +sql(`SELECT dbo.QA2_Emp(${q(name)})`);
const B1 = +sql(`SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 1'`);
const B2 = +sql(`SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2'`);
const M = sql(`SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month'`);

for (const u of ['qa2.owner', 'qa2.hr', 'qa2.e11']) {
  const s = await login(u);
  if (s !== 200) { check('API-0', `login as ${u}`, '200', String(s), false); process.exit(0); }
}

/* ---------------------------------------------------------------- D1: holidays ---- */
{
  const year = M.slice(0, 4);
  const list = await api('qa2.e11', 'GET', `/api/holidays?year=${year}`);
  const mine = (list.json ?? []).filter((h) => /^QA2 /.test(h.name));
  check('API-H1', 'GET /api/holidays as an ordinary employee (reading is for everybody signed in)', '200 with the QA2 holidays of the year, each with its branch name',
    `${list.status}; ${mine.map((h) => `${String(h.holidayDate).slice(0, 10)} ${h.name} [${h.branchName ?? 'all branches'}]`).join(', ')}`,
    list.status === 200 && mine.length >= 2 && mine.every((h) => h.branchName));

  const day = iso(nextWeekday(plusDays(100), 3));
  const denied = await api('qa2.e11', 'POST', '/api/holidays', { holidayDate: day, name: 'QA2 API Holiday', branchId: B2 });
  const made = await api('qa2.owner', 'POST', '/api/holidays', { holidayDate: day, name: 'QA2 API Holiday', nameAr: 'عطلة', isPaid: true, branchId: B2 });
  const again = await api('qa2.owner', 'POST', '/api/holidays', { holidayDate: day, name: 'QA2 API Holiday twice', branchId: B2 });
  const hid = made.json?.holidayId;
  const renamed = hid ? await api('qa2.owner', 'PUT', `/api/holidays/${hid}`, { holidayDate: day, name: 'QA2 API Holiday (renamed)', isPaid: false, branchId: B2 }) : { status: 'n/a' };
  check('API-H2', 'holiday write: an employee is refused, the Owner (CORE_MANAGE) creates one for QA2 Branch 2, a second one on the same date and branch is a conflict, PUT renames it and makes it unpaid',
    '403; 200 with holidayId and branchName; 409 "A holiday is already recorded on that date for that branch."; 200 renamed, isPaid false',
    `${denied.status}; ${made.status} id=${hid} branch=${made.json?.branchName}; ${again.status} ${again.json?.error ?? ''}; ${renamed.status} ${renamed.json?.name} isPaid=${renamed.json?.isPaid}`,
    denied.status === 403 && made.status === 200 && !!hid && made.json?.branchName === 'QA2 Branch 2' && again.status === 409 && /already recorded/.test(again.json?.error ?? '')
      && renamed.status === 200 && /renamed/.test(renamed.json?.name ?? '') && renamed.json?.isPaid === false);

  /* D10 over HTTP: a holiday of EVERY branch inside M touches the real employees, who are paid for M */
  const paid = await api('qa2.owner', 'POST', '/api/holidays', { holidayDate: `${M}-25`, name: 'QA2 holiday on a paid month', branchId: null });
  check('API-H3', `a holiday of every branch on ${M}-25, a month the real employees are already paid for`, '409 { error: "This period is paid — raise a payroll adjustment instead.", traceId } and nothing written',
    `${paid.status} ${paid.json?.error ?? paid.text.slice(0, 120)} traceId=${paid.json?.traceId ? 'yes' : 'no'}; rows written=${sql(`SELECT COUNT(*) FROM core.HOLIDAY WHERE Name = N'QA2 holiday on a paid month'`)}`,
    paid.status === 409 && /This period is paid/.test(paid.json?.error ?? '') && !!paid.json?.traceId && sql(`SELECT COUNT(*) FROM core.HOLIDAY WHERE Name = N'QA2 holiday on a paid month'`) === '0');

  const del = hid ? await api('qa2.owner', 'DELETE', `/api/holidays/${hid}`) : { status: 'n/a' };
  const after = await api('qa2.owner', 'GET', `/api/holidays?branchId=${B2}`);
  check('API-H4', 'DELETE /api/holidays/{id}, then the list for the branch', '204; the holiday is gone; the branch list still carries holidays of that branch only (and any of every branch)',
    `${del.status}; still listed=${(after.json ?? []).some((h) => h.holidayId === hid)}; other branches in the list=${(after.json ?? []).filter((h) => h.branchId && h.branchId !== B2).length}`,
    del.status === 204 && !(after.json ?? []).some((h) => h.holidayId === hid) && (after.json ?? []).every((h) => !h.branchId || h.branchId === B2));
}

/* ---------------------------------------------------------------- D2 / D3: working days preview, half-day leave ---- */
{
  const e11 = id('E11');
  const wed = nextWeekday(plusDays(60), 3), tue = new Date(wed); tue.setDate(tue.getDate() + 6);
  /* E11's roster stops at the end of M+2: beyond it there is no roster row, and an unrostered day counts as a working day.
     So the preview is asked for a Wednesday -> Tuesday INSIDE the rostered months. */
  const inRoster = sql(`SELECT CONVERT(CHAR(10), MIN(WorkDate), 23) FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = ${e11} AND WorkDate > DATEADD(DAY, 7, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)) AND DATEDIFF(DAY, '19000103', WorkDate) % 7 = 0`);
  const from = inRoster, to = iso(new Date(new Date(inRoster + 'T12:00:00').getTime() + 6 * 864e5));
  const prev = await api('qa2.e11', 'GET', `/api/leave-requests/working-days?employeeId=${e11}&leaveTypeId=1&from=${from}&to=${to}`);
  const other = await api('qa2.e11', 'GET', `/api/leave-requests/working-days?employeeId=${id('E1')}&leaveTypeId=1&from=${from}&to=${to}`);
  /* asking about somebody else follows the same right as RAISING for them. In this database the Employee role itself holds
     REQUEST_RAISE_OTHERS (reported in QA_REPORT_2.md), so the expectation is read from the role, not assumed. */
  const mayRaiseOthers = sql(`SELECT COUNT(*) FROM security.USER_ROLE ur JOIN security.ROLE_PERMISSION rp ON rp.RoleId = ur.RoleId JOIN security.PERMISSION p ON p.PermissionId = rp.PermissionId WHERE ur.UserId = dbo.QA2_User(N'e11') AND p.Code = 'REQUEST_RAISE_OTHERS'`) !== '0';
  check('API-L1', `GET /api/leave-requests/working-days for E11 (Sat + Sun rest), ${from} -> ${to}; then the same user asks about SOMEBODY ELSE`, `200 { calendarDays 7, workingDays 5, restDays 2, balance }; for another employee ${mayRaiseOthers ? '200 (this user holds REQUEST_RAISE_OTHERS)' : '403 (no REQUEST_RAISE_OTHERS)'}`,
    `${prev.status} ${JSON.stringify(prev.json)}; other=${other.status}`, prev.status === 200 && prev.json?.calendarDays === 7 && prev.json?.workingDays === 5 && prev.json?.restDays === 2 && typeof prev.json?.balance === 'number' && other.status === (mayRaiseOthers ? 200 : 403));
  if (mayRaiseOthers) note('API-L1: the Employee role holds REQUEST_RAISE_OTHERS in this database, so an ordinary employee may raise — and preview — leave for anybody. A configuration finding, not an API one.');

  const half = await api('qa2.e11', 'POST', '/api/leave-requests', { employeeId: e11, leaveTypeId: 1, fromDate: from, toDate: from, reason: 'QA2 API half day', halfDay: 'pm' });
  const rid = half.json?.requestInstanceId;
  const payload = rid ? await api('qa2.hr', 'GET', `/api/leave-requests/${rid}/payload`) : { status: 'n/a' };
  const twoDays = await api('qa2.e11', 'POST', '/api/leave-requests', { employeeId: e11, leaveTypeId: 1, fromDate: to, toDate: iso(new Date(new Date(to + 'T12:00:00').getTime() + 864e5)), reason: 'QA2 API bad half day', halfDay: 'AM' });
  check('API-L2', 'POST /api/leave-requests with halfDay "pm" on one day; the payload; then halfDay on a two-day request', '200 daysRequested 0.5; payload halfDay "PM"; 400 "A half day is for a one-day request…"',
    `${half.status} days=${half.json?.daysRequested}; payload ${payload.status} halfDay=${payload.json?.halfDay} title="${sql(`SELECT Title FROM workflow.REQUEST_INSTANCE WHERE RequestInstanceId = ${rid ?? 0}`)}"; two-day ${twoDays.status} ${twoDays.json?.error ?? ''}`,
    half.status === 200 && half.json?.daysRequested === 0.5 && payload.json?.halfDay === 'PM' && twoDays.status === 400 && /one-day request/.test(twoDays.json?.error ?? ''));
  if (rid) await api('qa2.e11', 'POST', `/api/requests/${rid}/cancel`, { reason: 'QA2 API done' });
}

/* ---------------------------------------------------------------- D7: branch transfer + history ---- */
{
  const e8 = id('E8');
  const before = await api('qa2.hr', 'GET', `/api/employees/${e8}`);
  const b = before.json ?? {};
  const body = { branchId: B2, departmentId: b.departmentId, positionId: b.positionId, fullName: b.fullName, nationalId: b.nationalId ?? null, nssfNumber: b.nssfNumber ?? null,
    hireDate: String(b.hireDate).slice(0, 10), terminationDate: b.terminationDate ? String(b.terminationDate).slice(0, 10) : null, email: b.email ?? null, phoneNumber: b.phoneNumber ?? null,
    preferredLanguage: b.preferredLanguage ?? 'en', branchEffectiveFrom: iso(plusDays(10)) };
  const put = await api('qa2.hr', 'PUT', `/api/employees/${e8}`, body);
  const after = await api('qa2.hr', 'GET', `/api/employees/${e8}`);
  const hist = await api('qa2.hr', 'GET', `/api/employees/${e8}/branch-history`);
  const rows = hist.json ?? [];
  /* sending the CURRENT branch is "no change" (an ordinary edit while a transfer is pending must go through); a transfer to the
     other branch dated BEFORE the pending one is what is refused */
  const plain = await api('qa2.hr', 'PUT', `/api/employees/${e8}`, { ...body, branchId: B1, branchEffectiveFrom: null });
  const early = await api('qa2.hr', 'PUT', `/api/employees/${e8}`, { ...body, branchId: B2, branchEffectiveFrom: iso(plusDays(3)) });
  const pendingId = rows[0]?.employeeBranchHistoryId;
  const cancel = pendingId ? await api('qa2.hr', 'DELETE', `/api/employees/${e8}/branch-history/${pendingId}`) : { status: 'n/a' };
  const pastId = rows[1]?.employeeBranchHistoryId;
  const cancelPast = pastId ? await api('qa2.hr', 'DELETE', `/api/employees/${e8}/branch-history/${pastId}`) : { status: 'n/a' };
  const histAfter = await api('qa2.hr', 'GET', `/api/employees/${e8}/branch-history`);
  check('API-T1', `PUT /api/employees/{id} moving E8 to QA2 Branch 2 with branchEffectiveFrom 10 days ahead; the history; then a transfer dated BEFORE that one`,
    '204; the employee is still in Branch 1 today; history newest first: Branch 2 from the future date (open-ended), Branch 1 before it (ending the day before); an ordinary edit still goes through (204); a transfer dated before the pending one is refused in words; the pending transfer can be cancelled (204), the past row cannot (4xx); one row left',
    `${put.status}; current branch ${after.json?.branchId === B1 ? 'Branch 1' : after.json?.branchId === B2 ? 'Branch 2' : after.json?.branchId}; history ${hist.status}: ${rows.map((r) => `${r.branchName} ${String(r.effectiveFrom).slice(0, 10)}..${r.effectiveTo ? String(r.effectiveTo).slice(0, 10) : 'open'}`).join(' | ')}; plain edit ${plain.status}; earlier transfer ${early.status} ${early.json?.error ?? ''}; cancel pending ${cancel.status}; cancel past ${cancelPast.status} ${cancelPast.json?.error ?? ''}; rows now ${(histAfter.json ?? []).length}`,
    put.status === 204 && after.json?.branchId === B1 && hist.status === 200 && rows.length === 2 && rows[0].branchId === B2 && String(rows[0].effectiveFrom).slice(0, 10) === body.branchEffectiveFrom && !rows[0].effectiveTo
      && rows[1].branchId === B1 && !!rows[1].effectiveTo && plain.status === 204 && early.status >= 400 && early.status < 500 && /later transfer/.test(early.json?.error ?? '')
      && cancel.status === 204 && cancelPast.status >= 400 && cancelPast.status < 500 && /already taken effect/.test(cancelPast.json?.error ?? '') && (histAfter.json ?? []).length === 1);

  const e12 = id('E12');
  const r1 = await api('qa2.hr', 'GET', `/api/roster?from=${M}-01&to=${M}-28&employeeId=${e12}&branchId=${B1}`);
  const r2 = await api('qa2.hr', 'GET', `/api/roster?from=${M}-01&to=${M}-28&employeeId=${e12}&branchId=${B2}`);
  const d1 = (r1.json ?? []).map((r) => String(r.workDate).slice(0, 10)), d2 = (r2.json ?? []).map((r) => String(r.workDate).slice(0, 10));
  check('API-T2', 'GET /api/roster with branchId for E12 (transferred on the 16th of M by the SQL case A4c)', 'Branch 1: only days up to the 15th; Branch 2: only days from the 16th; every row carries the branchId of its day',
    `B1 ${r1.status}: ${d1.length} rows ${d1[0]}..${d1[d1.length - 1]}; B2 ${r2.status}: ${d2.length} rows ${d2[0]}..${d2[d2.length - 1]}`,
    r1.status === 200 && d1.length > 0 && d1.every((d) => d < `${M}-16`) && (r1.json ?? []).every((r) => r.branchId === B1) && d2.length > 0 && d2.every((d) => d >= `${M}-16`) && (r2.json ?? []).every((r) => r.branchId === B2));
}

/* ---------------------------------------------------------------- D9 + worked without roster ---- */
{
  const e4 = id('E4');
  const dev = +sql(`SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001'`);
  /* two punches under a PIN enrolled to nobody, on E4's 3rd working day of M+1 (its own punches are removed first: the day must be derived from the unknown PIN's) */
  const day = sql(`SELECT CONVERT(CHAR(10), x.WorkDate, 23) FROM (SELECT WorkDate, ROW_NUMBER() OVER (ORDER BY WorkDate) n FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId = ${e4} AND IsRestDay = 0 AND WorkDate >= DATEADD(MONTH, 1, '${M}-01')) x WHERE x.n = 3`);
  sql(`DELETE FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = ${e4} AND WorkDate = '${day}'; DELETE FROM attendance.RAW_DEVICE_LOG WHERE EmployeeId = ${e4} AND CAST(PunchTimeUtc AS DATE) = '${day}';
       INSERT INTO attendance.RAW_DEVICE_LOG (DeviceId, EnrollPin, EmployeeId, PunchTimeUtc, PunchType, [Source], DedupHash) VALUES (${dev}, 'Q2API', NULL, '${day} 08:00', 0, 'QA2', 'QA2-API-Q-1'), (${dev}, 'Q2API', NULL, '${day} 12:00', 1, 'QA2', 'QA2-API-Q-2')`);
  const list = await api('qa2.hr', 'GET', `/api/attendance/device-quarantine?branchId=${B1}`);
  const row = (list.json ?? []).find((r) => r.enrollPin === 'Q2API');
  const denied = await api('qa2.e11', 'POST', '/api/attendance/device-quarantine/map', { deviceId: dev, enrollPin: 'Q2API', employeeId: e4 });
  const map = await api('qa2.hr', 'POST', '/api/attendance/device-quarantine/map', { deviceId: dev, enrollPin: 'Q2API', employeeId: e4 });
  const list2 = await api('qa2.hr', 'GET', `/api/attendance/device-quarantine?branchId=${B1}`);
  const rec = sql(`SELECT CONCAT([Status], ' ', WorkedMinutes, ' ', DayFraction) FROM attendance.ATTENDANCE_RECORD WHERE EmployeeId = ${e4} AND WorkDate = '${day}'`);
  check('API-Q1', 'GET /api/attendance/device-quarantine lists an unknown device user; POST …/map as an employee, then as HR (ATTENDANCE_IMPORT)',
    'listed with punchCount 2 and the device name; 403 for the employee; 200 { punchesResolved 2, daysDerived 1, daysAlreadyPaid 0 }; gone from the list; the day derived: Present 240 1.00',
    `listed=${row ? `${row.deviceName} PIN ${row.enrollPin} x${row.punchCount}` : 'no'}; employee ${denied.status}; map ${map.status} ${JSON.stringify(map.json)}; still listed=${(list2.json ?? []).some((r) => r.enrollPin === 'Q2API')}; record=${rec || 'none'}`,
    !!row && row.punchCount === 2 && denied.status === 403 && map.status === 200 && map.json?.punchesResolved === 2 && map.json?.daysDerived === 1 && map.json?.daysAlreadyPaid === 0
      && !(list2.json ?? []).some((r) => r.enrollPin === 'Q2API') && rec === 'Present 240 1.00');

  const sat = sql(`SELECT CONVERT(CHAR(10), WorkDate, 23) FROM dbo.QA2_DAY WHERE CaseId = 'A1i'`);
  const wwr = await api('qa2.hr', 'GET', `/api/attendance/worked-without-roster?from=${sat}&to=${sat}&branchId=${B1}`);
  const hit = (wwr.json ?? []).find((r) => r.employeeId === e4);
  check('API-W1', `GET /api/attendance/worked-without-roster for ${sat} (E4 punched 08:00-12:00 on a day the approved roster does not give him)`, '200 with E4: branch QA2 Branch 1, 2 punches, 240 minutes',
    `${wwr.status} ${hit ? `${hit.employeeName} ${hit.branchName} punches=${hit.punchCount} minutes=${hit.workedMinutes}` : 'E4 not listed'}`, wwr.status === 200 && !!hit && hit.punchCount === 2 && hit.workedMinutes === 240 && hit.branchName === 'QA2 Branch 1');
}
note('QA2 API stage done.');
