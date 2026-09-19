#!/usr/bin/env node
/* ============================================================================
   tests/qa/api-tests.mjs — drives the HRMS API as qa.owner / qa.hr / qa.manager /
   qa.ops / qa.e1 / qa.e5 (all password QaPass!2026, created by seed.sql).

     node api-tests.mjs phase1   (after seed.sql: roster approval, leaves, exit permission)
     node api-tests.mjs phase2   (after cases/02_attendance.sql: anomaly and exit variance decisions,
                                  manual correction, payroll API rules, bookings, permissions)

   Every check prints one line:  PASS|FAIL | <id> | <case> | expected=... | actual=...
   and is also written to dbo.QA_RESULT (so run.sh can build the summary).
   Needs: API on http://localhost:5078, sqlcmd on PATH, and SQLCMDSERVER / SQLCMDUSER /
   SQLCMDPASSWORD from the environment or tests/qa/.env (see qa-env.mjs; nothing falls back).
   ============================================================================ */
import { execFileSync } from 'node:child_process';
import { SQLCMD_CONNECTION } from './qa-env.mjs';

const API = process.env.QA_API ?? 'http://localhost:5078';
const PW = 'QaPass!2026';
const phase = process.argv[2];
if (!['phase1', 'phase2'].includes(phase)) { console.error('usage: node api-tests.mjs phase1|phase2'); process.exit(2); }

/* ---------------------------------------------------------------- helpers ---- */
function sql(query) {
  const out = execFileSync('sqlcmd', [...SQLCMD_CONNECTION, '-h', '-1', '-W', '-s', '|',
    '-Q', 'SET NOCOUNT ON; ' + query], { encoding: 'utf8' });
  return out.trim();
}
const q = (s) => `N'${String(s ?? '').replace(/'/g, "''")}'`;
let failures = 0;
function check(id, kase, expected, actual, pass) {
  const exp = String(expected), act = String(actual).slice(0, 580);
  console.log(`${pass ? 'PASS' : 'FAIL'} | ${id} | ${kase} | expected=${exp} | actual=${act}`);
  if (!pass) failures++;
  sql(`EXEC dbo.QA_Check ${q(id)}, ${q(kase)}, ${q(exp)}, ${q(act)}, ${pass ? 1 : 0}`);
}
function note(text) { console.log(`NOTE | ${text}`); }
function state(key, value) { sql(`DELETE FROM dbo.QA_STATE WHERE [Key]=${q(key)}; INSERT INTO dbo.QA_STATE VALUES (${q(key)}, ${q(value)})`); }
function stateGet(key) { return sql(`SELECT [Value] FROM dbo.QA_STATE WHERE [Key]=${q(key)}`); }

