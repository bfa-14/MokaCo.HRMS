#!/usr/bin/env node
/* ============================================================================
   tests/qa/ui-tests.mjs — browser checks through headless Chrome (CDP, no
   puppeteer): R6 (branch selector on the roster page survives a change), X4
   (route gating for an Operations Manager, a 403 inside a page does not log out)
   and X5 (no horizontal page scroll at 390 px on calendar / roster / payroll).
   Needs: google-chrome on PATH, the web dev server on http://localhost:5173,
   the API on :5078, the QA users from seed.sql. Screenshots go to tests/qa/screenshots.
   ============================================================================ */
import { spawn, execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = process.env.QA_WEB ?? 'http://localhost:5173';
const API = process.env.QA_API ?? 'http://localhost:5078';
const PW = 'QaPass!2026';
const SQL_PW = process.env.SQLCMDPASSWORD ?? 'p@ssW0rd';
const PORT = 9333;
mkdirSync(join(HERE, 'screenshots'), { recursive: true });

function sql(query) {
  return execFileSync('sqlcmd', ['-S', 'localhost', '-U', 'sa', '-P', SQL_PW, '-C', '-I', '-h', '-1', '-W', '-d', 'MokaCo_HRMS', '-Q', 'SET NOCOUNT ON; ' + query], { encoding: 'utf8' }).trim();
}
const q = (s) => `N'${String(s ?? '').replace(/'/g, "''")}'`;
function check(id, kase, expected, actual, pass) {
  const act = String(actual).slice(0, 580);
  console.log(`${pass ? 'PASS' : 'FAIL'} | ${id} | ${kase} | expected=${expected} | actual=${act}`);
  sql(`EXEC dbo.QA_Check ${q(id)}, ${q(kase)}, ${q(expected)}, ${q(act)}, ${pass ? 1 : 0}`);
}
const note = (t) => console.log(`NOTE | ${t}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function login(user) {
  const r = await fetch(`${API}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: user, password: PW }) });
  return r.json();
}

/* ---- tiny CDP client ---- */
class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.events = []; ws.onmessage = (m) => this.onMessage(JSON.parse(m.data)); }
  onMessage(msg) {
    if (msg.id && this.pending.has(msg.id)) { const { res, rej } = this.pending.get(msg.id); this.pending.delete(msg.id); msg.error ? rej(new Error(msg.error.message)) : res(msg.result); }
    else if (msg.method) this.events.push(msg);
  }
  send(method, params = {}) { const id = ++this.id; return new Promise((res, rej) => { this.pending.set(id, { res, rej }); this.ws.send(JSON.stringify({ id, method, params })); }); }
  async evaluate(expression) { const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + JSON.stringify(r.exceptionDetails.exception?.description ?? '')); return r.result.value; }
  async navigate(url, wait = 3000) { await this.send('Page.navigate', { url }); await sleep(wait); }
  async screenshot(file) { const r = await this.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }); writeFileSync(file, Buffer.from(r.data, 'base64')); }
}

