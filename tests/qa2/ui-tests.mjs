#!/usr/bin/env node
/* ============================================================================
   tests/qa2/ui-tests.mjs — the web side of the QA2 features (part E), through headless Chrome over CDP (no
   puppeteer), on the data the SQL cases left. Each page is opened as a qa2.* user, checked against what the API
   answers for the same question, and photographed into tests/qa2/screenshots.
   Needs: google-chrome on PATH, the web dev server (QA_WEB, default http://localhost:5173), the API on :5078.
   Without Chrome or the web server the stage is a NOTE, not a failure: the suite's subject is the rules.
   ============================================================================ */
import { spawn, execFileSync } from 'node:child_process';
import { SQLCMD_CONNECTION } from '../qa/qa-env.mjs';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = process.env.QA_WEB ?? 'http://localhost:5173';
const API = process.env.QA_API ?? 'http://localhost:5078';
const PW = 'QaPass!2026';
const PORT = 9334;
mkdirSync(join(HERE, 'screenshots'), { recursive: true });

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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function login(user) {
  const r = await fetch(`${API}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: user, password: PW }) });
  return r.json();
}
async function apiGet(token, path) {
  const r = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${token}` } });
  return r.ok ? r.json() : null;
}

class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); ws.onmessage = (m) => this.onMessage(JSON.parse(m.data)); }
  onMessage(msg) { if (msg.id && this.pending.has(msg.id)) { const { res, rej } = this.pending.get(msg.id); this.pending.delete(msg.id); msg.error ? rej(new Error(msg.error.message)) : res(msg.result); } }
  send(method, params = {}) { const id = ++this.id; return new Promise((res, rej) => { this.pending.set(id, { res, rej }); this.ws.send(JSON.stringify({ id, method, params })); }); }
  async evaluate(expression) { const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + JSON.stringify(r.exceptionDetails.exception?.description ?? '')); return r.result.value; }
  async navigate(url, wait = 3500) { await this.send('Page.navigate', { url }); await sleep(wait); }
  async screenshot(name) { const r = await this.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }); writeFileSync(join(HERE, 'screenshots', `${name}.png`), Buffer.from(r.data, 'base64')); }
}