const tokens = new Map();
async function login(user, password = PW) {
  const r = await fetch(`${API}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: user, password }) });
  const j = await r.json().catch(() => null);
  if (r.ok) tokens.set(user, j.accessToken);
  return { status: r.status, json: j };
}
/** Calls the API as `user` (null = anonymous). Returns {status, json, text}. */
async function api(user, method, path, body, opts = {}) {
  const headers = { ...(opts.headers ?? {}) };
  if (user) headers.Authorization = `Bearer ${tokens.get(user)}`;
  let payload;
  if (body instanceof FormData) payload = body;
  else if (body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const r = await fetch(`${API}${path}`, { method, headers, body: payload });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
  refusals.push({ path, status: r.status, text: text.slice(0, 300) });
  return { status: r.status, json, text };
}
const refusals = [];

/* ---- a minimal SignalR client (JSON protocol over a WebSocket; Node 22 has both built in), so the suite needs no package.
        token = staff JWT (travels as ?access_token=, the way a browser sends it) or null for the website's anonymous guest. ---- */
const RS = '\x1e';
async function hubConnect(token) {
  const auth = token ? `&access_token=${encodeURIComponent(token)}` : '';
  const neg = await fetch(`${API}/hubs/booking/negotiate?negotiateVersion=1${auth}`, { method: 'POST' });
  if (!neg.ok) return { ok: false, status: neg.status, events: [], close() {} };
  const { connectionToken } = await neg.json();
  const ws = new WebSocket(`${API.replace(/^http/, 'ws')}/hubs/booking?id=${encodeURIComponent(connectionToken)}${auth}`);
  const events = [], completions = new Map();
  let handshake; const ready = new Promise((res, rej) => { handshake = res; ws.onerror = () => rej(new Error('websocket error')); });
  ws.onmessage = (m) => {
    for (const frame of String(m.data).split(RS).filter(Boolean)) {
      const msg = JSON.parse(frame);
      if (msg.type === undefined) handshake(msg);                                   // {} = handshake accepted
      else if (msg.type === 1) events.push({ target: msg.target, arg: msg.arguments?.[0] });
      else if (msg.type === 3) completions.get(msg.invocationId)?.(msg);
    }
  };
  await new Promise((res) => (ws.onopen = res));
  ws.send(JSON.stringify({ protocol: 'json', version: 1 }) + RS);
  await ready;
  let seq = 0;
  return {
    ok: true, events,
    invoke(target, ...args) { const id = String(++seq); return new Promise((res) => { completions.set(id, res); ws.send(JSON.stringify({ type: 1, invocationId: id, target, arguments: args }) + RS); }); },
    async waitFor(pred, ms = 4000) { const end = Date.now() + ms; while (Date.now() < end) { const hit = events.find(pred); if (hit) return hit; await new Promise((r) => setTimeout(r, 100)); } return null; },
    close() { try { ws.close(); } catch { /* already closed */ } },
  };
}
/** X1: a refusal must be JSON {error} in plain words — never SQL text or a stack trace. */
function looksClean(text) {
  return !/Violation of|System\.|at MokaCo\.|Exception|stack|Microsoft\.Data\.SqlClient/i.test(text ?? '');
}
const ids = {};
function loadIds() {
  const rows = sql(`SELECT FullName, EmployeeId, ISNULL(UserId,0) FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %'`).split('\n');
  for (const row of rows) { const [name, emp, usr] = row.split('|').map((s) => s.trim()); if (name) ids[name] = { emp: +emp, user: +usr }; }
  ids.branch = +sql(`SELECT BranchId FROM hr.BRANCH WHERE Name=N'QA Branch'`);
  ids.room = +sql(`SELECT RoomId FROM booking.ROOM WHERE Code='qa-room'`);
  ids.addon = +sql(`SELECT AddonId FROM booking.ROOM_ADDON WHERE Name=N'QA Platter'`);
  ids.morning = +sql(`SELECT ShiftId FROM attendance.SHIFT WHERE Name=N'Morning'`);
  ids.users = {};
  for (const row of sql(`SELECT Username, UserId FROM security.[USER] WHERE Username LIKE N'qa.%'`).split('\n')) {
    const [u, id] = row.split('|').map((s) => s.trim()); if (u) ids.users[u] = +id;
  }
  ids.tips = +sql(`SELECT ComponentTypeId FROM hr.COMPONENT_TYPE WHERE Name=N'Tips'`);
}
const iso = (d) => d.toISOString().slice(0, 10);
const today = new Date(); today.setHours(12, 0, 0, 0);
const plusDays = (n) => { const d = new Date(today); d.setDate(d.getDate() + n); return iso(d); };

/* ---------------------------------------------------------------- phase 1 ---- */
async function phase1() {
  loadIds();
  for (const u of ['qa.owner', 'qa.hr', 'qa.manager', 'qa.ops', 'qa.e1', 'qa.e5']) {
    const r = await login(u);
    check('X0', `login ${u}`, '200 + accessToken', `${r.status}${r.json?.accessToken ? ' + token' : ''}`, r.status === 200 && !!r.json?.accessToken);
  }
  const bad = await login('qa.e1', 'wrong-password');
  check('X1a', 'wrong password: 401 with a plain-words JSON error', '401 {"error":"Invalid username or password."}',
    `${bad.status} ${JSON.stringify(bad.json)}`, bad.status === 401 && /Invalid username or password/.test(bad.json?.error ?? ''));

  /* ---- X4: permissions at the API ---- */
  const empList = await api('qa.manager', 'GET', '/api/employees');
  const foreign = (empList.json ?? []).filter((e) => e.branch !== 'QA Branch');
  check('X4a', 'a Manager (branch manager of QA Branch) sees only own-branch employees on GET /api/employees',
    'no employees of other branches in the list', `status ${empList.status}, ${(empList.json ?? []).length} employees returned, ${foreign.length} from other branches (e.g. ${foreign.slice(0, 2).map((e) => e.fullName + '/' + e.branch).join(', ')})`,
    empList.status === 200 && foreign.length === 0);
  const opsPayroll = await api('qa.ops', 'GET', '/api/payroll/runs');
  check('X4b', 'an Operations Manager gets 403 on GET /api/payroll/runs (no PAYROLL_* permission)', '403', `${opsPayroll.status} body=${opsPayroll.text.slice(0, 80) || '(empty)'}`, opsPayroll.status === 403);
  const opsSettings = await api('qa.ops', 'GET', '/api/settings');
  check('X4c', 'an Operations Manager gets 403 on GET /api/settings', '403', `${opsSettings.status}`, opsSettings.status === 403);

  /* ---- R3: roster approval through the ROSTER_APPROVAL workflow ---- */
  const created = await api('qa.hr', 'POST', '/api/workflow/roster-approvals', { branchId: ids.branch, monthDate: '2026-08-01', title: 'QA roster August' });
  check('R3a', 'HR submits the QA Branch August roster for approval', '200 + requestInstanceId, status Pending', `${created.status} ${JSON.stringify(created.json)}`, created.status === 200 && created.json?.requestInstanceId > 0);
  const rid = created.json?.requestInstanceId;
  state('req.roster', rid);
  let rm = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=2026-08-01`);
  check('R3b', 'roster month status after submit', 'PendingApproval', `${rm.json?.status}`, rm.json?.status === 'PendingApproval');
  const s1 = await api('qa.manager', 'POST', `/api/requests/${rid}/approve`, { comment: 'QA step 1', password: PW });
  check('R3c', 'step 1 (BranchManager = qa.manager) approves with password', '200, currentStepNo 2', `${s1.status} ${JSON.stringify(s1.json)}`, s1.status === 200 && s1.json?.currentStepNo === 2);
  const s2 = await api('qa.hr', 'POST', `/api/requests/${rid}/approve`, { comment: 'QA step 2', password: PW });
  check('R3d', 'step 2 (HR role; the submitter may sign an organisational request) approves', '200, currentStepNo 3', `${s2.status} ${JSON.stringify(s2.json)}`, s2.status === 200 && s2.json?.currentStepNo === 3);
  const s3 = await api('qa.owner', 'POST', `/api/requests/${rid}/approve`, { comment: 'QA step 3', password: PW });
  check('R3e', 'step 3 (Owner) approves; request closes Approved', '200, status Approved', `${s3.status} ${JSON.stringify(s3.json)}`, s3.status === 200 && s3.json?.status === 'Approved');
  rm = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=2026-08-01`);
  const applied = rm.json?.status === 'Approved';
  check('R3f', 'after the final approval the roster month becomes Approved (approval effect applied)', 'Approved', `${rm.json?.status} (request ${rid} status ${s3.json?.status})`, applied);
  if (!applied) {
    note('R3f: applying the approval effect by hand (EXEC workflow.usp_Request_ApplyApprovalEffects) so the attendance cases can run against an approved roster.');
    sql(`EXEC workflow.usp_Request_ApplyApprovalEffects @RequestInstanceId=${rid}`);
    rm = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=2026-08-01`);
    note(`R3f: roster month status after manual effect application = ${rm.json?.status}`);
  }
  /* R3 lock: editing a day of the approved month */
  const e1 = ids['QA E1'].emp;
  const edit = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: '2026-08-20', shiftId: null, isRestDay: true });
  check('R3g', 'editing a PAST day of an APPROVED month is refused: 409 with the lock sentence (no SQL text)',
    '409 + {error:"This day is already in an approved roster..."}', `${edit.status} ${edit.text.slice(0, 160)}`, edit.status === 409 && looksClean(edit.text) && /already in an approved roster/i.test(edit.json?.error ?? ''));
  const day = await api('qa.hr', 'GET', `/api/roster?from=2026-08-20&to=2026-08-20&employeeId=${e1}`);
  const rowNow = (day.json ?? [])[0];
  if (edit.status === 200) {
    check('R4a', 'the changed day is visible in the roster calendar read (GET /api/roster)', 'isRestDay true for 2026-08-20', `isRestDay=${rowNow?.isRestDay} shiftId=${rowNow?.shiftId}`, rowNow?.isRestDay === true);
    rm = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=2026-08-01`);
    check('R4b', 'changing an approved day requires re-approval (month leaves Approved)', 'status not Approved after the change', `${rm.json?.status}`, rm.json?.status !== 'Approved');
    const revert = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: '2026-08-20', shiftId: ids.morning, isRestDay: false });
    note(`R4: reverted 2026-08-20 to the Morning shift (status ${revert.status}) so the attendance cases keep their expected roster.`);
  } else {
    check('R4a', 'the changed day is visible in the roster calendar read', 'n/a: edit was refused', `edit refused with ${edit.status}`, true);
    check('R4b', 'changing an approved day requires re-approval', 'n/a: edit was refused', `edit refused with ${edit.status}`, true);
  }
  /* X1: a database constraint error must not leak */
  const fk = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: 999999, workDate: '2026-08-20', shiftId: ids.morning, isRestDay: false });
  check('X1b', 'PUT /api/roster/day for a non-existent employee: clean JSON error, no SQL constraint text or stack trace',
    '4xx {error:"..."}', `${fk.status} ${fk.text.slice(0, 200).replace(/\s+/g, ' ')}`, fk.status < 500 && looksClean(fk.text) && !!fk.json?.error);
  /* X1c: a constraint no controller maps (a shift that does not exist -> FK 547) reaches the global
     exception handler: 400 {error, traceId} in plain words, in Development too. Nothing is written. */
  const fk2 = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: '2026-10-20', shiftId: 999999, isRestDay: false });
  check('X1c', 'PUT /api/roster/day with a non-existent shift (unmapped FK violation): the global handler answers 400 {error, traceId}, no constraint text',
    '400 {error:"The referenced record does not exist or the value is not allowed.", traceId}', `${fk2.status} ${fk2.text.slice(0, 200).replace(/\s+/g, ' ')}`,
    fk2.status === 400 && looksClean(fk2.text) && /does not exist or the value is not allowed/.test(fk2.json?.error ?? '') && !!fk2.json?.traceId);

  /* ---- R4c-R4e: the lock on a month that still has FUTURE days (the month after this one, E1 only) ----
     pending month read-only -> approved: a future day may change, the month stays Approved and says
     changedSinceApproval -> re-submission opens a new request and the month stays Approved (the
     processor keeps the signed-off shifts). cleanup.sql removes the rows, header and requests. */
  const nm = new Date(today); nm.setDate(1); nm.setMonth(nm.getMonth() + 1);
  const nmFrom = iso(nm), nmTo = iso(new Date(nm.getFullYear(), nm.getMonth() + 1, 0, 12)), nmDay = iso(new Date(nm.getFullYear(), nm.getMonth(), 15, 12));
  const gen = await api('qa.hr', 'POST', '/api/roster/generate', { employeeId: e1, fromDate: nmFrom, toDate: nmTo, shiftId: ids.morning, weekdays: '1111110', overwrite: false });
  const sub = await api('qa.hr', 'POST', '/api/workflow/roster-approvals', { branchId: ids.branch, monthDate: nmFrom, title: 'QA roster next month' });
  const rid2 = sub.json?.requestInstanceId; state('req.roster2', rid2);
  const pend = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: nmDay, shiftId: null, isRestDay: true });
  check('R4c', `a month waiting for approval is read-only: PUT /api/roster/day on ${nmDay} while request ${rid2} is pending`,
    '409 {error:"Waiting for approval — request #N. Withdraw or wait..."}', `generate ${gen.status}, submit ${sub.status}, edit ${pend.status} ${pend.json?.error ?? pend.text.slice(0, 120)}`,
    gen.status === 200 && sub.status === 200 && pend.status === 409 && new RegExp(`Waiting for approval .*#${rid2}`).test(pend.json?.error ?? ''));
  for (const [u, step] of [['qa.manager', 1], ['qa.hr', 2], ['qa.owner', 3]]) await api(u, 'POST', `/api/requests/${rid2}/approve`, { comment: `QA step ${step}`, password: PW });
  const rm2 = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=${nmFrom}`);
  const fut = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: nmDay, shiftId: null, isRestDay: true });
  const rm3 = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=${nmFrom}`);
  check('R4d', `a FUTURE day (${nmDay}) of an APPROVED month may be changed by HR: 200; the month stays Approved and reports changedSinceApproval`,
    'Approved before; 200; Approved + changedSinceApproval=true after', `${rm2.json?.status} before; ${fut.status}; ${rm3.json?.status} + changedSinceApproval=${rm3.json?.changedSinceApproval} after`,
    rm2.json?.status === 'Approved' && fut.status === 200 && rm3.json?.status === 'Approved' && rm3.json?.changedSinceApproval === true);
  const resub = await api('qa.hr', 'POST', '/api/workflow/roster-approvals', { branchId: ids.branch, monthDate: nmFrom, title: 'QA roster next month (changed)' });
  const rm4 = await api('qa.hr', 'GET', `/api/attendance/roster-month?branchId=${ids.branch}&month=${nmFrom}`);
  const lock2 = await api('qa.hr', 'PUT', '/api/roster/day', { employeeId: e1, workDate: nmDay, shiftId: ids.morning, isRestDay: false });
  check('R4e', 're-submitting the changed month opens a new request; the month stays Approved (processing keeps the signed-off shifts) and is read-only again',
    '200 + new request; status Approved, openRequestId = new request; edit 409', `${resub.status} rid=${resub.json?.requestInstanceId}; status ${rm4.json?.status}, openRequestId ${rm4.json?.openRequestId}; edit ${lock2.status}`,
    resub.status === 200 && resub.json?.requestInstanceId > rid2 && rm4.json?.status === 'Approved' && rm4.json?.openRequestId === resub.json?.requestInstanceId && lock2.status === 409);
  if (resub.json?.requestInstanceId) await api('qa.hr', 'POST', `/api/requests/${resub.json.requestInstanceId}/cancel`, { reason: 'QA done with the next-month roster' });

  /* ---- leaves ---- */
  const e5 = ids['QA E5'].emp, e6 = ids['QA E6'].emp, mgr = ids['QA Manager'].emp;
  const l2 = await api('qa.e5', 'POST', '/api/leave-requests', { employeeId: e5, leaveTypeId: 1, fromDate: '2026-08-17', toDate: '2026-08-19', reason: 'QA annual 3 days' });
  check('L2a', 'E5 raises a 3-day annual leave (17-19 Aug)', '200 + requestInstanceId, daysRequested 3', `${l2.status} ${JSON.stringify(l2.json)}`, l2.status === 200 && l2.json?.daysRequested === 3);
  const rl2 = l2.json?.requestInstanceId; state('req.l2', rl2);
  check('L4a', 'submit response carries the short-notice warning (14 days preferred, dates in the past)', 'noticeShorterThanPreferred=true, noticePreferredDays=14',
    `noticeShorterThanPreferred=${l2.json?.noticeShorterThanPreferred} noticePreferredDays=${l2.json?.noticePreferredDays}`, l2.json?.noticeShorterThanPreferred === true && l2.json?.noticePreferredDays === 14);
  const pl = await api('qa.manager', 'GET', `/api/leave-requests/${rl2}/payload`);
  check('L4b', 'the approver\'s payload shows the warning fields (noticeGivenDays, noticePreferredDays, noticeShorterThanPreferred)',
    'noticeShorterThanPreferred=true with noticeGivenDays < 14', `status ${pl.status} noticeGivenDays=${pl.json?.noticeGivenDays} noticePreferredDays=${pl.json?.noticePreferredDays} noticeShorterThanPreferred=${pl.json?.noticeShorterThanPreferred}`,
    pl.status === 200 && pl.json?.noticeShorterThanPreferred === true && typeof pl.json?.noticeGivenDays === 'number');
  let d = await api('qa.manager', 'POST', `/api/leave-requests/${rl2}/decide`, { comment: 'QA ok', password: PW });
  check('L2b', 'step 1 (branch manager) approves the annual leave', '200', `${d.status} ${JSON.stringify(d.json)}`, d.status === 200);
  d = await api('qa.owner', 'POST', `/api/leave-requests/${rl2}/decide`, { comment: 'QA ok', password: PW });
  check('L2c', 'step 2 (Owner) approves; ledger Usage -3 posted, balance 12 (15 - 3)', 'status Approved, daysApproved 3, balanceAfter 12',
    `${d.status} status=${d.json?.status} daysApproved=${d.json?.daysApproved} balanceAfter=${d.json?.balanceAfter}`, d.status === 200 && d.json?.status === 'Approved' && Number(d.json?.balanceAfter) === 12);

  /* L5: sick leave needs a certificate */
  const l5 = await api('qa.e5', 'POST', '/api/leave-requests', { employeeId: e5, leaveTypeId: 2, fromDate: '2026-08-24', toDate: '2026-08-24', reason: 'QA sick' });
  const rl5 = l5.json?.requestInstanceId; state('req.l5', rl5);
  d = await api('qa.manager', 'POST', `/api/leave-requests/${rl5}/decide`, { comment: 'QA', password: PW });
  check('L5a', 'sick leave cannot be approved without a certificate attachment', '400 "...requires a certificate..."', `${d.status} ${d.json?.error ?? d.text.slice(0, 120)}`, d.status === 400 && /certificate/i.test(d.json?.error ?? ''));
  const fd = new FormData();
  /* a 1x1 PNG: the API accepts only PDF/PNG/JPEG/WEBP */
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
  fd.append('file', new Blob([png], { type: 'image/png' }), 'qa-certificate.png');
  fd.append('caption', 'QA certificate');
  const up = await api('qa.e5', 'POST', `/api/requests/${rl5}/attachments`, fd);
  check('L5b', 'the requester attaches the certificate', '200/201', `${up.status} ${up.text.slice(0, 100)}`, up.status === 200 || up.status === 201);
  d = await api('qa.manager', 'POST', `/api/leave-requests/${rl5}/decide`, { comment: 'QA', password: PW });
  const d2 = await api('qa.owner', 'POST', `/api/leave-requests/${rl5}/decide`, { comment: 'QA', password: PW });
  check('L5c', 'with the attachment the sick leave is approved at both steps', '200 then 200 Approved', `${d.status} then ${d2.status} ${d2.json?.status}`, d.status === 200 && d2.status === 200 && d2.json?.status === 'Approved');

  /* L6: unpaid leave for E6 raised by HR on behalf */
  const l6 = await api('qa.hr', 'POST', '/api/leave-requests', { employeeId: e6, leaveTypeId: 3, fromDate: '2026-08-10', toDate: '2026-08-11', reason: 'QA unpaid' });
  const rl6 = l6.json?.requestInstanceId; state('req.l6', rl6);
  d = await api('qa.manager', 'POST', `/api/leave-requests/${rl6}/decide`, { comment: 'QA', password: PW });
  d = await api('qa.owner', 'POST', `/api/leave-requests/${rl6}/decide`, { comment: 'QA', password: PW });
  check('L6a', 'HR raises a 2-day unpaid leave for E6 (10-11 Aug); manager and owner approve', 'Approved', `${l6.status}/${d.status} ${d.json?.status}`, d.json?.status === 'Approved');

  /* L3: discretionary approval needs a note */
  const l3 = await api('qa.e1', 'POST', '/api/leave-requests', { employeeId: e1, leaveTypeId: 1, fromDate: '2026-09-28', toDate: '2026-09-30', reason: 'QA discretionary' });
  const rl3 = l3.json?.requestInstanceId; state('req.l3', rl3);
  d = await api('qa.manager', 'POST', `/api/leave-requests/${rl3}/decide`, { comment: 'QA', password: PW });
  const noNote = await api('qa.owner', 'POST', `/api/leave-requests/${rl3}/decide`, { password: PW, makeDiscretionary: true });
  check('L3a', 'discretionary approval WITHOUT a note is refused', '400 "A note is required..."', `${noNote.status} ${noNote.json?.error ?? noNote.text.slice(0, 120)}`, noNote.status === 400 && /note is required/i.test(noNote.json?.error ?? ''));
  const disc = await api('qa.owner', 'POST', `/api/leave-requests/${rl3}/decide`, { comment: 'QA discretionary grant', password: PW, makeDiscretionary: true });
  check('L3b', 'discretionary approval with a note: Usage -3 and Adjustment +3 (balance unchanged at 21)', 'Approved, discretionaryGranted true, balanceAfter 21',
    `${disc.status} status=${disc.json?.status} discretionaryGranted=${disc.json?.discretionaryGranted} balanceAfter=${disc.json?.balanceAfter}`, disc.status === 200 && disc.json?.discretionaryGranted === true && Number(disc.json?.balanceAfter) === 21);
  /* cancel / take back an approved leave */
  const wd = await api('qa.owner', 'POST', `/api/requests/${rl3}/steps/2/withdraw-decision`, { reason: 'QA withdraw', password: PW });
  check('L2d', 'taking back the final approval of an approved leave through the API (withdraw-decision)',
    'documented rule: refused - an approved request is closed and must be corrected elsewhere', `${wd.status} ${wd.json?.error ?? wd.text.slice(0, 160)}`, wd.status === 400 && /closed/i.test(wd.json?.error ?? ''));
  const lc = await api('qa.e5', 'POST', '/api/leave-requests', { employeeId: e5, leaveTypeId: 1, fromDate: '2026-09-21', toDate: '2026-09-22', reason: 'QA to cancel' });
  const rlc = lc.json?.requestInstanceId; state('req.lcancel', rlc);
  const cn = await api('qa.e5', 'POST', `/api/requests/${rlc}/cancel`, { reason: 'QA cancel' });
  check('L2e', 'the requester cancels a pending leave request', '200 status Cancelled', `${cn.status} ${cn.json?.status}`, cn.status === 200 && cn.json?.status === 'Cancelled');

  /* A11: exit permission for E1 on 13 Aug, 60 minutes */
  const ep = await api('qa.e1', 'POST', '/api/exit-permissions', { employeeId: e1, exitDate: '2026-08-13', fromTime: '14:05:00', toTime: '15:05:00', reason: 'QA exit permission' });
  const rep = ep.json?.requestInstanceId; state('req.exit', rep);
  check('A11a', 'E1 raises an exit permission 14:05-15:05 on 13 Aug (60 min)', '200, requestedMinutes 60', `${ep.status} ${JSON.stringify(ep.json).slice(0, 200)}`, ep.status === 200 && ep.json?.requestedMinutes === 60);
  d = await api('qa.hr', 'POST', `/api/exit-permissions/by-request/${rep}/decide`, { comment: 'QA', password: PW });
  const d3 = await api('qa.owner', 'POST', `/api/exit-permissions/by-request/${rep}/decide`, { comment: 'QA', password: PW });
  check('A11b', 'HR then Owner approve the exit permission', 'Approved', `${d.status}/${d3.status} ${d3.json?.status}`, d3.json?.status === 'Approved');

  /* ---- L7: deputy rules on the LEAVE_REQUEST chain (step 1 BranchManager, deputy role OperationsManager) ---- */
  const l7 = await api('qa.e5', 'POST', '/api/leave-requests', { employeeId: e5, leaveTypeId: 1, fromDate: '2026-10-05', toDate: '2026-10-06', reason: 'QA deputy test' });
  const rl7 = l7.json?.requestInstanceId; state('req.l7', rl7);
  const opsUser = ids.users['qa.ops'];
  const stepInst = sql(`SELECT RequestStepInstanceId FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId=${rl7} AND StepNo=1`);
  const canAct = () => sql(`SELECT workflow.fn_CanUserActOnStep(${stepInst}, ${opsUser})`);
  const refused = await api('qa.ops', 'POST', `/api/leave-requests/${rl7}/decide`, { comment: 'QA', password: PW });
  check('L7a', 'deputy (OperationsManager) is refused while the main approver is available and nothing is delegated',
    '403 "You are not the approver for this step."', `${refused.status} ${refused.json?.error ?? refused.text.slice(0, 100)} | fn_CanUserActOnStep=${canAct()}`, refused.status === 403 && canAct() === '0');
  const del = await api('qa.manager', 'POST', `/api/requests/${rl7}/steps/1/delegate-deputy`, {});
  check('L7b', 'main approver delegates the step to the deputy role -> deputy may act', '200, fn_CanUserActOnStep=1', `${del.status} ${del.text.slice(0, 80)} | fn_CanUserActOnStep=${canAct()}`, del.status === 200 && canAct() === '1');
  const undel = await api('qa.manager', 'DELETE', `/api/requests/${rl7}/steps/1/delegate-deputy`);
  check('L7c', 'main approver reclaims the step -> deputy refused again', '200/204, fn_CanUserActOnStep=0', `${undel.status} | fn_CanUserActOnStep=${canAct()}`, (undel.status === 200 || undel.status === 204) && canAct() === '0');
  /* the manager's own leave: he is the requester, so he never counts as available -> only the deputy can sign step 1 */
  const own = await api('qa.manager', 'POST', '/api/leave-requests', { employeeId: mgr, leaveTypeId: 1, fromDate: plusDays(0), toDate: plusDays(0), reason: 'QA manager away today' });
  const rown = own.json?.requestInstanceId; state('req.mgrleave', rown);
  const step1 = sql(`SELECT [Status] FROM workflow.REQUEST_STEP_INSTANCE WHERE RequestInstanceId=${rown} AND StepNo=1`);
  const byDep = await api('qa.ops', 'POST', `/api/leave-requests/${rown}/decide`, { comment: 'QA deputy signs', password: PW });
  check('L7d', 'requester never counts as available: manager\'s own request keeps step 1 Pending and the deputy signs it (signedAsDeputy)',
    'step1 Pending; deputy decide 200 signedAsDeputy=true', `step1=${step1}; ${byDep.status} signedAsDeputy=${byDep.json?.signedAsDeputy}`, step1 === 'Pending' && byDep.status === 200 && byDep.json?.signedAsDeputy === true);
  const ownOk = await api('qa.owner', 'POST', `/api/leave-requests/${rown}/decide`, { comment: 'QA', password: PW });
  check('L7e', 'owner approves the manager\'s leave (manager is now on approved leave today)', 'Approved', `${ownOk.status} ${ownOk.json?.status}`, ownOk.json?.status === 'Approved');
  const absent = sql(`SELECT workflow.fn_ApproverIsAbsent(${ids.users['qa.manager']})`);
  const depNow = await api('qa.ops', 'POST', `/api/leave-requests/${rl7}/decide`, { comment: 'QA deputy while manager away', password: PW });
  check('L7f', 'main approver on approved leave today -> deputy can act on E5\'s request without delegation',
    'fn_ApproverIsAbsent=1, decide 200 signedAsDeputy=true', `fn_ApproverIsAbsent=${absent}; ${depNow.status} signedAsDeputy=${depNow.json?.signedAsDeputy} ${depNow.json?.error ?? ''}`, absent === '1' && depNow.status === 200 && depNow.json?.signedAsDeputy === true);

  x1Summary('phase1');
}

