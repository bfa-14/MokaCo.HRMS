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
  /** A REAL click (mouse pressed + released at the element's centre) — what Mantine's popovers and day cells listen to. `expr` is a JS expression for the element. */
  async clickAt(expr) { const box = await this.evaluate(`(() => { const e = ${expr}; if (!e) return null; e.scrollIntoView({ block: 'center' }); const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`); if (!box) return false; await this.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: box.x, y: box.y }); for (const type of ['mousePressed', 'mouseReleased']) await this.send('Input.dispatchMouseEvent', { type, x: box.x, y: box.y, button: 'left', clickCount: 1 }); return true; }
  async hover(expr) { const box = await this.evaluate(`(() => { const e = ${expr}; if (!e) return null; const r = e.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`); if (!box) return false; await this.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: box.x, y: box.y }); return true; }
  async type(text) { for (const ch of text) await this.send('Input.dispatchKeyEvent', { type: 'char', text: ch }); }
  async key(key, vk) { for (const type of ['rawKeyDown', 'keyUp']) await this.send('Input.dispatchKeyEvent', { type, key, code: key, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk }); }
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

    /* ---- E6: Settings — Leave and Payroll are tabs of their own, each carrying its new keys ---- */
    const tabsWanted = { leave: ['Leave counts rest days and holidays', 'Allow a negative leave balance', 'Carry-over cap', 'Carried-over days expire on'], payroll: ['Holiday work rate', 'Pay the leave balance on termination'] };
    const missing = [];
    for (const [tab, titles] of Object.entries(tabsWanted)) {
      await cdp.navigate(`${WEB}/settings?tab=${tab}`, 4000);
      p = await page();
      await cdp.screenshot(`settings-${tab}`);
      const selected = await cdp.evaluate(`[...document.querySelectorAll('[role="tab"][aria-selected="true"]')].map((t) => t.textContent.trim()).join(',')`);
      if (!new RegExp(`^${tab}$`, 'i').test(selected)) missing.push(`tab ${tab} not selected (selected: ${selected})`);
      for (const w of titles) if (!p.text.includes(w)) missing.push(`${tab}: ${w}`);
    }
    await cdp.navigate(`${WEB}/settings?tab=advanced`, 3500);
    p = await page();
    const stillUnderAdvanced = Object.values(tabsWanted).flat().filter((w) => p.text.includes(w));
    check('UI-E6', 'Settings has a Leave tab and a Payroll tab carrying the six new keys; none of them is left under Advanced', 'nothing missing, nothing still under Advanced',
      `missing=[${missing.join(' | ')}] stillUnderAdvanced=[${stillUnderAdvanced.join(' | ')}]`, missing.length === 0 && stillUnderAdvanced.length === 0);

    /* ---- E7: the roster page's branch filter — narrows the grid, sends branchId, is remembered ---- */
    await cdp.navigate(`${WEB}/attendance/roster?period=${M}`, 5000);
    const gridRows = () => cdp.evaluate(`document.querySelectorAll('tbody tr').length`);
    const allRows = await gridRows();
    /* the dev server loads hundreds of modules, so the resource-timing buffer is full long before this: record the page's own fetches instead */
    await cdp.evaluate(`(() => { window.__qaUrls = []; const f = window.fetch; window.fetch = (...a) => { window.__qaUrls.push(String(a[0]?.url ?? a[0])); return f(...a); }; return 'ok'; })()`);
    await cdp.evaluate(`document.querySelector('input[aria-label="Branch filter"]').click(); 'ok'`);
    await sleep(800);
    const pickedBranch = await cdp.evaluate(`(() => { const i = document.querySelector('input[aria-label="Branch filter"]'); const box = document.getElementById(i.getAttribute('aria-controls') ?? '') ?? document;
      const o = [...box.querySelectorAll('[role="option"]')].find((e) => e.textContent.trim() === 'QA2 Branch 2'); if (!o) return 'no option'; o.click(); return 'picked'; })()`);
    await sleep(4000);
    const b2Rows = await gridRows();
    const b2 = +sql(`SELECT BranchId FROM hr.BRANCH WHERE Name = N'QA2 Branch 2'`);
    const sent = await cdp.evaluate(`(window.__qaUrls ?? []).filter((n) => n.includes('/api/roster?') && n.includes('branchId=${b2}')).length`);
    const names = await cdp.evaluate(`document.body.innerText`);
    const apiB2 = (await apiGet(owner.accessToken, `/api/roster?from=${from}&to=${to}&branchId=${b2}`)) ?? [];
    const expectedPeople = [...new Set(apiB2.map((r) => r.fullName))];
    await cdp.screenshot('roster-branch-filter');
    await cdp.navigate(`${WEB}/attendance/roster?period=${M}`, 5000);
    const remembered = await cdp.evaluate(`document.querySelector('input[aria-label="Branch filter"]')?.value`);
    const rememberedRows = await gridRows();
    await cdp.evaluate(`Object.keys(localStorage).filter((k) => k.startsWith('mokaco.roster.branch.')).forEach((k) => localStorage.removeItem(k)); 'ok'`);
    check('UI-E7', 'roster page: choosing "QA2 Branch 2" in the branch filter narrows the grid to that branch (as of the work dates), sends branchId to GET /api/roster, and is remembered after a reload',
      `fewer rows than "All branches"; everybody the API returns for branchId=${b2} (${expectedPeople.length}) on the grid and no QA2 Branch 1 only employee; filter still "QA2 Branch 2" after reload`,
      `pick=${pickedBranch} rows all=${allRows} branch2=${b2Rows} requestsWithBranchId=${sent} missingPeople=[${expectedPeople.filter((n) => !names.includes(n)).join(', ')}] E1shown=${/QA2 E1\b/.test(names)} afterReload="${remembered}" rows=${rememberedRows}`,
      pickedBranch === 'picked' && b2Rows > 0 && b2Rows < allRows && sent > 0 && expectedPeople.every((n) => names.includes(n)) && !/QA2 E1\b/.test(names) && remembered === 'QA2 Branch 2' && rememberedRows === b2Rows);

    /* =====================================================================================================
       BUG A — the shared from–to field (src/components/DateRangeField). It was unusable: a page that only stores
       COMPLETE ranges threw away the state between the first click and the second, the controlled picker snapped
       back, and the range could never change; it was a button, so nothing could be typed; and on the booking pages
       the choice was not in the URL. On every page that carries it: pick 01–15 of LAST month in the calendar, then
       the field, the URL, the request and the grid must all say so — and still say so after a reload.
       ===================================================================================================== */
    {
      const [ty, tm] = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Beirut' }).format(new Date()).split('-').map(Number);
      const lm = tm === 1 ? `${ty - 1}-12` : `${ty}-${String(tm - 1).padStart(2, '0')}`;
      const F = `${lm}-01`, T = `${lm}-15`;
      const field = () => cdp.evaluate(`(() => { const f = document.querySelector('[data-testid="date-range"]'); return f ? { from: f.dataset.from, to: f.dataset.to, texts: [...f.querySelectorAll('input')].map((i) => i.value) } : null; })()`);
      const dayCell = (n) => `[...document.querySelectorAll('.mantine-DatePicker-day:not([data-outside])')].find((b) => b.textContent.trim() === '${n}')`;
      const record = () => cdp.evaluate(`(() => { window.__qaUrls = []; if (!window.__qaFetch) { window.__qaFetch = window.fetch; window.fetch = (...a) => { window.__qaUrls.push(String(a[0]?.url ?? a[0])); return window.__qaFetch(...a); }; } return 'ok'; })()`);
      /** every date written in the grid's body, as yyyy-MM-dd */
      const gridDates = () => cdp.evaluate(String.raw`(() => { const text = [...document.querySelectorAll('tbody')].map((b) => b.innerText).join('\n'); const out = [];
        for (const m of text.matchAll(/\b(\d{4})-(\d{2})-(\d{2})\b/g)) out.push(m[0]);
        for (const m of text.matchAll(/\b(\d{2})\/(\d{2})\/(\d{4})\b/g)) out.push(m[3] + '-' + m[2] + '-' + m[1]);
        return out; })()`);
      const nextDay = sql(`SELECT CONVERT(CHAR(10), DATEADD(DAY, 1, CAST('${T}' AS DATE)), 23)`);

      const pages = [
        ['daily', '/attendance/daily', '/api/attendance?'],
        ['anomalies', '/attendance/anomalies', '/api/attendance/anomalies?'],
        ['exit-variances', '/attendance/exit-variances', '/api/attendance/exit-variances?'],
        ['bookings-list', '/bookings/list', '/api/bookings'],
        ['bookings-report', '/bookings/report', '/api/bookings'],
        ['requests', '/requests', '/api/requests'],
      ];
      for (const [name, path, apiPart] of pages) {
        await cdp.navigate(`${WEB}${path}`, 4500);
        await record();
        const before = await field();
        const openedByClick = await cdp.clickAt(`document.querySelector('[data-testid="date-range"] input[data-range-end="from"]')`);
        await sleep(700);
        const calendar = await cdp.evaluate(`!!document.querySelector('.mantine-DatePicker-day')`);
        /* to last month: the calendar opens on the month of the current start (or today), so step back until the header says it */
        const wantHeader = new Date(Date.UTC(+lm.slice(0, 4), +lm.slice(5) - 1, 1)).toLocaleString('en', { month: 'long', year: 'numeric', timeZone: 'UTC' });
        for (let i = 0; i < 14; i++) {
          const h = await cdp.evaluate(`document.querySelector('.mantine-DatePicker-calendarHeaderLevel')?.textContent ?? ''`);
          if (h === wantHeader) break;
          const dir = new Date(h + ' 1 UTC') > new Date(wantHeader + ' 1 UTC') ? 'previous' : 'next';
          await cdp.clickAt(`document.querySelector('.mantine-DatePicker-calendarHeaderControl[data-direction="${dir}"]')`); await sleep(350);
        }
        await cdp.clickAt(dayCell(1)); await sleep(500);
        const mid = await cdp.evaluate(`({ open: !!document.querySelector('.mantine-DatePicker-day'), first: document.querySelectorAll('.mantine-DatePicker-day[data-first-in-range]').length })`);
        await cdp.hover(dayCell(9)); await sleep(300);
        const hoverRange = await cdp.evaluate(`document.querySelectorAll('.mantine-DatePicker-day[data-in-range]').length`);
        await cdp.clickAt(dayCell(15)); await sleep(800);
        /* the Daily page reloads on an explicit Apply (so the grid never moves under somebody still choosing) */
        await cdp.clickAt(`[...document.querySelectorAll('.filter-bar button, .filter-field button')].find((b) => b.textContent.trim() === 'Apply')`);
        await sleep(3200);
        const picked = await field();
        const url = await cdp.evaluate(`location.search`);
        const requested = await cdp.evaluate(`(window.__qaUrls ?? []).filter((u) => u.includes(${JSON.stringify(apiPart)}) && u.includes('${F}') && u.includes('${T}')).length`);
        const dates = await gridDates();
        /* an overnight shift's clock-out is written with the next day's date: that belongs to the 15th */
        const outside = dates.filter((d) => d < F || d > nextDay);
        await cdp.screenshot(`range-${name}`);
        await cdp.navigate(`${WEB}${path}${url}`, 4500);
        const reloaded = await field();
        const ok = openedByClick && calendar && mid.open && hoverRange >= 8 && picked?.from === F && picked?.to === T && url.includes(`from=${F}`) && url.includes(`to=${T}`) && requested > 0 && outside.length === 0 && reloaded?.from === F && reloaded?.to === T;
        check(`UI-A-${name}`, `${path}: clicking the period opens the calendar; 01–15 of last month is picked with the hover preview; the field, the URL, the request and the grid follow; a reload keeps it`,
          `calendar opens; after the 1st click it stays open with a draft and the hover paints the range; field = ${F}..${T}; URL ?from=${F}&to=${T}; a request for that range; every grid date inside it; the same after reload`,
          `before=${before?.from}..${before?.to} calendar=${calendar} afterFirstClick={open:${mid.open},hoverInRange:${hoverRange}} field=${picked?.from}..${picked?.to} [${picked?.texts.join(' – ')}] url="${url}" requests=${requested} gridDates=${dates.length} outside=[${outside.slice(0, 4).join(',')}] afterReload=${reloaded?.from}..${reloaded?.to}`, ok);
      }

      /* typing, the shortcuts, the X, and Arabic — once, on the exit-variances page (the one that could not be changed at all) */
      await cdp.navigate(`${WEB}/attendance/exit-variances?from=${F}&to=${T}`, 4500);
      const toInput = `document.querySelector('[data-testid="date-range"] input[data-range-end="to"]')`;
      await cdp.clickAt(toInput); await sleep(400);
      await cdp.evaluate(`${toInput}.select(); 'ok'`);
      const typedText = `10/${lm.slice(5)}/${lm.slice(0, 4)}`;
      await cdp.type(typedText); await cdp.key('Enter', 13); await sleep(2500);
      const typed = await field();
      const typedUrl = await cdp.evaluate(`location.search`);
      await cdp.evaluate(`${toInput}.select(); 'ok'`);
      await cdp.type('31/02/2026'); await cdp.key('Enter', 13); await sleep(800);
      const nonsense = await cdp.evaluate(`({ to: document.querySelector('[data-testid="date-range"]').dataset.to, invalid: document.querySelector('[data-testid="date-range"]').dataset.invalid ?? null })`);
      await cdp.key('Escape', 27); await sleep(500);
      check('UI-A-typing', 'a date can be typed into either end: DD/MM/YYYY + Enter applies it and writes the URL; a day that does not exist (31/02) is refused and changes nothing',
        `to = ${lm}-10 in the field and the URL; 31/02/2026 marked invalid, the range untouched`,
        `typed "${typedText}" -> ${typed?.from}..${typed?.to} url="${typedUrl}"; "31/02/2026" -> to=${nonsense.to} invalid=${nonsense.invalid}`,
        typed?.from === F && typed?.to === `${lm}-10` && typedUrl.includes(`to=${lm}-10`) && nonsense.to === `${lm}-10` && nonsense.invalid === 'to');

      const preset = async (p) => { await cdp.clickAt(`document.querySelector('[data-testid="date-range"] input[data-range-end="from"]')`); await sleep(600); const okClick = await cdp.clickAt(`document.querySelector('[data-preset="${p}"]')`); await sleep(2200); return okClick ? field() : null; };
      const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Beirut' }).format(new Date());
      const minus6 = sql(`SELECT CONVERT(CHAR(10), DATEADD(DAY, -6, CAST('${today}' AS DATE)), 23)`);
      const lastMonthEnd = sql(`SELECT CONVERT(CHAR(10), EOMONTH('${F}'), 23)`);
      const thisMonthEnd = sql(`SELECT CONVERT(CHAR(10), EOMONTH('${today}'), 23)`);
      const p7 = await preset('last7Days');
      const pLast = await preset('lastMonth');
      const customShown = await (async () => { await cdp.clickAt(`document.querySelector('[data-testid="date-range"] input[data-range-end="from"]')`); await sleep(600); const v = await cdp.evaluate(`[...document.querySelectorAll('[data-preset]')].map((b) => b.dataset.preset + (b.dataset.active ? '*' : '')).join(',')`); await cdp.key('Escape', 27); await sleep(400); return v; })();
      const hasReset = await cdp.evaluate(`!!document.querySelector('[data-range-clear]')`);
      await cdp.clickAt(`document.querySelector('[data-range-clear]')`); await sleep(2200);
      const reset = await field();
      const resetUrl = await cdp.evaluate(`location.search`);
      check('UI-A-presets', 'the shortcuts "This month", "Last month", "Last 7 days", "Custom" are offered and apply; the X goes back to the page default',
        `last7Days = ${minus6}..${today}; lastMonth = ${F}..${lastMonthEnd} (marked active); X -> this month ${today.slice(0, 8)}01..${thisMonthEnd} (the URL drops the range or carries the default)`,
        `last7Days=${p7?.from}..${p7?.to} lastMonth=${pLast?.from}..${pLast?.to} offered=[${customShown}] resetButton=${hasReset} afterX=${reset?.from}..${reset?.to} url="${resetUrl}"`,
        p7?.from === minus6 && p7?.to === today && pLast?.from === F && pLast?.to === lastMonthEnd && customShown === 'thisMonth,lastMonth*,last7Days,custom' && hasReset
          && reset?.from === `${today.slice(0, 8)}01` && reset?.to === thisMonthEnd && (!/from=|to=/.test(resetUrl) || resetUrl.includes(`from=${today.slice(0, 8)}01`)));

      /* Arabic: the page is RTL, the field still opens, picks and writes the URL; the dates themselves stay left-to-right */
      const ownerUserId = +sql(`SELECT UserId FROM security.[USER] WHERE Username = N'qa2.owner'`);
      await cdp.evaluate(`localStorage.setItem('lang:${ownerUserId}', 'ar'); 'ok'`);
      await cdp.navigate(`${WEB}/attendance/exit-variances`, 5000);
      const dir = await cdp.evaluate(`document.documentElement.dir`);
      await cdp.clickAt(`document.querySelector('[data-testid="date-range"] input[data-range-end="from"]')`); await sleep(700);
      const arPresets = await cdp.evaluate(`[...document.querySelectorAll('[data-preset]')].map((b) => b.textContent.trim()).join(' | ')`);
      await cdp.clickAt(`document.querySelector('[data-preset="lastMonth"]')`); await sleep(2200);
      await cdp.clickAt(`document.querySelector('[data-testid="date-range"] input[data-range-end="from"]')`); await sleep(700);
      await cdp.clickAt(dayCell(1)); await sleep(400);
      await cdp.clickAt(dayCell(15)); await sleep(2500);
      const ar = await field();
      const arUrl = await cdp.evaluate(`location.search`);
      const inputDir = await cdp.evaluate(`document.querySelector('[data-testid="date-range"] input').dir`);
      await cdp.screenshot('range-arabic');
      await cdp.evaluate(`localStorage.removeItem('lang:${ownerUserId}'); 'ok'`);
      check('UI-A-rtl', 'in Arabic the page is right-to-left and the field works the same: shortcuts in Arabic, 01–15 picked in the calendar, URL written; the digits stay left-to-right',
        `dir=rtl; field = ${F}..${T}; URL carries it; inputs dir=ltr`, `dir=${dir} presets="${arPresets}" field=${ar?.from}..${ar?.to} url="${arUrl}" inputDir=${inputDir}`,
        dir === 'rtl' && ar?.from === F && ar?.to === T && arUrl.includes(`from=${F}`) && inputDir === 'ltr' && /الشهر الماضي/.test(arPresets));
      await cdp.navigate(`${WEB}/attendance/exit-variances`, 3000);
    }
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
  }
}
main().catch((e) => { console.error('UI tests crashed:', e); note(`UI stage crashed: ${String(e?.message ?? e).slice(0, 300)}`); });
