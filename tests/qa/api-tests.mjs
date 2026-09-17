#!/usr/bin/env node
/* ============================================================================
   tests/qa/api-tests.mjs — drives the HRMS API as qa.owner / qa.hr / qa.manager /
   qa.ops / qa.e1 / qa.e5 (all password QaPass!2026, created by seed.sql).

     node api-tests.mjs phase1   (after seed.sql: roster approval, leaves, exit permission)
     node api-tests.mjs phase2   (after cases/02_attendance.sql: exit variance decisions,
                                  manual correction, payroll API rules, bookings, permissions)

   Every check prints one line:  PASS|FAIL | <id> | <case> | expected=... | actual=...
   and is also written to dbo.QA_RESULT (so run.sh can build the summary).
   Needs: API on http://localhost:5078, sqlcmd on PATH, SQLCMDPASSWORD env (falls back
   to the development password from appsettings.json).
   ============================================================================ */
import { execFileSync } from 'node:child_process';

const API = process.env.QA_API ?? 'http://localhost:5078';
const PW = 'QaPass!2026';
const SQL_PW = process.env.SQLCMDPASSWORD ?? 'p@ssW0rd';
const phase = process.argv[2];
if (!['phase1', 'phase2'].includes(phase)) { console.error('usage: node api-tests.mjs phase1|phase2'); process.exit(2); }