/* ---------------------------------------------------------------- phase 2 ---- */
async function phase2() {
  loadIds();
  for (const u of ['qa.owner', 'qa.hr', 'qa.manager', 'qa.ops', 'qa.e1', 'qa.e5']) await login(u);
  const e1 = ids['QA E1'].emp;

  /* ---- A4 / A2 / A3 / A11: the anomaly queue (script 77) next to the exit-variance queue ---- */
  let ev = await api('qa.hr', 'GET', '/api/attendance/exit-variances?from=2026-08-01&to=2026-08-31');
  const rows = ev.json ?? [];
  const aug6v = rows.find((r) => r.employeeId === e1 && String(r.workDate).startsWith('2026-08-06'));
  const aug8 = rows.find((r) => r.employeeId === e1 && String(r.workDate).startsWith('2026-08-08'));
  let an = await api('qa.hr', 'GET', '/api/attendance/anomalies?from=2026-08-01&to=2026-08-31');
  const arows = an.json ?? [];
  const findAn = (day, type) => arows.find((r) => r.employeeId === e1 && String(r.workDate).startsWith(day) && r.type === type);
  const fmt = (r) => r ? `${r.type} ${r.minutes} min decision=${r.decision ?? 'undecided'} shift=${String(r.shiftStart).slice(11, 16)}-${String(r.shiftEnd).slice(11, 16)} punch=${String(r.punchIn).slice(11, 16)}-${String(r.punchOut).slice(11, 16)} fraction=${r.dayFraction}` : 'no row';
  const aug6 = findAn('2026-08-06', 'EarlyDeparture');
  check('A4a', 'E1 left 75 min early on 6 Aug -> an EarlyDeparture anomaly of 75 min (undecided, day covered) in GET /api/attendance/anomalies, and NOT a row in the exit-variance queue (script 77: only mid-day gaps stay there)',
    'anomaly EarlyDeparture 75 undecided, dayFraction 1, no exit-variance row for 6 Aug', `${an.status} ${fmt(aug6)}; exit-variance row for 6 Aug=${!!aug6v} (anomalies listed: ${arows.length})`,
    an.status === 200 && !!aug6 && aug6.minutes === 75 && aug6.decision == null && aug6.dayFraction === 1 && !aug6v);
  check('A4b', 'E1 75-minute mid-day exit on 8 Aug (out 10:00, in 11:15) -> variance row in the queue',
    'row present, ExitActualMinutes 45 (75 gap - 30 break absorbed), variance 45', aug8 ? `actual=${aug8.exitActualMinutes} approved=${aug8.exitApprovedMinutes} variance=${aug8.exitVarianceMinutes}` : 'no row', !!aug8 && aug8.exitActualMinutes === 45 && aug8.exitVarianceMinutes === 45);
  if (aug8) {
    const ap = await api('qa.hr', 'POST', `/api/attendance/${aug8.attendanceId}/exit-approval`, { exitApprovedMinutes: 60, hrNote: 'QA approve 60' });
    check('A4c', 'HR approves 60 minutes on the 8 Aug variance -> record updated, remaining variance = actual - approved',
      'exitApprovedMinutes 60, exitVarianceMinutes -15 (45-60)', `${ap.status} approved=${ap.json?.exitApprovedMinutes} variance=${ap.json?.exitVarianceMinutes} leave=${ap.json?.exitLeaveMinutes}`, ap.status === 200 && ap.json?.exitApprovedMinutes === 60 && ap.json?.exitVarianceMinutes === -15);
    const disp = await api('qa.hr', 'POST', `/api/attendance/${aug8.attendanceId}/exit-disposition`, { disposition: 'Ignore', hrNote: 'QA ignore' });
    ev = await api('qa.hr', 'GET', '/api/attendance/exit-variances?from=2026-08-01&to=2026-08-31');
    const still = (ev.json ?? []).some((r) => r.attendanceId === aug8.attendanceId);
    check('A4d', 'after HR disposition (Ignore) the row leaves the undecided queue', 'disposition 200, row gone', `${disp.status} ${disp.json?.exitVarianceDisposition}; still queued=${still}`, disp.status === 200 && !still);
    const r8 = (await api('qa.hr', 'GET', `/api/attendance?from=2026-08-08&to=2026-08-08&employeeId=${e1}`)).json?.[0];
    check('A4g', 'the approved 60 cover the 45-minute gap and the day is not manual: DayFraction 1.00, worked stays 465, isManual false (a reprocess keeps the decision)',
      'dayFraction 1, workedMinutes 465, isManual false', `fraction=${r8?.dayFraction} worked=${r8?.workedMinutes} covered=${r8?.coveredMinutes} isManual=${r8?.isManual}`,
      r8?.dayFraction === 1 && r8?.workedMinutes === 465 && r8?.isManual === false);
  }

  if (aug6) {
    /* the 6 Aug early departure is an anomaly; HR decides Deduct: the 75 minutes come off the day */
    const d6 = await api('qa.hr', 'POST', `/api/attendance/anomalies/${aug6.anomalyId}/decide`, { decision: 'Deduct', note: 'QA deduct' });
    const r6 = (await api('qa.hr', 'GET', `/api/attendance?from=2026-08-06&to=2026-08-06&employeeId=${e1}`)).json?.[0];
    check('A4f', 'HR decides Deduct on the 6 Aug EarlyDeparture anomaly (75 min, nothing approved) -> the 75 minutes come off the day: DayFraction 435/510 = 0.85, worked unchanged, decision Deducted',
      'decide 200 Deducted, dayFraction 0.85, workedMinutes 435', `${d6.status} ${d6.json?.decision ?? d6.json?.error}; fraction=${r6?.dayFraction} worked=${r6?.workedMinutes} covered=${r6?.coveredMinutes} earlyDeduct=${r6?.earlyDeductMinutes}`,
      d6.status === 200 && d6.json?.decision === 'Deducted' && r6?.dayFraction === 0.85 && r6?.workedMinutes === 435);
  }
  ev = await api('qa.hr', 'GET', '/api/attendance/exit-variances?from=2026-08-01&to=2026-08-31');
  const qaIds = new Set(Object.values(ids).filter((v) => v && typeof v === 'object' && 'emp' in v).map((v) => v.emp));
  const others = (ev.json ?? []).filter((r) => qaIds.has(r.employeeId));
  check('A4e', 'no other QA day is waiting in the exit-variance queue (an approved exit permission must not resurface as a variance after a reprocess)', 'queue empty for QA employees',
    others.length === 0 ? 'empty' : others.map((r) => `${r.fullName} ${String(r.workDate).slice(0, 10)} actual=${r.exitActualMinutes} approved=${r.exitApprovedMinutes} variance=${r.exitVarianceMinutes}`).join('; '), others.length === 0);
  for (const r of others) { await api('qa.hr', 'POST', `/api/attendance/${r.attendanceId}/exit-disposition`, { disposition: 'Ignore', hrNote: 'QA: cleared so payroll readiness can pass' }); }
  if (others.length) note(`A4e: ${others.length} leftover variance(s) dispositioned Ignore so the payroll case can run.`);

  /* A2 / A3: the late arrival at or beyond the tolerance is an anomaly; below it nothing */
  const aug4 = findAn('2026-08-04', 'LateArrival');
  const aug5 = arows.filter((r) => r.employeeId === e1 && String(r.workDate).startsWith('2026-08-05'));
  check('A2c', 'E1 in 07:12 on 4 Aug (tolerance 10) -> a LateArrival anomaly of 12 min, undecided, with the shift and punch times; in 07:08 on 5 Aug -> no anomaly row',
    'LateArrival 12 undecided shift 07:00-16:00 punch 07:12-16:00 for 4 Aug; 0 rows for 5 Aug', `4 Aug: ${fmt(aug4)}; 5 Aug rows=${aug5.length}`,
    !!aug4 && aug4.minutes === 12 && aug4.decision == null && String(aug4.shiftStart).slice(11, 16) === '07:00' && String(aug4.punchIn).slice(11, 16) === '07:12' && aug5.length === 0);

  /* A11: the approved exit permission resolves the early departure automatically */
  const aug13 = findAn('2026-08-13', 'EarlyDeparture');
  check('A11d', 'E1 left 55 min early on 13 Aug with a 60-min approved exit permission -> the EarlyDeparture anomaly is Excused automatically, note "covered by exit permission #N"',
    'EarlyDeparture 55 Excused, note names the permission, decidedBy empty (automatic)', `${fmt(aug13)} decidedBy=${aug13?.decidedBy ?? 'null'} note="${aug13?.note ?? ''}"`,
    !!aug13 && aug13.minutes === 55 && aug13.decision === 'Excused' && /exit permission #\d+/i.test(aug13.note ?? ''));

  /* ---- A6: the missing out punch is a MissingPunch anomaly: Excuse is refused, Correct enters the time through the manual path ---- */
  const aug10 = findAn('2026-08-10', 'MissingPunch');
  let man = { status: 0, json: null, text: '' };
  if (aug10) {
    const bad = await api('qa.hr', 'POST', `/api/attendance/anomalies/${aug10.anomalyId}/decide`, { decision: 'Excuse', note: 'QA' });
    check('A6a3', 'Excuse on a MissingPunch anomaly is refused in plain words (there is no time to excuse or deduct)', '400 "...missing punch..."', `${bad.status} ${bad.json?.error ?? bad.text.slice(0, 120)}`, bad.status === 400 && /missing punch/i.test(bad.json?.error ?? ''));
    man = await api('qa.hr', 'POST', `/api/attendance/anomalies/${aug10.anomalyId}/decide`, { decision: 'Correct', correctedTime: '2026-08-10T16:00:00', note: 'QA manual out punch' });
  } else {
    note('A6: no MissingPunch anomaly row for 10 Aug; A6b cannot correct through the decision.');
  }
  check('A6b', 'HR corrects the 10 Aug missing out punch to 16:00 (decide Correct -> stored through the manual path, usp_Attendance_ManualUpsert) -> IsManual, worked 510, no anomaly, decision Corrected',
    'decide 200 Corrected, workedMinutes 510, dayFraction 1, isManual true, hasAnomaly false', `${man.status} ${man.json?.decision ?? man.json?.error ?? man.text.slice(0, 120)} worked=${man.json?.workedMinutes} fraction=${man.json?.dayFraction} isManual=${man.json?.isManual} anomaly=${man.json?.hasAnomaly}`,
    man.status === 200 && man.json?.decision === 'Corrected' && man.json?.workedMinutes === 510 && man.json?.isManual === true && man.json?.hasAnomaly === false);
  const rp = await api('qa.hr', 'POST', '/api/attendance/reprocess?date=2026-08-10');
  const rec = await api('qa.hr', 'GET', `/api/attendance?from=2026-08-10&to=2026-08-10&employeeId=${e1}`);
  const r10 = (rec.json ?? [])[0];
  check('A6c', 'reprocessing 10 Aug does NOT overwrite the manual value', 'isManual true, workedMinutes 510, hasAnomaly false',
    `reprocess ${rp.status}; isManual=${r10?.isManual} worked=${r10?.workedMinutes} anomaly=${r10?.hasAnomaly}`, r10?.isManual === true && r10?.workedMinutes === 510 && r10?.hasAnomaly === false);

  /* ---- decide-all for the QA branch month, then HR changes the 4 Aug decision to Deduct (the payroll case P5a reads it) ---- */
  const all = await api('qa.hr', 'POST', '/api/attendance/anomalies/decide-all', { month: '2026-08', branchId: ids.branch, decision: 'Excuse', note: 'QA month end' });
  const r4a = (await api('qa.hr', 'GET', `/api/attendance?from=2026-08-04&to=2026-08-04&employeeId=${e1}`)).json?.[0];
  check('A2d', 'POST /api/attendance/anomalies/decide-all { month, branchId, decision: Excuse } decides the remaining undecided QA rows (the 4 Aug late arrival) and keeps full pay: 4 Aug DayFraction 1.00',
    'decided >= 1, skipped 0, 4 Aug dayFraction 1', `${all.status} decided=${all.json?.decided} skipped=${all.json?.skipped} days=${all.json?.daysRecomputed} ${all.json?.error ?? ''}; 4 Aug fraction=${r4a?.dayFraction}`,
    all.status === 200 && Number(all.json?.decided) >= 1 && Number(all.json?.skipped) === 0 && r4a?.dayFraction === 1);
  let dec4 = { status: 0, json: null, text: '' };
  if (aug4) dec4 = await api('qa.hr', 'POST', `/api/attendance/anomalies/${aug4.anomalyId}/decide`, { decision: 'Deduct', note: 'QA deduct 12 min' });
  const r4 = (await api('qa.hr', 'GET', `/api/attendance?from=2026-08-04&to=2026-08-04&employeeId=${e1}`)).json?.[0];
  check('A2e', 'HR changes the 4 Aug decision from Excused to Deduct -> the 12 late minutes come off the day: DayFraction 498/510 = 0.98, worked unchanged 498, lateDeductMinutes 12',
    'decide 200 Deducted, dayFraction 0.98, workedMinutes 498', `${dec4.status} ${dec4.json?.decision ?? dec4.json?.error}; fraction=${r4?.dayFraction} worked=${r4?.workedMinutes} lateDeduct=${r4?.lateDeductMinutes} covered=${r4?.coveredMinutes}`,
    dec4.status === 200 && dec4.json?.decision === 'Deducted' && r4?.dayFraction === 0.98 && r4?.workedMinutes === 498 && r4?.lateDeductMinutes === 12);
  an = await api('qa.hr', 'GET', `/api/attendance/anomalies?from=2026-08-01&to=2026-08-31&onlyUndecided=true&branchId=${ids.branch}`);
  const left = (an.json ?? []).filter((r) => qaIds.has(r.employeeId));
  check('A2f', 'no QA anomaly is left undecided for August (onlyUndecided=true&branchId filter; payroll readiness needs UndecidedAnomalies 0)', 'empty',
    left.length === 0 ? 'empty' : left.map((r) => `${r.fullName} ${String(r.workDate).slice(0, 10)} ${r.type} ${r.minutes}`).join('; '), an.status === 200 && left.length === 0);
  const rd = await api('qa.hr', 'GET', '/api/attendance/payroll-readiness?period=2026-08');
  check('RD1', 'GET /api/attendance/payroll-readiness exposes undecidedAnomalies (script 77) next to the six existing counters', 'undecidedAnomalies is a number',
    `${rd.status} undecidedAnomalies=${rd.json?.undecidedAnomalies} openAnomalies=${rd.json?.openAnomalies} variances=${rd.json?.undecidedExitVariances} ready=${rd.json?.isReady}`, rd.status === 200 && Number.isInteger(rd.json?.undecidedAnomalies));

  /* ---- payroll rules at the API ---- */
  const run = await api('qa.hr', 'POST', '/api/payroll/runs', { periodYearMonth: '2026-08', notes: 'QA August run', runType: 'Primary' });
  check('P9a', 'creating a second primary run for 2026-08 (an approved one already exists) is refused with the proc message',
    '400 "A primary run for 2026-08 already exists..."', `${run.status} ${run.json?.error ?? run.text.slice(0, 160)}`, run.status === 400 && /already exists/i.test(run.json?.error ?? ''));
  if (run.status === 200 && run.json?.payrollRunId) { note(`P9a: a run was created unexpectedly (id ${run.json.payrollRunId}); cleanup.sql removes runs whose Notes start with "QA ".`); }
  const runDef = await api('qa.hr', 'POST', '/api/payroll/runs', { periodYearMonth: '2026-08', notes: 'QA August run (no type)' });
  check('P9a2', 'POST /api/payroll/runs WITHOUT runType is treated as a primary run (the documented default)',
    '400 "A primary run for 2026-08 already exists..." (primary path)', `${runDef.status} ${runDef.json?.error ?? runDef.text.slice(0, 160)}`, runDef.status === 400 && /already exists/i.test(runDef.json?.error ?? ''));
  if (runDef.status === 200 && runDef.json?.payrollRunId) { note(`P9a2: a run was created unexpectedly (id ${runDef.json.payrollRunId}); cleanup.sql removes runs whose Notes start with "QA ".`); }
  const bulk1 = await api('qa.owner', 'POST', '/api/payroll/adjustments/bulk', { componentTypeId: ids.tips, amount: 50, currencyCode: 'USD', targetPeriod: '2026-08', reason: 'QA gift August', branchId: ids.branch });
  const bulk2 = await api('qa.owner', 'POST', '/api/payroll/adjustments/bulk', { componentTypeId: ids.tips, amount: 50, currencyCode: 'USD', targetPeriod: '2026-08', reason: 'QA gift August', branchId: ids.branch });
  const perEmp = sql(`SELECT COUNT(*) FROM payroll.PAYROLL_ADJUSTMENT WHERE Reason=N'QA gift August'`);
  const dup = sql(`SELECT COUNT(*) FROM (SELECT EmployeeId FROM payroll.PAYROLL_ADJUSTMENT WHERE Reason=N'QA gift August' GROUP BY EmployeeId HAVING COUNT(*)>1) x`);
  const active = sql(`SELECT COUNT(*) FROM hr.EMPLOYEE WHERE FullName LIKE N'QA %' AND IsDeleted=0 AND (TerminationDate IS NULL OR TerminationDate >= '2026-08-01')`);
  check('P7a', 'bulk gift to all active QA-branch employees in 2026-08: once per employee, second run adds nothing',
    `first=${active} employees, second=0, duplicates=0`, `first=${bulk1.json?.employeesGiven} (status ${bulk1.status}), second=${bulk2.json?.employeesGiven}, rows=${perEmp}, employees with >1 row=${dup}`,
    bulk1.status === 200 && Number(bulk1.json?.employeesGiven) === Number(active) && Number(bulk2.json?.employeesGiven) === 0 && dup === '0');
  const xr = await api('qa.hr', 'POST', '/api/exchange-rates', { fromCurrency: 'USD', toCurrency: 'LBP', rateType: 'Official', effectiveDate: '2026-08-01', rate: 89500 });
  check('P11a', 'a second Official USD->LBP rate is refused', '400 "...already exists..."', `${xr.status} ${xr.json?.error ?? xr.text.slice(0, 120)}`, xr.status === 400 && /already exists/i.test(xr.json?.error ?? ''));
  const xr2 = await api('qa.hr', 'POST', '/api/exchange-rates', { fromCurrency: 'EUR', toCurrency: 'USD', rateType: 'NonOfficial', effectiveDate: '2026-08-01', rate: 1.2345 });
  const xid = xr2.json?.exchangeRateId ?? xr2.json;
  const del = Number.isInteger(xid) ? await api('qa.hr', 'DELETE', `/api/exchange-rates/${xid}`) : { status: 'skipped' };
  check('P11b', 'the non-official rate type exists and can be stored (then deleted again)', 'create 200/201 then delete 204', `create ${xr2.status} id=${xid}, delete ${del.status}`, (xr2.status === 200 || xr2.status === 201) && (del.status === 204 || del.status === 200));
  const my = await api('qa.e1', 'GET', '/api/payslips/my-status');
  check('P10a', 'dashboard salary status for E1 before any QA run', 'no payslip / "not prepared" (204 or null)', `${my.status} ${my.text.slice(0, 120) || '(empty)'}`, my.status === 204 || my.status === 404 || my.json === null || my.text === '' || my.json?.statusCode == null);

  /* ---- bookings: the public API is the website contract (mokanco-lb/src/scripts/api.ts):
          base /api/public/booking, minutes from midnight, {error, code} refusals, Origin gated ---- */
  const room = ids.room;
  const ORIGIN = 'http://localhost:4321';                                 // listed in core.SETTING BookingCorsOrigins
  const pub = (method, path, body, headers = { Origin: ORIGIN }) => api(null, method, path, body, { headers });
  const idOf = (ref) => (ref ? +sql(`SELECT BookingId FROM booking.BOOKING WHERE BookingRef=${q(ref)}`) : 0);
  const hold = (id) => sql(`UPDATE core.EMAIL_OUTBOX SET [Status]='QaHeld' WHERE BookingId=${id} AND [Status]='Pending'`);
  const kinds = (id) => sql(`SELECT ISNULL(STRING_AGG(MailKind + '/' + Channel, ','), '') FROM core.EMAIL_OUTBOX WHERE BookingId=${id}`);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const isRef = (ref) => /^MC-[A-Z0-9]{8}$/.test(ref ?? '');
  const guest = (n, date, startMin, endMin, extra = {}) => ({ roomCode: 'qa-room', date, startMin, endMin, persons: 2, name: `QA Guest ${n}`, phone: `+9617000000${n.replace(/\D/g, '').slice(-1) || '1'}`, email: `qa-guest-${n.toLowerCase().replace(/[^a-z0-9]+/g, '-')}@example.invalid`, notes: null, addonIds: [], ...extra });
  /* NOTE: the public WRITE rate limit is 5 per minute per IP (public-booking-write). Creates, cancels
     and releases below are grouped so that no minute sees more than five; the sleep before B6 is that. */
  const cat = await pub('GET', '/api/public/booking/catalog');
  const qaRoom = cat.json?.rooms?.find((r) => r.code === 'qa-room');
  check('B0a', 'GET /api/public/booking/catalog (Origin allowed) -> rooms with hours in minutes, rules, timeZone Asia/Beirut', 'qa-room present with openMin 540 / closeMin 1500 x7, rules.localNow ISO with offset',
    `${cat.status} timeZone=${cat.json?.timeZone} qa-room hours=${JSON.stringify(qaRoom?.hours?.[0])} n=${qaRoom?.hours?.length} localNow=${cat.json?.rules?.localNow} addons=${JSON.stringify(qaRoom?.addons)} discounts=${JSON.stringify(qaRoom?.discounts)}`,
    cat.status === 200 && cat.json?.timeZone === 'Asia/Beirut' && qaRoom?.hours?.length === 7 && qaRoom.hours.every((h) => h.openMin === 540 && h.closeMin === 1500 && !h.isClosed) && /\+0[23]:00$/.test(cat.json?.rules?.localNow ?? ''));
  const d1 = plusDays(10);
  /* B8: /hubs/booking. Three listeners are opened BEFORE anything changes: staff with a booking permission (qa.hr),
     an authenticated user without one (qa.e1) and, once the reference exists, the website's anonymous guest. */
  const hubStaff = await hubConnect(tokens.get('qa.hr'));
  const hubNoPerm = await hubConnect(tokens.get('qa.e1'));
  const b1 = await pub('POST', '/api/public/booking', guest('B1', d1, 600, 720));
  const b1Id = idOf(b1.json?.ref);
  if (b1Id) { hold(b1Id); state('booking.b1', b1Id); }
  check('B1a', 'public create on a free slot -> 201 Pending, times echoed in minutes with Beirut moments', '201 status Pending startMin 600 endMin 720 startAt ...T10:00:00+03:00', `${b1.status} ${JSON.stringify(b1.json).slice(0, 220)}`,
    b1.status === 201 && b1.json?.status === 'Pending' && b1.json?.startMin === 600 && b1.json?.endMin === 720 && b1.json?.timeZone === 'Asia/Beirut' && /T10:00:00\+0[23]:00$/.test(b1.json?.startAt ?? ''));
  const refDb = b1Id ? sql(`SELECT BookingRef FROM booking.BOOKING WHERE BookingId=${b1Id}`) : '';
  check('B1d', 'the public create response carries the booking reference (MC-...) the guest is told to keep', 'ref MC-XXXXXXXX equal to the DB row', `ref=${b1.json?.ref}; DB ref=${refDb}; keys=${Object.keys(b1.json ?? {}).join(',')}`, isRef(b1.json?.ref) && b1.json.ref === refDb);
  check('B3a', 'creation queues Request + StaffAlert e-mails only (no Confirmation) - written by the DB trigger, not the API', 'Request/Email,StaffAlert/Email', kinds(b1Id), /Request\/Email/.test(kinds(b1Id)) && /StaffAlert\/Email/.test(kinds(b1Id)) && !/Confirmation/.test(kinds(b1Id)));
  const b1b = await pub('POST', '/api/public/booking', guest('B1 again', d1, 600, 720, { phone: '+96170000001' }));
  const b1bId = idOf(b1b.json?.ref); if (b1bId) hold(b1bId);
  check('B1b', 'identical second create -> 409 slot_taken with the procedure\'s sentence', '409 {"code":"slot_taken"}', `${b1b.status} ${b1b.text.slice(0, 120)}`, b1b.status === 409 && b1b.json?.code === 'slot_taken' && /just taken/.test(b1b.json?.error ?? ''));
  const d2 = plusDays(11);
  const b2 = await pub('POST', '/api/public/booking', guest('B2', d2, 1320, 1500));
  let b2Id = idOf(b2.json?.ref);
  if (b2Id) { hold(b2Id); state('booking.b2', b2Id); }
  check('B2a', 'public create 22:00-01:00 (startMin 1320, endMin 1500) succeeds', '201, hours 3, endAt next day 01:00 with offset', `${b2.status} ${b2.json?.error ?? JSON.stringify(b2.json).slice(0, 200)}`,
    b2.status === 201 && Number(b2.json?.hours) === 3 && b2.json?.endMin === 1500 && /T01:00:00\+0[23]:00$/.test(b2.json?.endAt ?? ''));
  if (b2.status !== 201) {
    /* the procedure accepts it; create the same booking through it so the availability read can be checked */
    sql(`EXEC booking.usp_Booking_Create @RoomId=${room}, @BookDate='${d2}', @StartTime='22:00', @EndTime='01:00', @Persons=2, @GuestName=N'QA Guest B2 (proc)', @GuestPhone='+96170000002', @Source='Manual'`);
    const id2 = sql(`SELECT MAX(BookingId) FROM booking.BOOKING WHERE GuestName=N'QA Guest B2 (proc)'`); if (id2) { hold(+id2); state('booking.b2', id2); b2Id = +id2; }
    note('B2: the API refused the after-midnight end, so the booking was created through usp_Booking_Create (Manual) for the availability check.');
  }
  const dayB2 = await pub('GET', `/api/public/booking/availability?room=qa-room&date=${d2}`);
  check('B2b', 'GET availability?room&date shows the 22:00-01:00 slot as taken, in minutes', 'taken contains {startMin 1320, endMin 1500}', `${dayB2.status} taken=${JSON.stringify(dayB2.json?.taken)} free=${JSON.stringify(dayB2.json?.free)}`,
    dayB2.status === 200 && (dayB2.json?.taken ?? []).some((t) => t.startMin === 1320 && t.endMin === 1500));
  check('B2e', 'day availability reports the room\'s opening hours in minutes (QA room 09:00-01:00) and the free time up to the taken slot', 'openMin 540, closeMin 1500, isClosed false, a free range ending at 1320, earliestStartMin 540',
    `openMin=${dayB2.json?.openMin} closeMin=${dayB2.json?.closeMin} isClosed=${dayB2.json?.isClosed} earliest=${dayB2.json?.earliestStartMin} free=${JSON.stringify(dayB2.json?.free)} turnaround=${dayB2.json?.turnaroundMinutes}`,
    dayB2.json?.openMin === 540 && dayB2.json?.closeMin === 1500 && dayB2.json?.isClosed === false && dayB2.json?.earliestStartMin === 540 && (dayB2.json?.free ?? []).some((f) => f.endMin === 1320));
  const monthB2 = await pub('GET', `/api/public/booking/availability/month?room=qa-room&month=${d2.slice(0, 7)}`);
  const dayWord = monthB2.json?.days?.find((d) => d.date === d2)?.status;
  check('B2f', 'GET availability/month?room&month paints the day with the 22:00-01:00 booking as partial and a past day as past', `${d2} partial; ${plusDays(-1).slice(0, 7) === d2.slice(0, 7) ? 'yesterday past' : 'first of month past-or-open'}`,
    `${monthB2.status} month=${monthB2.json?.month} ${d2}=${dayWord} first=${monthB2.json?.days?.[0]?.status} n=${monthB2.json?.days?.length}`, monthB2.status === 200 && dayWord === 'partial' && monthB2.json?.days?.length >= 28);
  const quote = await pub('POST', '/api/public/booking/quote', { roomCode: 'qa-room', date: d2, startMin: 600, endMin: 780, addonIds: [ids.addon] });
  check('B5d', 'POST quote for 3 h + the 15 add-on prices the room with the 10 % discount and the add-on undiscounted', 'roomGross 60, discountAmount 6, roomTotal 54, addonTotal 15, total 69, depositPercent 20, deposit 13.80',
    `${quote.status} ${JSON.stringify(quote.json).slice(0, 300)}`, quote.status === 200 && Number(quote.json?.roomGross) === 60 && Number(quote.json?.discountAmount) === 6 && Number(quote.json?.addonTotal) === 15 && Number(quote.json?.total) === 69 && Number(quote.json?.deposit) === 13.8);
  const hubNeg = await fetch(`${API}/hubs/booking/negotiate?negotiateVersion=1`, { method: 'POST', headers: { Origin: ORIGIN } });
  const hubNegBad = await fetch(`${API}/hubs/booking/negotiate?negotiateVersion=1`, { method: 'POST', headers: { Origin: 'https://evil.example' } });
  check('B8a', 'POST /hubs/booking/negotiate is anonymous and answers CORS from BookingCorsOrigins WITH credentials (no wildcard); an unlisted origin gets no CORS grant',
    `200, Access-Control-Allow-Origin ${ORIGIN}, Allow-Credentials true; evil origin: no Allow-Origin`,
    `${hubNeg.status} acao=${hubNeg.headers.get('access-control-allow-origin')} acac=${hubNeg.headers.get('access-control-allow-credentials')}; evil acao=${hubNegBad.headers.get('access-control-allow-origin')}`,
    hubNeg.status === 200 && hubNeg.headers.get('access-control-allow-origin') === ORIGIN && hubNeg.headers.get('access-control-allow-credentials') === 'true' && !hubNegBad.headers.get('access-control-allow-origin'));
  const hubGuest = await hubConnect(null), hubStranger = await hubConnect(null);
  const watchOk = hubGuest.ok ? await hubGuest.invoke('WatchBooking', b1.json?.ref) : { error: 'no connection' };
  const watchBad = hubStranger.ok ? await hubStranger.invoke('WatchBooking', 'MC-ZZZZZZZZ') : { error: 'no connection' };
  const watchGroup = hubStranger.ok ? await hubStranger.invoke('WatchBooking', 'staff') : { error: 'no connection' };
  check('B8b', 'an anonymous connection joins "booking:{ref}" only with a real MC- reference (WatchBooking, the website\'s call); an unknown reference or a group name is refused',
    'real ref: completed without error; MC-ZZZZZZZZ and "staff": error not_found', `real=${watchOk.error ?? 'ok'}; unknown=${watchBad.error}; "staff"=${watchGroup.error}`,
    hubGuest.ok && !watchOk.error && /not_found/.test(watchBad.error ?? '') && /not_found/.test(watchGroup.error ?? ''));
  const created = hubStaff.ok ? await hubStaff.waitFor((e) => e.target === 'BookingChanged' && e.arg?.ref === b1.json?.ref && e.arg?.status === 'Pending') : null;
  check('B8c', 'the public create is announced to group "staff": BookingChanged { bookingId, ref, status, roomCode, date, startMin, endMin, guestName, source }',
    `BookingChanged ref ${b1.json?.ref} Pending Website qa-room ${d1} 600-720 with bookingId ${b1Id}`, JSON.stringify(created?.arg ?? null),
    !!created && created.arg.bookingId === b1Id && created.arg.source === 'Website' && created.arg.roomCode === 'qa-room' && created.arg.date === d1 && created.arg.startMin === 600 && created.arg.endMin === 720 && !!created.arg.guestName);
  const conf = await api('qa.hr', 'PUT', `/api/bookings/${b1Id}/status`, { status: 'Confirmed' });
  const gotGuest = hubGuest.ok ? await hubGuest.waitFor((e) => e.target === 'BookingStatus' && e.arg?.status === 'Confirmed') : null;
  const gotStaff = hubStaff.ok ? await hubStaff.waitFor((e) => e.target === 'BookingChanged' && e.arg?.ref === b1.json?.ref && e.arg?.status === 'Confirmed') : null;
  check('B8d', 'staff confirm -> the guest\'s page hears BookingStatus { ref, status, refundStatus, paid, balance } and staff hear BookingChanged Confirmed',
    `guest: ref ${b1.json?.ref} Confirmed with paid and balance; staff: Confirmed`, `guest=${JSON.stringify(gotGuest?.arg ?? null)} staff=${gotStaff?.arg?.status ?? 'nothing'}`,
    !!gotGuest && gotGuest.arg.ref === b1.json?.ref && 'refundStatus' in gotGuest.arg && typeof gotGuest.arg.paid === 'number' && typeof gotGuest.arg.balance === 'number' && !('guestName' in gotGuest.arg) && !!gotStaff);
  check('B8e', 'nobody else hears it: an authenticated user without BOOKING_VIEW/MANAGE (qa.e1) and an anonymous connection that watches nothing receive no booking message',
    '0 messages each', `no-permission user=${hubNoPerm.events.length} (connected=${hubNoPerm.ok}); anonymous stranger=${hubStranger.events.length}`, hubNoPerm.ok && hubNoPerm.events.length === 0 && hubStranger.events.length === 0);
  for (const h of [hubStaff, hubNoPerm, hubGuest, hubStranger]) h.close();
  if (b1Id) hold(b1Id);
  check('B3b', 'staff confirm in HRMS -> Confirmed and a Confirmation e-mail is queued only now (by the trigger)', 'status Confirmed; outbox gains Confirmation/Email', `${conf.status} ${conf.json?.status}; outbox=${kinds(b1Id)}`, conf.status === 200 && conf.json?.status === 'Confirmed' && /Confirmation\/Email/.test(kinds(b1Id)));
  /* B4: staff cancel with a payment on file, cancelled-by Staff vs Guest, refunds through the API */
  const d3 = plusDays(12), d4 = plusDays(13), d6 = plusDays(15);
  const m1 = await api('qa.hr', 'POST', '/api/bookings/manual', { roomId: room, bookDate: d3, startTime: '14:00:00', endTime: '16:00:00', persons: 2, guestName: 'QA Guest B4a', guestPhone: '+96170000004' });
  const m2 = await api('qa.hr', 'POST', '/api/bookings/manual', { roomId: room, bookDate: d4, startTime: '14:00:00', endTime: '16:00:00', persons: 2, guestName: 'QA Guest B4b', guestPhone: '+96170000005' });
  const m3 = await api('qa.hr', 'POST', '/api/bookings/manual', { roomId: room, bookDate: d6, startTime: '14:00:00', endTime: '16:00:00', persons: 2, guestName: 'QA Guest B4c', guestPhone: '+96170000008' });
  for (const m of [m1, m2, m3]) if (m.json?.bookingId) hold(m.json.bookingId);
  state('booking.b4a', m1.json?.bookingId); state('booking.b4b', m2.json?.bookingId); state('booking.b4c', m3.json?.bookingId);
  check('B4m', 'POST /api/bookings/manual still takes roomId + times and now surfaces the reference, hours, discount and deposit percent', '200 bookingId, bookingRef MC-..., status Confirmed, hours 2',
    `${m1.status} ${JSON.stringify(m1.json).slice(0, 220)}`, m1.status === 200 && isRef(m1.json?.bookingRef) && m1.json?.status === 'Confirmed' && Number(m1.json?.hours) === 2);
  const pay1 = await api('qa.hr', 'POST', `/api/bookings/${m1.json?.bookingId}/payments`, { paymentMethodId: 1, amount: 30, reference: 'QA cash' });
  const pay2 = await api('qa.hr', 'POST', `/api/bookings/${m2.json?.bookingId}/payments`, { paymentMethodId: 1, amount: 30, reference: 'QA cash' });
  const pay3 = await api('qa.hr', 'POST', `/api/bookings/${m3.json?.bookingId}/payments`, { paymentMethodId: 1, amount: 30, reference: 'QA cash' });
  const cancel = await api('qa.hr', 'PUT', `/api/bookings/${m1.json?.bookingId}/status`, { status: 'Cancelled', cancelledBy: 'Staff', note: 'QA staff cancel' });
  if (m1.json?.bookingId) hold(m1.json.bookingId);
  const b4aRow = m1.json?.bookingId ? sql(`SELECT CONCAT(CancelledBy, '|', RefundAmount, '|', RefundStatus, '|', DepositDue) FROM booking.BOOKING WHERE BookingId=${m1.json.bookingId}`) : '';
  const [cb, ra, rs, dd] = b4aRow.split('|');
  check('B4a', 'staff cancel {status, cancelledBy Staff, note} of a booking with 30 paid (total 40) -> refund due = everything paid (30); the response is the booking row', 'cancelledBy Staff, refundAmount 30.00, refundStatus Due (response and DB)',
    `manual ${m1.status} pay ${pay1.status}/${pay2.status}/${pay3.status}; cancel ${cancel.status} response cancelledBy=${cancel.json?.cancelledBy} refundAmount=${cancel.json?.refundAmount} refundStatus=${cancel.json?.refundStatus}; DB cancelledBy=${cb} refundAmount=${ra} refundStatus=${rs} (deposit ${dd})`,
    cancel.status === 200 && cancel.json?.status === 'Cancelled' && cancel.json?.cancelledBy === 'Staff' && Number(cancel.json?.refundAmount) === 30 && cancel.json?.refundStatus === 'Due' && cb === 'Staff' && Number(ra) === 30 && rs === 'Due');
  const dep3 = Number(sql(`SELECT DepositDue FROM booking.BOOKING WHERE BookingId=${m3.json?.bookingId ?? 0}`) || 0);
  const cancelG = await api('qa.hr', 'PUT', `/api/bookings/${m3.json?.bookingId}/status`, { status: 'Cancelled', cancelledBy: 'Guest', reason: 'QA guest asked by phone' });
  if (m3.json?.bookingId) hold(m3.json.bookingId);
  check('B4e', 'staff cancel as cancelledBy Guest (the guest rang; `reason` still accepted as the note) -> refund = paid - deposit', `cancelledBy Guest, refundAmount ${(30 - dep3).toFixed(2)} (30 paid - ${dep3.toFixed(2)} deposit), refundStatus Due`,
    `${cancelG.status} cancelledBy=${cancelG.json?.cancelledBy} refundAmount=${cancelG.json?.refundAmount} refundStatus=${cancelG.json?.refundStatus} depositDue=${cancelG.json?.depositDue} ${cancelG.json?.error ?? ''}`,
    cancelG.status === 200 && cancelG.json?.cancelledBy === 'Guest' && Number(cancelG.json?.refundAmount) === 30 - dep3 && cancelG.json?.refundStatus === 'Due');
  const r1 = await api('qa.hr', 'POST', `/api/bookings/${m1.json?.bookingId}/refunds`, { amount: 10, method: 'Cash', reference: 'QA partial refund' });
  const r2 = await api('qa.hr', 'POST', `/api/bookings/${m1.json?.bookingId}/refunds`, { amount: 20, method: 1, reference: 'QA rest' });
  if (m1.json?.bookingId) hold(m1.json.bookingId);
  const refundLines = (r) => (r.json?.payments ?? []).filter((p) => p.isRefund).map((p) => `${p.amount}/${p.method}`).join(',');
  check('B4c', 'POST /api/bookings/{id}/refunds (method by name "Cash", then by id 1) on the staff-cancelled booking flips RefundStatus Due -> Partial (10) -> Refunded (30) and lists the negative lines with isRefund',
    'after 10: Partial; after 30: Refunded, refundedUtc set, payments -10/Cash,-20/Cash', `${r1.status} ${r1.json?.refundStatus} (${r1.json?.methodResolvedBy}) lines=${refundLines(r1)}; ${r2.status} ${r2.json?.refundStatus} (${r2.json?.methodResolvedBy}) refundedUtc=${r2.json?.refundedUtc} lines=${refundLines(r2)} ${r1.json?.error ?? ''} ${r2.json?.error ?? ''}`,
    r1.status === 200 && r1.json?.refundStatus === 'Partial' && r1.json?.methodResolvedBy === 'name' && r2.status === 200 && r2.json?.refundStatus === 'Refunded' && r2.json?.methodResolvedBy === 'id' && !!r2.json?.refundedUtc && refundLines(r2) === '-10/Cash,-20/Cash');
  const r3 = await api('qa.hr', 'POST', `/api/bookings/${m1.json?.bookingId}/refunds`, { amount: 1, method: 'Cash' });
  check('B4f', 'a refund past what was paid is refused with the procedure\'s sentence', '400 "Refund exceeds what was paid"', `${r3.status} ${r3.text.slice(0, 120)}`, r3.status === 400 && /exceeds what was paid/.test(r3.json?.error ?? ''));
  const g1 = await api('qa.hr', 'GET', `/api/bookings/${m1.json?.bookingId}`);
  check('B4g', 'GET /api/bookings/{id} carries refundAmount, refundStatus, refundedUtc, cancelledBy and the payment lines with isRefund', 'status Cancelled, cancelledBy Staff, refundAmount 30, refundStatus Refunded, 3 payments (1 paid + 2 refunds)',
    `${g1.status} status=${g1.json?.status} cancelledBy=${g1.json?.cancelledBy} refundAmount=${g1.json?.refundAmount} refundStatus=${g1.json?.refundStatus} refundedUtc=${g1.json?.refundedUtc} payments=${JSON.stringify((g1.json?.payments ?? []).map((p) => [p.amount, p.isRefund]))}`,
    g1.status === 200 && g1.json?.cancelledBy === 'Staff' && Number(g1.json?.refundAmount) === 30 && g1.json?.refundStatus === 'Refunded' && !!g1.json?.refundedUtc && (g1.json?.payments ?? []).filter((p) => p.isRefund).length === 2 && (g1.json?.payments ?? []).filter((p) => !p.isRefund).length === 1);
  /* B5: 3 hours -> 10 % discount on the room only; deposit on the discounted total (incl. add-on) */
  const d5 = plusDays(14);
  const b5 = await pub('POST', '/api/public/booking', guest('B5', d5, 600, 780, { phone: '+96170000006', addonIds: [ids.addon] }));
  const b5Id = idOf(b5.json?.ref);
  if (b5Id) { hold(b5Id); state('booking.b5', b5Id); }
  const b5Row = b5Id ? sql(`SELECT CONCAT(DiscountPercent, '|', DiscountAmount, '|', TotalAmount, '|', DepositPercent, '|', DepositDue) FROM booking.BOOKING WHERE BookingId=${b5Id}`) : '';
  const [dp, da, ta, depP, depD] = b5Row.split('|');
  check('B5a', '3-hour booking at 20/h with a 15 fixed add-on and a 10 % discount from 3 h: discount 6 on the room only, total 69 - in the response and in the row',
    'discountAmount 6.00, total 69.00', `${b5.status} response total=${b5.json?.total} discountPercent=${b5.json?.discountPercent} discountAmount=${b5.json?.discountAmount}; DB discount%=${dp} discount=${da} total=${ta} ${b5.json?.error ?? ''}`, b5.status === 201 && Number(b5.json?.discountAmount) === 6 && Number(b5.json?.total) === 69 && Number(da) === 6 && Number(ta) === 69);
  check('B5b', 'deposit computed on the discounted total with the lead-time tier (>=168 h -> 20 %) - response carries deposit and depositPercent', 'depositPercent 20, deposit 13.80',
    `response deposit=${b5.json?.deposit} depositPercent=${b5.json?.depositPercent}; DB depositPercent=${depP} depositDue=${depD}`, Number(b5.json?.depositPercent) === 20 && Number(b5.json?.deposit) === 13.8 && Number(depP) === 20 && Number(depD) === 13.8);
  /* B6: the guest cancels online with the phone number; B7: the access filter and the pause switch */
  const d7 = plusDays(17);
  const b6 = await pub('POST', '/api/public/booking', guest('B6', d7, 600, 720, { phone: '+96170000007' }));   // 5th public write this minute
  const b6Id = idOf(b6.json?.ref);
  if (b6Id) { hold(b6Id); state('booking.b6', b6Id); }
  state('setting.BookingWebsiteEnabled', '1');                                     // cleanup.sql restores it even if this run is interrupted
  sql(`UPDATE core.SETTING SET SettingValue='0' WHERE SettingKey='BookingWebsiteEnabled'`);
  note('B6/B7: waiting 61 s for the public write rate-limit window (5/min) and the settings cache (60 s) to roll over.');
  await sleep(61000);
  let paused = null;
  for (let waited = 0; waited <= 30; waited += 5) { paused = await pub('POST', '/api/public/booking/quote', { roomCode: 'qa-room', date: d7, startMin: 600, endMin: 720, addonIds: [] }); if (paused.status === 503) break; await sleep(5000); }
  const catPaused = await pub('GET', '/api/public/booking/catalog');
  const createPaused = await pub('POST', '/api/public/booking', guest('B7', d7, 780, 840));
  const createPausedId = idOf(createPaused.json?.ref); if (createPausedId) hold(createPausedId);
  check('B7b', 'BookingWebsiteEnabled=0 -> POST quote and POST create answer 503 paused; GET catalog stays up and says websiteEnabled false', '503 {"code":"paused"} x2; catalog 200 websiteEnabled=false',
    `quote ${paused?.status} ${paused?.text?.slice(0, 80)}; create ${createPaused.status} ${createPaused.json?.code}; catalog ${catPaused.status} websiteEnabled=${catPaused.json?.rules?.websiteEnabled}`,
    paused?.status === 503 && paused?.json?.code === 'paused' && createPaused.status === 503 && createPaused.json?.code === 'paused' && catPaused.status === 200 && catPaused.json?.rules?.websiteEnabled === false);
  sql(`UPDATE core.SETTING SET SettingValue='1' WHERE SettingKey='BookingWebsiteEnabled'`);
  const wrongPhone = await pub('POST', `/api/public/booking/${b6.json?.ref}/cancel`, { phone: '70 999 999' });
  check('B6b', 'POST {ref}/cancel with a phone whose last 8 digits do not match -> 400 invalid_input, booking untouched', '400 {"code":"invalid_input"}; status still Pending',
    `${wrongPhone.status} ${wrongPhone.text.slice(0, 100)}; DB status=${b6Id ? sql(`SELECT [Status] FROM booking.BOOKING WHERE BookingId=${b6Id}`) : 'n/a'}`, wrongPhone.status === 400 && wrongPhone.json?.code === 'invalid_input' && (b6Id ? sql(`SELECT [Status] FROM booking.BOOKING WHERE BookingId=${b6Id}`) === 'Pending' : false));
  const cancelled = await pub('POST', `/api/public/booking/${b6.json?.ref}/cancel`, { phone: '70 000 007' });
  if (b6Id) hold(b6Id);
  check('B6a', 'POST {ref}/cancel {phone} inside the window (the phone spelled without the country code) -> the recap with the refund figures', 'ref, status Cancelled, cancelledBy Guest, refundAmount 0 (nothing paid), refundStatus None',
    `${cancelled.status} ref=${cancelled.json?.ref} status=${cancelled.json?.status} cancelledBy=${cancelled.json?.cancelledBy} refundAmount=${cancelled.json?.refundAmount} refundStatus=${cancelled.json?.refundStatus} ${cancelled.json?.error ?? ''}`,
    cancelled.status === 200 && cancelled.json?.ref === b6.json?.ref && cancelled.json?.status === 'Cancelled' && cancelled.json?.cancelledBy === 'Guest' && Number(cancelled.json?.refundAmount) === 0 && cancelled.json?.refundStatus === 'None');
  const recap = await pub('GET', `/api/public/booking/${b6.json?.ref}`);
  check('B6c', 'GET {ref} recap after the cancellation: status, minutes, "First L." name, money - and never the phone or e-mail', 'status Cancelled, canCancelOnline false, guestName "QA B.", no guestPhone/guestEmail/email/phone keys, addons []',
    `${recap.status} ${JSON.stringify(recap.json).slice(0, 260)}`,
    recap.status === 200 && recap.json?.status === 'Cancelled' && recap.json?.canCancelOnline === false && recap.json?.guestName === 'QA B.' && recap.json?.startMin === 600 && recap.json?.endMin === 720 && !Object.keys(recap.json ?? {}).some((k) => /phone|email/i.test(k)));
  const evil = await pub('GET', '/api/public/booking/catalog', undefined, { Origin: 'http://evil.example' });
  const noOrigin = await pub('GET', '/api/public/booking/catalog', undefined, {});
  const keyOff = await pub('GET', '/api/public/booking/catalog', undefined, { 'X-Booking-Key': 'anything' });
  check('B7a', 'an origin not in BookingCorsOrigins, no origin at all, or a key while BookingApiKey is empty -> 401 unauthorized', '401 {"code":"unauthorized"} x3',
    `${evil.status} ${evil.json?.code}; ${noOrigin.status} ${noOrigin.json?.code}; ${keyOff.status} ${keyOff.json?.code}`, [evil, noOrigin, keyOff].every((r) => r.status === 401 && r.json?.code === 'unauthorized'));
  const preflight = await fetch(`${API}/api/public/booking/quote`, { method: 'OPTIONS', headers: { Origin: ORIGIN, 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type' } });
  check('B7c', 'CORS preflight from the site origin is answered from BookingCorsOrigins (DB setting), GET/POST only', '204 Access-Control-Allow-Origin http://localhost:4321',
    `${preflight.status} acao=${preflight.headers.get('access-control-allow-origin')} methods=${preflight.headers.get('access-control-allow-methods')}`, (preflight.status === 204 || preflight.status === 200) && preflight.headers.get('access-control-allow-origin') === ORIGIN);
  const verify = await pub('GET', '/api/public/booking/verify?ref=MC-ABCD1234');
  check('B7d', 'GET verify?ref= answers 501 not_implemented (step 2)', '501 {"code":"not_implemented"}', `${verify.status} ${verify.json?.code}`, verify.status === 501 && verify.json?.code === 'not_implemented');
  state('booking.routes', `catalog=${cat.status},availability=${dayB2.status},quote=${quote.status},byref=${recap.status},create=${b1.status},cancel=${cancelled.status}`);

  x1Summary('phase2');
}

function x1Summary(tag) {
  const bad = refusals.filter((r) => r.status >= 400 && !looksClean(r.text));
  check(`X1-${tag}`, `every error body returned during ${tag} is plain text (no SQL constraint text / stack trace)`,
    '0 leaking responses', bad.length === 0 ? `0 of ${refusals.filter((r) => r.status >= 400).length} error responses leak` : bad.map((b) => `${b.status} ${b.path}: ${b.text.slice(0, 120).replace(/\s+/g, ' ')}`).join(' || '), bad.length === 0);
  const nonJson = refusals.filter((r) => r.status >= 400 && r.status !== 401 && r.status !== 403 && r.status !== 404 && !/^\s*\{/.test(r.text));
  if (nonJson.length) note(`X1 ${tag}: ${nonJson.length} error response(s) without a JSON body: ${nonJson.map((b) => `${b.status} ${b.path}`).join('; ')}`);
}

const run = phase === 'phase1' ? phase1 : phase2;
run().then(() => { console.log(`API ${phase} done, ${failures} failure(s)`); }).catch((e) => { console.error('API tests crashed:', e); process.exit(1); });