async function main() {
  const chrome = spawn('google-chrome', ['--headless=new', '--disable-gpu', '--no-sandbox', `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/qa-chrome-${process.pid}`, '--window-size=390,844', 'about:blank'], { stdio: 'ignore' });
  try {
    let version = null;
    for (let i = 0; i < 30 && !version; i++) { try { version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); } catch { await sleep(500); } }
    if (!version) { check('X5', 'headless Chrome available for the responsive checks', 'chrome started', 'chrome did not start', false); return; }
    const target = await (await fetch(`http://127.0.0.1:${PORT}/json/new?about:blank`, { method: 'PUT' })).json();
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res) => (ws.onopen = res));
    const cdp = new Cdp(ws);
    await cdp.send('Page.enable'); await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });

    const setSession = async (user) => {
      const t = await login(user);
      await cdp.navigate(`${WEB}/login`, 2500);
      await cdp.evaluate(`sessionStorage.setItem('mokaco.accessToken', ${JSON.stringify(t.accessToken)}); sessionStorage.setItem('mokaco.refreshToken', ${JSON.stringify(t.refreshToken)}); 'ok'`);
    };
    const metrics = () => cdp.evaluate(`({ path: location.pathname, sw: document.documentElement.scrollWidth, bw: document.body.scrollWidth, iw: window.innerWidth, text: document.body.innerText.slice(0, 400) })`);

    /* ---- X5: 390 px, no horizontal page scroll ---- */
    await setSession('qa.hr');
    const pages = [['calendar', '/bookings/calendar'], ['roster', '/attendance/roster'], ['payroll-runs', '/payroll/runs'], ['daily-attendance', '/attendance/daily']];
    for (const [name, path] of pages) {
      await cdp.navigate(`${WEB}${path}`, 4000);
      const m = await metrics();
      await cdp.screenshot(join(HERE, 'screenshots', `${name}-390.png`));
      const ok = m.sw <= m.iw && m.bw <= m.iw;
      check(`X5-${name}`, `${path} at 390 px has no horizontal page scroll`, `scrollWidth <= innerWidth (390)`, `documentElement.scrollWidth=${m.sw} body.scrollWidth=${m.bw} innerWidth=${m.iw} (screenshot tests/qa/screenshots/${name}-390.png)`, ok);
    }

    /* ---- R6: the branch selector on the roster page (approval banner) keeps its value after a change ---- */
    await cdp.navigate(`${WEB}/attendance/roster`, 4000);
    let hasSelect = await cdp.evaluate(`!!document.querySelector('input[aria-label="Branch"]')`);
    if (!hasSelect) {
      /* the approval banner (which carries the branch selector) renders only for a month that has a ROSTER_MONTH row: go back to August */
      await cdp.evaluate(`document.querySelector('button[aria-label="Previous month"]').click(); 'ok'`); await sleep(3000);
      hasSelect = await cdp.evaluate(`!!document.querySelector('input[aria-label="Branch"]')`);
      note(`R6: no branch selector on the current month; after moving to the previous month selector present=${hasSelect}`);
    }
    if (!hasSelect) {
      check('R6', 'roster page branch selector keeps the selected branch after a change', 'selector present', 'no branch selector on /attendance/roster in the current or previous month (the only one is inside the roster-approval banner, shown only when the month has a roster-month row)', false);
    } else {
      await cdp.evaluate(`document.querySelector('input[aria-label="Branch"]').click(); 'ok'`);
      await sleep(600);
      const picked = await cdp.evaluate(`(() => { const o = [...document.querySelectorAll('[role="option"]')].find((e) => e.textContent.trim() === 'QA Branch'); if (!o) return 'no option'; o.click(); return 'clicked'; })()`);
      await sleep(1500);
      const before = await cdp.evaluate(`document.querySelector('input[aria-label="Branch"]')?.value`);
      /* a change: move to the next month and back (re-fetches everything), then a real roster write that fires the live refresh */
      await cdp.evaluate(`document.querySelector('button[aria-label="Next month"]').click(); 'ok'`); await sleep(2500);
      await cdp.evaluate(`document.querySelector('button[aria-label="Previous month"]').click(); 'ok'`); await sleep(2500);
      const afterNav = await cdp.evaluate(`document.querySelector('input[aria-label="Branch"]')?.value`);
      const e1 = sql(`SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName=N'QA E1'`);
      const morning = sql(`SELECT ShiftId FROM attendance.SHIFT WHERE Name=N'Morning'`);
      const t = await login('qa.hr');
      await fetch(`${API}/api/roster/day`, { method: 'PUT', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${t.accessToken}` }, body: JSON.stringify({ employeeId: +e1, workDate: '2026-09-15', shiftId: +morning, isRestDay: false }) });
      await sleep(3000);
      const afterChange = await cdp.evaluate(`document.querySelector('input[aria-label="Branch"]')?.value`);
      sql(`DELETE FROM attendance.SHIFT_ASSIGNMENT WHERE EmployeeId=${e1} AND WorkDate='2026-09-15'`);
      check('R6', 'roster page branch selector keeps "QA Branch" after month navigation and after a roster change (live refresh)', 'QA Branch / QA Branch / QA Branch',
        `pick=${picked}; after pick=${before}; after month nav=${afterNav}; after change=${afterChange}`, picked === 'clicked' && before === 'QA Branch' && afterNav === 'QA Branch' && afterChange === 'QA Branch');
    }

    /* ---- X4: Operations Manager route gating and 403 handling ---- */
    await setSession('qa.ops');
    await cdp.navigate(`${WEB}/payroll/runs`, 3500);
    let m = await metrics();
    const denied = /permission|access denied|not allowed/i.test(m.text) || m.path !== '/payroll/runs';
    check('X4d', 'Operations Manager opening /payroll/runs (not in routeAccess for the role) sees an access-denied view, not the page', 'access denied view', `path=${m.path} text="${m.text.slice(0, 120).replace(/\n/g, ' ')}"`, denied);
    await cdp.navigate(`${WEB}/settings`, 3500);
    m = await metrics();
    /* /settings stays an open route on purpose (everybody's Preferences live there), so the refusal is
       a "No access" card BELOW the preferences — beyond the 400 characters metrics() keeps. Read the
       whole page, and also require that none of the system tabs is offered. */
    const st = await cdp.evaluate(`({ text: document.body.innerText, tabs: [...document.querySelectorAll('[role="tab"]')].map((t) => t.textContent.trim()) })`);
    const deniedAt = st.text.search(/no access|permission|access denied|not allowed/i);
    const systemTabs = st.tabs.filter((t) => /attendance|payroll|leave|workflow|booking|danger/i.test(t));
    check('X4e', 'Operations Manager opening /settings sees an access-denied view for the system settings (own preferences only, no system tabs)', 'access denied wording on the page, 0 system tabs',
      `path=${m.path} tabs=[${st.tabs.join(', ')}] denied="${deniedAt < 0 ? 'none' : st.text.slice(deniedAt, deniedAt + 90).replace(/\n/g, ' ')}"`,
      m.path !== '/settings' || (deniedAt >= 0 && systemTabs.length === 0));
    await cdp.navigate(`${WEB}/attendance/daily`, 4000);
    m = await metrics();
    check('X4f', 'Operations Manager opens /attendance/daily (ATTENDANCE_VIEW granted) normally', 'page shown, still logged in', `path=${m.path} text="${m.text.slice(0, 80).replace(/\n/g, ' ')}"`, m.path === '/attendance/daily' && !/permission/i.test(m.text.slice(0, 200)));
    /* a 403 through the app's own request wrapper must produce a message, not a logout */
    const r = await cdp.evaluate(`(async () => { const mod = await import('/src/api/client.ts'); const errMod = await import('/src/api/errorMessage.ts');
      try { await mod.apiRequest('/api/payroll/runs'); return { thrown: false }; }
      catch (e) { await new Promise((r) => setTimeout(r, 800)); return { thrown: true, status: e.status, message: errMod.getErrorMessage(e), path: location.pathname, token: !!sessionStorage.getItem('mokaco.accessToken') }; } })()`);
    check('X4g', 'a 403 from the API inside a page is shown as a message and does not log the user out', 'status 403, message "You don\'t have permission for this action", still on the page with a token',
      JSON.stringify(r), r.thrown === true && r.status === 403 && /permission/i.test(r.message ?? '') && r.token === true && r.path === '/attendance/daily');
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
  }
}
main().catch((e) => { console.error('UI tests crashed:', e); process.exit(1); });