/* ---------------------------------------------------------------- helpers ---- */
function sql(query) {
  const out = execFileSync('sqlcmd', ['-S', 'localhost', '-U', 'sa', '-P', SQL_PW, '-C', '-I', '-h', '-1', '-W', '-s', '|',
    '-d', 'MokaCo_HRMS', '-Q', 'SET NOCOUNT ON; ' + query], { encoding: 'utf8' });
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
  const headers = {};
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
  check('R3g', 'editing a day of an APPROVED month is refused with a clear message (no SQL text)',
    '4xx + {error:"...approved..."}', `${edit.status} ${edit.text.slice(0, 160)}`, edit.status >= 400 && edit.status < 500 && looksClean(edit.text) && !!edit.json?.error);
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

  /* ---- A4: exit-variance queue and decision ---- */
  let ev = await api('qa.hr', 'GET', '/api/attendance/exit-variances?from=2026-08-01&to=2026-08-31');
  const rows = ev.json ?? [];
  const aug6 = rows.find((r) => r.employeeId === e1 && String(r.workDate).startsWith('2026-08-06'));
  const aug8 = rows.find((r) => r.employeeId === e1 && String(r.workDate).startsWith('2026-08-08'));
  check('A4a', 'E1 left 75 min early on 6 Aug (single interval) -> an exit-variance row appears in the queue',
    'row for 2026-08-06 in the queue', aug6 ? `row present: actual=${aug6.exitActualMinutes} approved=${aug6.exitApprovedMinutes} variance=${aug6.exitVarianceMinutes}` : `no row for 2026-08-06 (queue has ${rows.length} row(s); early departure produces no gap, so ExitActualMinutes stays 0)`, !!aug6);
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
  }

  ev = await api('qa.hr', 'GET', '/api/attendance/exit-variances?from=2026-08-01&to=2026-08-31');
  const qaIds = new Set(Object.values(ids).filter((v) => v && typeof v === 'object' && 'emp' in v).map((v) => v.emp));
  const others = (ev.json ?? []).filter((r) => qaIds.has(r.employeeId));
  check('A4e', 'no other QA day is waiting in the exit-variance queue (an approved exit permission must not resurface as a variance after a reprocess)', 'queue empty for QA employees',
    others.length === 0 ? 'empty' : others.map((r) => `${r.fullName} ${String(r.workDate).slice(0, 10)} actual=${r.exitActualMinutes} approved=${r.exitApprovedMinutes} variance=${r.exitVarianceMinutes}`).join('; '), others.length === 0);
  for (const r of others) { await api('qa.hr', 'POST', `/api/attendance/${r.attendanceId}/exit-disposition`, { disposition: 'Ignore', hrNote: 'QA: cleared so payroll readiness can pass' }); }
  if (others.length) note(`A4e: ${others.length} leftover variance(s) dispositioned Ignore so the payroll case can run.`);

  /* ---- A6: manual correction of the missing out punch, then reprocess ---- */
  const man = await api('qa.hr', 'POST', '/api/attendance/manual', { employeeId: e1, workDate: '2026-08-10', firstInUtc: '2026-08-10T07:00:00', lastOutUtc: '2026-08-10T16:00:00', exitMinutes: 0, exitApprovedMins: 0, hrNote: 'QA manual out punch' });
  check('A6b', 'HR manual correction of 10 Aug (07:00-16:00) -> IsManual, worked 510, no anomaly', 'workedMinutes 510, dayFraction 1, status Present',
    `${man.status} worked=${man.json?.workedMinutes} fraction=${man.json?.dayFraction} status=${man.json?.status}`, man.status === 200 && man.json?.workedMinutes === 510);
  const rp = await api('qa.hr', 'POST', '/api/attendance/reprocess?date=2026-08-10');
  const rec = await api('qa.hr', 'GET', `/api/attendance?from=2026-08-10&to=2026-08-10&employeeId=${e1}`);
  const r10 = (rec.json ?? [])[0];
  check('A6c', 'reprocessing 10 Aug does NOT overwrite the manual value', 'isManual true, workedMinutes 510, hasAnomaly false',
    `reprocess ${rp.status}; isManual=${r10?.isManual} worked=${r10?.workedMinutes} anomaly=${r10?.hasAnomaly}`, r10?.isManual === true && r10?.workedMinutes === 510 && r10?.hasAnomaly === false);

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

  /* ---- bookings ---- */
  const room = ids.room;
  const hold = (id) => sql(`UPDATE core.EMAIL_OUTBOX SET [Status]='QaHeld' WHERE BookingId=${id} AND [Status]='Pending'`);
  const kinds = (id) => sql(`SELECT ISNULL(STRING_AGG(MailKind + '/' + Channel, ','), '') FROM core.EMAIL_OUTBOX WHERE BookingId=${id}`);
  const d1 = plusDays(10);
  const b1 = await api(null, 'POST', '/api/public/booking/bookings', { roomId: room, bookDate: d1, startTime: '10:00:00', endTime: '12:00:00', persons: 2, guestName: 'QA Guest B1', guestPhone: '+96170000001', guestEmail: 'qa-guest-b1@example.invalid' });
  if (b1.json?.bookingId) { hold(b1.json.bookingId); state('booking.b1', b1.json.bookingId); }
  check('B1a', 'public create on a free slot -> Pending', '200 status Pending', `${b1.status} ${JSON.stringify(b1.json).slice(0, 160)}`, b1.status === 200 && b1.json?.status === 'Pending');
  const refDb = b1.json?.bookingId ? sql(`SELECT BookingRef FROM booking.BOOKING WHERE BookingId=${b1.json.bookingId}`) : '';
  check('B1d', 'the public create response carries the booking reference (MC-...) the guest is told to keep', 'bookingRef in the response', `response keys=${Object.keys(b1.json ?? {}).join(',')}; DB ref=${refDb}`, !!(b1.json?.bookingRef ?? b1.json?.ref));
  check('B3a', 'creation queues Request + StaffAlert e-mails only (no Confirmation)', 'Request/Email,StaffAlert/Email', kinds(b1.json?.bookingId ?? 0), /Request\/Email/.test(kinds(b1.json?.bookingId ?? 0)) && /StaffAlert\/Email/.test(kinds(b1.json?.bookingId ?? 0)) && !/Confirmation/.test(kinds(b1.json?.bookingId ?? 0)));
  const b1b = await api(null, 'POST', '/api/public/booking/bookings', { roomId: room, bookDate: d1, startTime: '10:00:00', endTime: '12:00:00', persons: 2, guestName: 'QA Guest B1 again', guestPhone: '+96170000001', guestEmail: 'qa-guest-b1@example.invalid' });
  if (b1b.json?.bookingId) hold(b1b.json.bookingId);
  check('B1b', 'identical second create -> 409 slot_taken', '409 {"code":"slot_taken"}', `${b1b.status} ${b1b.text.slice(0, 120)}`, b1b.status === 409 && b1b.json?.code === 'slot_taken');
  const d2 = plusDays(11);
  const b2 = await api(null, 'POST', '/api/public/booking/bookings', { roomId: room, bookDate: d2, startTime: '22:00:00', endTime: '01:00:00', persons: 2, guestName: 'QA Guest B2', guestPhone: '+96170000002', guestEmail: 'qa-guest-b2@example.invalid' });
  if (b2.json?.bookingId) { hold(b2.json.bookingId); state('booking.b2', b2.json.bookingId); }
  check('B2a', 'public create ending 01:00 (endMin 1500) succeeds', '200 Pending, hours 3', `${b2.status} ${b2.json?.error ?? JSON.stringify(b2.json).slice(0, 120)}`, b2.status === 200);
  if (b2.status !== 200) {
    /* the procedure accepts it; create the same booking through it so the availability read can be checked */
    sql(`EXEC booking.usp_Booking_Create @RoomId=${room}, @BookDate='${d2}', @StartTime='22:00', @EndTime='01:00', @Persons=2, @GuestName=N'QA Guest B2 (proc)', @GuestPhone='+96170000002', @Source='Manual'`);
    const id2 = sql(`SELECT MAX(BookingId) FROM booking.BOOKING WHERE GuestName=N'QA Guest B2 (proc)'`); if (id2) { hold(+id2); state('booking.b2', id2); }
    note('B2: the API refused the after-midnight end, so the booking was created through usp_Booking_Create (Manual) for the availability check.');
  }
  const dayB2 = await api(null, 'GET', `/api/public/booking/rooms/${room}/day?date=${d2}`);
  const busy = JSON.stringify(dayB2.json?.busy ?? dayB2.json?.taken ?? dayB2.json);
  check('B2b', 'availability for that day (GET rooms/{id}/day) shows the 22:00-01:00 slot as taken', 'busy contains 22:00 / 01:00 (1320 / 1500)', `${dayB2.status} ${JSON.stringify(dayB2.json).slice(0, 220)}`, dayB2.status === 200 && (/1320|22:00/.test(busy)) && (/1500|01:00/.test(busy)));
  check('B2e', 'day availability reports the room\'s opening hours (QA room 09:00-01:00)', 'openTime 09:00:00, closeTime 01:00:00, isClosed false', `openTime=${dayB2.json?.openTime} closeTime=${dayB2.json?.closeTime} isClosed=${dayB2.json?.isClosed}`, dayB2.json?.openTime === '09:00:00' && dayB2.json?.closeTime === '01:00:00');
  const conf = await api('qa.hr', 'PUT', `/api/bookings/${b1.json?.bookingId}/status`, { status: 'Confirmed' });
  if (b1.json?.bookingId) hold(b1.json.bookingId);
  check('B3b', 'staff confirm in HRMS -> Confirmed and a Confirmation e-mail is queued only now', 'status Confirmed; outbox gains Confirmation/Email', `${conf.status} ${conf.json?.status}; outbox=${kinds(b1.json?.bookingId ?? 0)}`, conf.status === 200 && conf.json?.status === 'Confirmed' && /Confirmation\/Email/.test(kinds(b1.json?.bookingId ?? 0)));
  /* B4: staff cancel with a payment on file */
  const d3 = plusDays(12), d4 = plusDays(13);
  const m1 = await api('qa.hr', 'POST', '/api/bookings/manual', { roomId: room, bookDate: d3, startTime: '14:00:00', endTime: '16:00:00', persons: 2, guestName: 'QA Guest B4a', guestPhone: '+96170000004' });
  const m2 = await api('qa.hr', 'POST', '/api/bookings/manual', { roomId: room, bookDate: d4, startTime: '14:00:00', endTime: '16:00:00', persons: 2, guestName: 'QA Guest B4b', guestPhone: '+96170000005' });
  for (const m of [m1, m2]) if (m.json?.bookingId) hold(m.json.bookingId);
  state('booking.b4a', m1.json?.bookingId); state('booking.b4b', m2.json?.bookingId);
  const pay1 = await api('qa.hr', 'POST', `/api/bookings/${m1.json?.bookingId}/payments`, { paymentMethodId: 1, amount: 30, reference: 'QA cash' });
  const pay2 = await api('qa.hr', 'POST', `/api/bookings/${m2.json?.bookingId}/payments`, { paymentMethodId: 1, amount: 30, reference: 'QA cash' });
  const cancel = await api('qa.hr', 'PUT', `/api/bookings/${m1.json?.bookingId}/status`, { status: 'Cancelled', reason: 'QA staff cancel' });
  if (m1.json?.bookingId) hold(m1.json.bookingId);
  const b4aRow = m1.json?.bookingId ? sql(`SELECT CONCAT(CancelledBy, '|', RefundAmount, '|', RefundStatus, '|', DepositDue) FROM booking.BOOKING WHERE BookingId=${m1.json.bookingId}`) : '';
  const [cb, ra, rs, dd] = b4aRow.split('|');
  check('B4a', 'staff cancel of a booking with 30 paid (total 40) -> refund due = everything paid (30)', 'cancelledBy Staff, RefundAmount 30.00, RefundStatus Due',
    `manual ${m1.status} pay ${pay1.status}/${pay2.status}; cancel ${cancel.status} -> DB cancelledBy=${cb} refundAmount=${ra} refundStatus=${rs} (deposit ${dd}); response=${JSON.stringify(cancel.json)}`,
    cancel.status === 200 && cb === 'Staff' && Number(ra) === 30 && rs === 'Due');
  note('B4: the HRMS API cannot mark a cancellation as requested by the GUEST (BookingStatusRequest has no CancelledBy) and exposes no refund-recording or guest-cancel endpoint; those two rules are exercised at procedure level in cases/05_bookings.sql.');
  /* B5: 3 hours -> 10 % discount on the room only; deposit on the discounted total (incl. add-on) */
  const d5 = plusDays(14);
  const b5 = await api(null, 'POST', '/api/public/booking/bookings', { roomId: room, bookDate: d5, startTime: '10:00:00', endTime: '13:00:00', persons: 2, guestName: 'QA Guest B5', guestPhone: '+96170000006', guestEmail: 'qa-guest-b5@example.invalid', addonIds: [ids.addon] });
  if (b5.json?.bookingId) { hold(b5.json.bookingId); state('booking.b5', b5.json.bookingId); }
  const b5Row = b5.json?.bookingId ? sql(`SELECT CONCAT(DiscountPercent, '|', DiscountAmount, '|', TotalAmount, '|', DepositPercent, '|', DepositDue) FROM booking.BOOKING WHERE BookingId=${b5.json.bookingId}`) : '';
  const [dp, da, ta, depP, depD] = b5Row.split('|');
  check('B5a', '3-hour booking at 20/h with a 15 fixed add-on and a 10 % discount from 3 h: discount 6 on the room only, total 69',
    'discountAmount 6.00, totalAmount 69.00', `${b5.status} response total=${b5.json?.totalAmount}; DB discount%=${dp} discount=${da} total=${ta} ${b5.json?.error ?? ''}`, b5.status === 200 && Number(da) === 6 && Number(ta) === 69);
  check('B5b', 'deposit computed on the discounted total with the lead-time tier (>=168 h -> 20 %)', 'depositPercent 20, depositDue 13.80',
    `response depositDue=${b5.json?.depositDue}; DB depositPercent=${depP} depositDue=${depD}`, Number(depP) === 20 && Number(depD) === 13.8);
  note(`B5: the public create response exposes only {${Object.keys(b5.json ?? {}).join(', ')}} - no reference, discount, hours or deposit percent, although usp_Booking_Create returns them.`);

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