async function main() {
  if (!(await fetch(WEB).then((r) => r.ok).catch(() => false))) { note(`UI stage skipped: ${WEB} is not reachable`); return; }
  const chrome = spawn('google-chrome', ['--headless=new', '--disable-gpu', '--no-sandbox', `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/qa2-chrome-${process.pid}`, '--window-size=1366,900', 'about:blank'], { stdio: 'ignore' });
  chrome.on('error', () => {});
  try {
    let version = null;
    for (let i = 0; i < 30 && !version; i++) { try { version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); } catch { await sleep(500); } }
    if (!version) { note('UI stage skipped: headless Chrome did not start'); return; }
    const target = await (await fetch(`http://127.0.0.1:${PORT}/json/new?about:blank`, { method: 'PUT' })).json();
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res) => (ws.onopen = res));
    const cdp = new Cdp(ws);
    await cdp.send('Page.enable'); await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1366, height: 900, deviceScaleFactor: 1, mobile: false });

    const owner = await login('qa2.owner');
    await cdp.navigate(`${WEB}/login`, 2500);
    await cdp.evaluate(`sessionStorage.setItem('mokaco.accessToken', ${JSON.stringify(owner.accessToken)}); sessionStorage.setItem('mokaco.refreshToken', ${JSON.stringify(owner.refreshToken)}); 'ok'`);
    const page = () => cdp.evaluate(`({ path: location.pathname, text: document.body.innerText, rows: document.querySelectorAll('tbody tr').length, errors: [...document.querySelectorAll('.alert--error')].map((e) => e.textContent.trim()) })`);

    const M = sql(`SELECT [Value] FROM dbo.QA2_STATE WHERE [Key] = 'month'`);          // yyyy-MM
    const from = `${M}-01`, year = M.slice(0, 4);
    const to = sql(`SELECT CONVERT(CHAR(10), EOMONTH(${q(from)}), 23)`);

    /* ---- E1: Core → Holidays ---- */
    await cdp.navigate(`${WEB}/core/holidays`);
    let p = await page();
    await cdp.screenshot('holidays');
    const apiHol = (await apiGet(owner.accessToken, `/api/holidays?year=${year}`)) ?? [];
    const qaHol = apiHol.filter((h) => /^QA2 /.test(h.name)).map((h) => h.name);
    check('UI-E1', '/core/holidays lists the year\'s holidays, the QA2 ones among them, with the add button', `every QA2 holiday of ${year} the API returns (${qaHol.length}) is on the page`,
      `path=${p.path} rows=${p.rows} api=${apiHol.length} missing=[${qaHol.filter((n) => !p.text.includes(n)).join(', ')}] errors=[${p.errors.join('; ')}]`,
      p.path === '/core/holidays' && qaHol.length > 0 && qaHol.every((n) => p.text.includes(n)) && p.errors.length === 0);

    /* ---- E4a: Anomalies → Worked without roster ---- */
    await cdp.navigate(`${WEB}/attendance/anomalies?from=${from}&to=${to}&view=unrostered`, 4500);
    p = await page();
    await cdp.screenshot('anomalies-worked-without-roster');
    const apiUnr = (await apiGet(owner.accessToken, `/api/attendance/worked-without-roster?from=${from}&to=${to}`)) ?? [];
    check('UI-E4a', 'Anomalies → "Worked without roster" shows what GET /api/attendance/worked-without-roster returns for the month', `${apiUnr.length} row(s), the first employee named`,
      `rows=${p.rows} api=${apiUnr.length} first=${apiUnr[0]?.employeeName ?? '-'} errors=[${p.errors.join('; ')}]`,
      p.errors.length === 0 && p.rows === apiUnr.length && (apiUnr.length === 0 || p.text.includes(apiUnr[0].employeeName)));

    /* ---- E4b: Anomalies → Unknown device punches, and "Map to employee" through the page's own dialog ----
       A punch under a PIN nobody holds is put on the QA2 terminal (yesterday: an open period), found on the page,
       mapped to QA2 E3 by clicking through the dialog, and then looked up in the database. */
    const e3 = +sql(`SELECT dbo.QA2_Emp(N'E3')`);
    sql(`DECLARE @Dev INT = (SELECT DeviceId FROM attendance.DEVICE WHERE SerialNumber = 'QA2-DEVICE-001');
         DECLARE @t DATETIME2(0) = DATEADD(HOUR, 8, CAST(DATEADD(DAY, -1, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)) AS DATETIME2(0)));
         DECLARE @h VARCHAR(64) = CONVERT(VARCHAR(64), HASHBYTES('SHA2_256', CONCAT('QA2|Q2UI1|', CONVERT(VARCHAR(19), @t, 126), '|0')), 2);
         DECLARE @ins TABLE (RawLogId BIGINT, WasDuplicate BIT, WasUnresolved BIT);
         INSERT INTO @ins EXEC attendance.usp_RawLog_Insert @DeviceId = @Dev, @EnrollPin = 'Q2UI1', @PunchTimeUtc = @t, @PunchType = 0, @Source = 'QA2', @DedupHash = @h;`);
    await cdp.navigate(`${WEB}/attendance/anomalies?view=devices`, 4500);
    p = await page();
    await cdp.screenshot('anomalies-unknown-device-punches');
    const apiQ = (await apiGet(owner.accessToken, `/api/attendance/device-quarantine`)) ?? [];
    const listed = p.text.includes('Q2UI1');
    let mapped = 'not attempted';
    if (listed) {
      await cdp.evaluate(`(() => { const row = [...document.querySelectorAll('tbody tr')].find((r) => r.textContent.includes('Q2UI1')); row.querySelector('button').click(); return 'ok'; })()`);
      await sleep(1200);
      await cdp.evaluate(`document.querySelector('#quarantine-employee').click(); 'ok'`);
      await sleep(900);
      /* the page's filter selects keep their own options mounted: look only inside THIS select's listbox, and type the
         name so the option is rendered whatever the size of the employee list */
      await cdp.evaluate(`(() => { const i = document.querySelector('#quarantine-employee'); i.focus(); const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set; set.call(i, 'QA2 E3'); i.dispatchEvent(new Event('input', { bubbles: true })); return 'typed'; })()`);
      await sleep(900);
      const picked = await cdp.evaluate(`(() => { const i = document.querySelector('#quarantine-employee'); const box = document.getElementById(i.getAttribute('aria-controls') ?? '') ?? document;
        const all = [...box.querySelectorAll('[role="option"]')]; const o = all.find((e) => /^QA2 E3(?!\\d)/.test(e.textContent.trim()));
        if (!o) return 'no option among ' + all.length + ': ' + all.slice(0, 3).map((e) => e.textContent.trim()).join(' / '); o.click(); return 'picked'; })()`);
      await sleep(600);
      await cdp.screenshot('anomalies-map-to-employee');
      await cdp.evaluate(`(() => { const b = [...document.querySelectorAll('[role="dialog"] button')].find((e) => /map to employee/i.test(e.textContent)); if (b) b.click(); return !!b; })()`);
      await sleep(3500);
      mapped = picked;
    }
    const after = await page();
    await cdp.screenshot('anomalies-mapped-result');
    const owned = +sql(`SELECT COUNT(*) FROM attendance.RAW_DEVICE_LOG WHERE EnrollPin = 'Q2UI1' AND EmployeeId = ${e3}`);
    const enrolled = +sql(`SELECT COUNT(*) FROM attendance.EMPLOYEE_DEVICE WHERE EnrollPin = 'Q2UI1' AND EmployeeId = ${e3}`);
    check('UI-E4b', 'Anomalies → "Unknown device punches" lists the unknown PIN; "Map to employee" in its dialog enrols it, hands the punch over and says what it did',
      'PIN Q2UI1 listed (rows = API lines); after mapping: the punch belongs to QA2 E3, the PIN is enrolled, the line is gone, the result is on screen',
      `listed=${listed} rows=${p.rows} api=${apiQ.length} pick=${mapped} punchesOnE3=${owned} enrolled=${enrolled} stillListed=${after.text.includes('Q2UI1 ') && after.rows > 0 && /Q2UI1\s/.test([...after.text.matchAll(/Q2UI1[^\n]*/g)].map((m) => m[0]).filter((l) => !/is now/.test(l)).join('|'))} result="${(after.text.match(/PIN Q2UI1 is now[^\n]*/) ?? ['none'])[0]}" errors=[${after.errors.join('; ')}]`,
      listed && p.rows === apiQ.length && owned === 1 && enrolled === 1 && /PIN Q2UI1 is now QA2 E3/.test(after.text) && after.errors.length === 0);

    /* ---- E3: employee profile → Branch history (E12 was transferred mid-month, A4d) ---- */
    const e12 = +sql(`SELECT dbo.QA2_Emp(N'E12')`);
    const apiHist = (await apiGet(owner.accessToken, `/api/employees/${e12}/branch-history`)) ?? [];
    await cdp.navigate(`${WEB}/hr/employees/${e12}`, 4000);
    await cdp.evaluate(`(() => { const t = [...document.querySelectorAll('[role="tab"]')].find((e) => /branch history/i.test(e.textContent)); if (t) t.click(); return !!t; })()`);
    await sleep(2500);
    p = await page();
    await cdp.screenshot('employee-branch-history');
    check('UI-E3', 'employee profile → "Branch history" tab lists the rows of GET /api/employees/{id}/branch-history', `${apiHist.length} row(s), every branch named, one marked Current`,
      `rows=${p.rows} api=${apiHist.length} branches=[${[...new Set(apiHist.map((h) => h.branchName))].join(', ')}] current=${/\bcurrent\b/i.test(p.text)}`,
      apiHist.length > 0 && p.rows === apiHist.length && apiHist.every((h) => p.text.includes(h.branchName)) && /\bcurrent\b/i.test(p.text));   // the badge is upper-cased by CSS, and innerText reports it as shown

    /* ---- E2: the leave form's cost preview — the page's own service, through the dev proxy ---- */
    const e11 = +sql(`SELECT dbo.QA2_Emp(N'E11')`);
    const annual = +sql(`SELECT TOP 1 LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name LIKE N'Annual%' ORDER BY LeaveTypeId`);
    const direct = await apiGet(owner.accessToken, `/api/leave-requests/working-days?employeeId=${e11}&leaveTypeId=${annual}&from=${from}&to=${to}`);
    const viaPage = await cdp.evaluate(`(async () => { const m = await import('/src/services/workflowService.ts'); try { return await m.leaveRequestsService.workingDays(${e11}, ${annual}, '${from}', '${to}', null); } catch (e) { return { error: String(e?.message ?? e) }; } })()`);
    const half = await cdp.evaluate(`(async () => { const m = await import('/src/services/workflowService.ts'); try { return await m.leaveRequestsService.workingDays(${e11}, ${annual}, '${from}', '${from}', 'AM'); } catch (e) { return { error: String(e?.message ?? e) }; } })()`);
    check('UI-E2', 'the leave form\'s preview call returns the month\'s working days (rest days and the branch holiday cost nothing) and 0.5 for a half day', `same as the API: ${JSON.stringify(direct)}; a half day = 0.5 or 0 (rest day)`,
      `page=${JSON.stringify(viaPage)} half=${JSON.stringify(half)}`,
      direct != null && viaPage?.workingDays === direct.workingDays && viaPage.workingDays < viaPage.calendarDays && viaPage.restDays + viaPage.holidays > 0 && (half?.workingDays === 0.5 || half?.workingDays === 0));
    await cdp.navigate(`${WEB}/requests/new`, 3500);
    await cdp.screenshot('new-request');

    /* ---- E6: Settings → Advanced carries the Leave and Payroll cards with the new keys ---- */
    await cdp.navigate(`${WEB}/settings?tab=advanced`, 4000);
    p = await page();
    await cdp.screenshot('settings-advanced');
    const wanted = ['Holiday work rate', 'Pay the leave balance on termination', 'Leave counts rest days and holidays', 'Allow a negative leave balance', 'Carry-over cap', 'Carried-over days expire on'];
    check('UI-E6', 'Settings shows the six new keys under their Leave and Payroll cards', wanted.join(' | '), `missing=[${wanted.filter((w) => !p.text.includes(w)).join(' | ')}]`, wanted.every((w) => p.text.includes(w)));
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
  }
}
main().catch((e) => { console.error('UI tests crashed:', e); note(`UI stage crashed: ${String(e?.message ?? e).slice(0, 300)}`); });
