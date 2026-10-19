# QA report 3: deep test of the whole system (19 October 2026)

Branch `dev` in both repos (MokaCo.HRMS and mokaco-web-mantine). The shared copy of this report, with the relations
diagram, is the "MokaCo HRMS deep test" document. Nothing here has been deployed: the VM was not touched.

## 1. Summary

- **Scope:** every module (attendance, rosters, leave, workflow, payroll, bookings, people, security, the web app), the
  API ↔ SQL contracts, and how a change on one page flows through the tables into the other pages.
- **How:** 11 reviewers, one per area plus contracts, relations and a database rebuild. Every defect was reproduced on a
  database before it was fixed. Eight fix units then worked in parallel; the lead merged, integrated and fixed the
  cross-unit gaps.
- **The base schema is not in the repo** (production was restored from a backup), so a stand-in database was rebuilt
  from an inferred base plus all 67 repo scripts; 134 procedures exist only in production.
- **Found:** 167 finding IDs, about 105 distinct problems once duplicates are merged (§3 and §4), plus the relations
  breaks (§5).
- **Fixed:** all but the items in §7, with tests. Ten new SQL scripts, `docs/98` to `docs/107`, must be applied in
  order before the API is deployed; the API now checks this itself (§8).
- **Tests now:** `dotnet test` 1736/1736 against the rebuilt database (none skipped); 53 SQL scenarios in `tests/qa3`
  all pass; web `tsc` clean, `npm test` 168/168, lint 0 errors, build ok; `npm audit` 0 vulnerabilities; NuGet: no
  vulnerable packages. Every QA3 script applies twice without change.

### The ten worst problems found

1. Days after an employee left (or before they started) were counted as absences and deducted: a leaver's final payslip
   could go negative (basic 2600, left on 15 August: net −41.94).
2. A run could be approved after its inputs changed: an expense paid twice, an advance recovered twice (balance −300).
3. Separation settlements and leave payouts recorded after the leaving month was locked were never paid.
4. The salary tab edited salary rows in place: after a raise, both rows were paid (2400 instead of 1650).
5. A partly approved leave was charged for every requested day.
6. Retracting an approved salary advance or payroll adjustment always failed.
7. Two people could approve the same step at once; an approval landing after a cancel still created the advance.
8. "Copy previous month" and "Apply patterns" on the roster wrote into every branch.
9. Any signed-in user could read any request's payload by id, and by-id reads ignored branch scope (salaries included).
10. Leavers kept their login, their branch-manager post and their approvals.

## 2. How it was tested

- **Reviewers** read the code path end to end (page → service → endpoint → controller → repository → procedure → tables)
  and reproduced each finding on a database before reporting it. Reproductions are kept per area.
- **Rebuilt database:** `00_base_schema.sql` (inferred base, `INFERRED.md` lists every stand-in and its evidence) +
  the 67 repo scripts in apply order + reference rows. It is a stand-in: base-only procedures (Submit, Reject, Cancel,
  salary Set/End, SendToReview, booking writers, …) are approximations, so their exact live behaviour is checked on the
  test VM, not here.
- **Fix units:** A workflow (101), B attendance (100), C rosters (102), D leave (99), E payroll (103), F bookings (104),
  G security (105), W web and HR (106); the lead wrote 98 and 107. Each unit worked on its own branch and database,
  showed its repro failing before and passing after, and added scenario tests.
- **Stale repo copies (CON-7):** unnumbered scripts are older than production for at least 16 procedures. A script
  redefines such a procedure only behind a guard that stops the whole script if the live copy has a parameter it does
  not know; 107 edits the live text instead of redefining it.

## 3. Business-logic defects (wrong rules and calculations)

| # | Area | What was wrong | Fix | Where |
|---|---|---|---|---|
| 1 | People → attendance → payroll | Days before hire and after termination counted as absences and deducted (ROS-1, ATT-2, REL-1) | Attendance follows employment; payroll counts only hire..termination; roster rows after leaving removed; re-derived when the dates change | 100, 102, 103 |
| 2 | Rosters → attendance | Approving a roster never re-derived days already processed against the draft; readiness stayed blocked (ATT-1, ROS-2) | Approval re-derives the month; nightly safety net; "Re-derive month" button | 102, API |
| 3 | Leave | A partly approved leave was treated as leave on every requested day (ATT-8, LEV-2, PAY-8, REL-6); 2.5 approved unpaid days cost 300, not 250 | The approved span is stored (`ApprovedToDate`) and read by attendance, payroll, payslips, dashboard and auto-roster | 99, 100, 103 |
| 4 | Leave | A leave was priced once, at submission; later roster, holiday or transfer changes never re-priced it (LEV-4, REL-12, ROS-12) | Re-priced on the approved roster when the roster, holidays, branch or employment dates change; never inside a paid period | 99, 100, 102 |
| 5 | Leave | The year balance card subtracted last year's unused days (LEV-1): it showed 19, the truth was 26 | Year-close rows dated in the year they close; existing rows repaired | 99 |
| 6 | Leave | Carry-over expiry miscounted; "02-29" or a malformed date switched expiry off (LEV-6) | Netted per day; 02-29 → last day of February; the setting is validated on save | 99, API |
| 7 | Leave | Leave could be raised, approved or reversed on days already paid (LEV-11, WF-16) | Refused: "This period is paid — raise a payroll adjustment instead." | 99 |
| 8 | Leave | A leave year could not be reopened, and the workaround posted twice (LEV-9) | Guards; `usp_LeaveYear_Undo` (current year); only manual adjustments can be deleted | 99, API, web |
| 9 | Leave, payroll | Service length counted calendar boundaries, not whole years (LEV-12, PAY-13) | Whole years and months | 99, 103 |
| 10 | Leave, payroll | Inactive leave types still granted; payroll found types by name, so a rename changed pay (LEV-13, PAY-10, REL-7) | System codes; system types cannot be renamed or removed; lookups by id/code | 99, 103 |
| 11 | Workflow, leave | Withdraw, retract and reopen kept the reduced figure (LEV-7, WF-4) | The original figure is kept and restored | 99, 101 |
| 12 | Payroll | Settlements and leave payouts recorded after the leaving month was locked were never paid; a payout was never booked against the balance, so a moved date paid it twice (PAY-2, REL-14, LEV-8) | The next open primary pays them; a `TerminationPayout` ledger row; payout = balance at the termination date | 103 |
| 13 | Payroll | Locking a primary before month end lost later overtime, holidays, tips and absences (PAY-3) | An early lock needs the Owner's explicit choice and is recorded | 103, web |
| 14 | Payroll | Readiness was checked only when the run was created (PAY-4) | Generate and Approve check it again | 103 |
| 15 | Payroll | A run whose inputs changed could still be approved: expense paid twice, advance recovered twice, retracted items deducted; today's unfinished shifts counted (PAY-5, REL-3, ATT-11) | Every input fingerprinted; Approve refuses a stale run; a banner names who and what changed; completed days only | 103, API, web |
| 16 | Payroll | The salary tab edited rows in place: no lock check, overlapping rows, hard delete; a raise paid both rows (PAY-6, REL-2) | The tab uses "set from a date" / "end"; the raw routes are retired; a later row supersedes from its start date | 103, API, web |
| 17 | Payroll | Two NSSF or tax versions in force in one month were both applied (PAY-9) | One version per scheme, the one in force at period end; a new version closes the previous one | 103 |
| 18 | Payroll | Rates frozen when the run was created; a currency first used later converted to nothing (REL-11) | A draft re-reads rates at each generate; frozen from review; a currency without a rate is refused | 103 |
| 19 | Payroll | Exchange rates stored with 4 decimals: 1/89,500 became 0 (CON-9, the August blocker again) | `DECIMAL(28,12)`, `CHECK (Rate > 0)`, full-precision procedures | 103 |
| 20 | Payroll | Overtime hour rate read a setting that does not exist (always 8 h); payslip branch was today's; sick pay across month ends charged to the first month; payslip leave days counted calendar days (PAY-14, PAY-15, LEV-16, LEV-17) | Corrected | 103 |
| 21 | Payroll | Unpaid holidays counted outside approved roster months; tips one line per source; unpaid deductions could exceed the basic paid | Corrected | 103 |
| 22 | People, payroll | "Remove" dropped a month the person worked from payroll (REL-5) | Refused until they have left and been paid; a removed employee with activity in the period is still paid | 106, 103 |
| 23 | Attendance | Overtime approved after the day was processed was paid 0 (ATT-4) | The approval re-derives the day | 101, 100 |
| 24 | Attendance | Retracting an exit-permission approval left the day covered (ATT-5) | Re-derived on retract; applied at final approval | 101, 100 |
| 25 | Attendance | Editing a shift's times re-judged past days (ATT-7, ROS-9, REL-10) | A shift that has been worked keeps its times; HR creates a new shift | 100 |
| 26 | Attendance | Exit-variance rulings mispriced: "Overtime" paid twice; "Actual" charged unpaid minutes again (ATT-9) | Corrected | 100 |
| 27 | Attendance | The exit-permission month close never followed later changes to the day (REL-13) | The day's ledger row is re-posted when the day changes | 100 |
| 28 | Attendance | Manual entries ignored the approved-month rule; a half-day leave counted as a full day (ATT-13) | Same rules as the processor | 100 |
| 29 | Attendance | A worked holiday with a lost out-punch raised no anomaly and paid no premium | Anomaly raised | 100 |
| 30 | Attendance | Rest day ranked above holiday, against the handoff: a worked holiday on a rest day earned no premium (DB-4) | Precedence is now leave > holiday > rest day | 100 |
| 31 | Attendance, rosters | Holiday and transfer recomputes wrote future records, which then blocked edits (ATT-14, ROS-5) | Capped at today | 100, 102 |
| 32 | Rosters | A transfer moved approved roster days to the other branch silently (ROS-8, REL-9) | Both months are marked changed; gaps per branch of the day | 102 |
| 33 | Rosters | Holidays were reported as roster gaps (ROS-10) | Excluded | 102 |
| 34 | Rosters | "Worked without roster" sent HR to a page where the day was locked (ROS-6) | A missing row can be added on an unpaid day with no record in an approved month | 102 |
| 35 | Rosters, workflow | Roster approvals were routed by who submitted, not by the branch (WF-7) | Routed to the roster branch's manager; others refused | 102 |
| 36 | Workflow | Retract revived cancelled requests (WF-5); reopen skipped the create-time checks: a double leave (WF-6) | Refused | 101 |
| 37 | Workflow | Reversals of several types left their effects behind (WF-8, ROS-11) | Undo for leave, advance, adjustment, exit permission, overtime and roster approval; other types refused | 101 |
| 38 | Workflow | Auto-approval and version moves applied no effects; moves ignored the requester's tier chain and matched steps by number (WF-9, WF-10) | Effects applied; moves stay in the population, match by position | 101 |
| 39 | Workflow | "Same day" retract used the UTC day (WF-13) | Beirut day | 101 |
| 40 | Workflow | Tier chains were picked in the pre-D6 direction: a chain for "tier 2 and more senior" served everyone but the head, and new employees on the lowest tier would follow the most senior chain (LEAD-2) | Probe of the live submit + guarded rewrite to "tier X serves 1..X, narrowest first"; chain tier = any tier but the lowest | 107, web |
| 41 | People | A new employee without a chosen tier became tier 1, the head: head's chains and salary band (LEAD-1) | Lowest tier by default; the form requires a tier | 106, web |
| 42 | People | Leaving ended nothing outside payroll: leavers could still sign in and approve (REL-4) | Nightly, the day after leaving: login off, branch-manager post vacated, PINs freed, all logged; new requests refused after leaving | 106, 100, 99 |
| 43 | Bookings | Two paid bookings could overlap across midnight (BKG-3) | Clash test across dates | 104 |
| 44 | Bookings | Cleaning time was added twice: the hour after each booking was never offered (BKG-6) | Turnaround inside the booking | API |
| 45 | Bookings | Cancelled and no-show bookings showed a growing balance due (BKG-8) | They owe nothing | API, web |
| 46 | Bookings | The receipt hid the discount; the staff preview ignored discount and deposit tier (BKG-10, WEB-9) | The server quote is used everywhere | API, web |
| 47 | Bookings | The last bookable night's 00:00 slot was offered then refused (BKG-13) | Consistent window | 104 |
| 48 | Reports | Attendance summaries used an old absence formula (REL-15) | Partly: "unpaid absence days" = the payslip's short days, branch-scoped; filing by the branch of the day is open (§7) | 103, 105 |

## 4. Functionality defects (broken pages, buttons, calls, access)

| # | Area | What was wrong | Fix | Where |
|---|---|---|---|---|
| 1 | Workflow | Retracting or reopening an approved advance or adjustment always failed on a foreign key (PAY-1, WF-1, ATT-3, LEV-3) | Pointers cleared before the rows go | 101 |
| 2 | Workflow | Decisions were not concurrency-safe: two approvals of one step; an approval after a cancel (WF-2, PAY-11) | Row locks, expected step, "decided a moment ago — reload" | 101, 103 |
| 3 | Workflow | The Retract button called withdraw (WF-3, WEB-8) | Calls retract, asks for the password when needed | API, web |
| 4 | Workflow | "Ask the employee" saved an ordinary hold; "Hand to someone else" always failed (WEB-6, WEB-7) | Fixed; delegate candidates endpoint | 101, web |
| 5 | Workflow | A refused exit-permission withdrawal still committed the restored minutes (CON-1) | Rolled back | 101 |
| 6 | Workflow | The close e-mail could not announce a changed outcome (WF-15) | The reversal supersedes the queued mail | 101 |
| 7 | Workflow | Request-type filter needed WORKFLOW_CONFIGURE; role steps showed "A role" (WEB-12, WEB-13) | Fixed | API, web |
| 8 | Rosters | "Copy previous month" and "Apply patterns" wrote into every branch (ROS-3) | One branch, required end to end | 102, API, web |
| 9 | Rosters | The roster page wrote rest days over approved leave (ROS-4, LEV-5) | Leave days read from the approved requests; the rewrite removed | 102, web |
| 10 | Rosters | After a rejected re-submission the month could not be submitted again (ROS-7) | Fixed | 102 |
| 11 | Rosters | Bulk generate reported 0 employees (ROS-13, CON-5) | Fixed | 102 |
| 12 | Attendance | Punch processing could mark punches processed that were never judged (ATT-6) | Snapshot ids + application lock | 100 |
| 13 | Attendance | A failed correction still marked the anomaly corrected (ATT-10) | One transaction | 100 |
| 14 | Attendance | Remapping a device PIN silently did nothing (ATT-12, REL-8) | Refused, naming the current owner | 100 |
| 15 | Attendance | "Post exit-permission leave" reported nothing posted; an auto-approved exit permission opened `/requests/0`; "decide all" said "0 decided" (ATT-15, CON-3, CON-4, CON-6) | Correct results returned | 100 |
| 16 | Attendance | A quarantined punch blocked readiness forever | "Set aside" | 100, 103, web |
| 17 | Attendance | Exit-permission reads selected a renamed column (DB-3) | Fixed | 100 |
| 18 | Payroll | Employees could not see their payslips; web and API used different permissions (PAY-12, WEB-4, WEB-15) | PAYROLL_VIEW, REPORT_VIEW, "My payslips" | 103, API, web |
| 19 | Payroll | The adjustment form's component list was empty for the people raising it (WEB-10) | Fixed | web |
| 20 | Leave | Balance reads never returned "Adjusted" (LEV-14, CON-8); dead repository code (CON-10) | Fixed / removed | 99, API |
| 21 | Bookings | The staff calendar and forms could not show or take bookings after midnight (BKG-2, WEB-1) | Minute spans past 24:00 | API, web |
| 22 | Bookings | Payments on bookings that had left "Pending" were never reconciled (BKG-4) | Any status | 104, API |
| 23 | Bookings | Guest cancel failed for 7-digit numbers (BKG-5) | National-number match | 104 |
| 24 | Bookings | Booking mail ignored its own sender, SMTP account and WhatsApp template (BKG-7, CON-2) | Carried through to the worker | 104, API |
| 25 | Bookings | A deactivated room's future bookings vanished; a crafted >24 h span was stored wrong; blocks and rooms were not live; holds were not announced (BKG-11, BKG-12, BKG-14, WEB-16) | Fixed | 104, API, web |
| 26 | Bookings | The website and deposit switches read only "1", but the Settings page wrote "true" | Both read; Settings writes the row's own dialect | 104, API, web |
| 27 | Security | Anyone with a booking reference could cancel a pending website booking (BKG-1) | Closed on the server | 104, API |
| 28 | Security | Any signed-in user could read any typed request payload by id (SEC-1) | `[RequestVisible]` on every typed read | API |
| 29 | Security | By-id reads ignored branch scope; branch managers saw salaries; document download allowed a path outside storage (SEC-2, WEB-3) | `[InCallerScope]`; salaries HR/payroll/self only; path check | 98, API, web |
| 30 | Security | Request notes and mail had no visibility check; a shift swap could be raised for anyone (WF-11, WF-12) | Fixed | API |
| 31 | Security | Attendance summaries, raw logs and reports were not branch-scoped (ATT-16) | Scoped | 105, API |
| 32 | Security | A password change or disable did not end existing sessions (SEC-5) | Session stamp; signed out everywhere | 105, API, web |
| 33 | Security | Sign-in timing revealed usernames; no rate limits on login, refresh, `/iclock` (SEC-6) | Same cost; limits | API, web |
| 34 | Security | nginx trusted a client-sent Cloudflare IP header (SEC-4); no HSTS on the HRMS host | Only from Cloudflare ranges; HSTS | deploy scripts |
| 35 | Security | The JWT secret placeholder was accepted at startup | Refused | API |
| 36 | Security | Signature passwords, the leave decision's included, were not counted towards lockout | Counted; a locked account cannot sign | 105, API |
| 37 | Security | The user and role pick-lists were open to every signed-in user | WORKFLOW_CONFIGURE | API |
| 38 | Startup | The API would not start without the card-gateway (MPGS) keys (SEC-3) | Starts; online deposits off | API |
| 39 | Deploy | The API could run ahead of its SQL scripts, failing feature by feature | Deploy guard: `/health` `"schema"`, deploy-test refuses, deploy-api warns | API, deploy |
| 40 | Database | `workflow_prereqs.sql` dropped the procedure every self-service screen needs and failed to recreate it (DB-1) | Fixed | repo script |
| 41 | Database | Repo copies older than production for ≥16 procedures (CON-7) | Guards in every QA3 script; a live snapshot is still needed (§7) | 98–107 |
| 42 | Tests | Database tests deadlocked in parallel (DB-2) | One serial collection | tests |
| 43 | Web | Decimal boxes turned 0.5 into a full day and 12.50 into 50 (WEB-5, the leave policy's fixed entitlement too) | Raw value kept, converted once at save | web |
| 44 | Web | UTC times shown as Beirut time (WEB-11); buttons offered that the API refuses (WEB-14); older answers overwrote newer ones (WEB-17) | Fixed | web |
| 45 | Web | Arabic plural forms missing; about 30 pages in English only (WEB-18) | Plurals; the main pages translated | web |
| 46 | Web | `npm run lint` broken (WEB-19) | ESLint config | web |
| 47 | Web | The shift-swap partner list was empty for staff (WEB-2) | New endpoint | 106, API, web |
| 48 | Web, people | Chain-builder pickers needed ROLE_MANAGE/USER_MANAGE; tier boxes offered tiers the server refused; a branch with active people could be deactivated; the copy note flagged equal audiences | Fixed | 106, 107, API, web |
| 49 | Settings | An empty boolean was saved as ""; the booking SMTP password and API key shown in clear; the test neutraliser left the booking SMTP live | Fixed | web, deploy |
| 50 | API | `GET /api/leave/days` unused and unscoped | Removed | API, web |
| 51 | Dependencies | Vulnerable packages: `System.Security.Cryptography.Pkcs` (2 advisories), `xlsx` (high, unused), three build-time npm packages | Updated or removed; audits clean | API, web |

## 5. Relations between pages and tables

Fifteen flows were traced from the page that writes, through the tables, to every page that reads (diagram in the
shared document):

1. Employee form → `EMPLOYEE` (+ branch history) → branch of the day → day computation → attendance records → lists,
   readiness, payroll.
2. Roster / auto-roster → `SHIFT_ASSIGNMENT` → roster approval → approved month → day computation → anomalies →
   readiness → payroll run.
3. Devices → raw punches (PIN → employee) → processing → day computation; unknown PIN → quarantine → map → replay.
4. Shifts page → `SHIFT`, read live by every later day computation.
5. Holidays page → `HOLIDAY` → day recompute → holiday work / unpaid holiday; leave cost.
6. Leave request → approval → leave ledger + attendance "Leave" → payroll (unpaid, sick tiers, payout) → balances.
7. Exit permission → day computation → month close → leave ledger + unpaid days → payroll.
8. Overtime request → day computation + nightly stamp → payroll overtime.
9. Salary tab → `SALARY_COMPONENT` → payroll proration and day/hour rates.
10. Exchange rates → run rates → conversions in payroll and statutory reports.
11. Component and leave types → payroll lookups.
12. Settings → read at run time by the day rule, leave cost and payroll.
13. Run approval → "period paid" → every HR writer refuses those days; advances, expenses, adjustments consumed.
14. Users and accounts → login, branch-manager and role approvers, scope.
15. Reports and dashboard → read records and ledger, filed by branch.

| Break | Edge | Status |
|---|---|---|
| REL-1 | Hire/termination dates → roster, day computation, absences, payroll | Fixed (100, 102, 103) |
| REL-2 | Salary tab → salary rules → payroll | Fixed (103) |
| REL-3 | Any input changed during review → payslips already generated | Fixed (103) |
| REL-4 | Termination → login, manager post, approvals, PINs, requests | Fixed (106); open requests reported, not cancelled (§7) |
| REL-5 | "Remove" → payroll drops the worked month | Fixed (106, 103) |
| REL-6 | Approved days → day computation and payroll | Fixed (99, 100, 103) |
| REL-7 | Type rename / delete → payroll lookups by name | Fixed (99, 103) |
| REL-8 | Device enrolment → PIN silently kept by the old owner | Fixed (100) |
| REL-9 | Transfer → approved roster rows re-filed silently | Fixed (102) |
| REL-10 | Shift edit → past days | Fixed (100) |
| REL-11 | Rates frozen at creation → later currencies | Fixed (103) |
| REL-12 | Holiday added → leave already approved | Fixed (99, 100) |
| REL-13 | Day changed → exit-permission month close | Fixed (100) |
| REL-14 | Termination payout → leave ledger | Fixed (103) |
| REL-15 | Records → summaries and reports (formula, branch, scope) | Partly fixed (103, 105); filing by branch of the day open |
| REL-16 | Settings → hour rate key; nothing re-derives after a setting change | Fixed key (103); "Re-derive month" covers rosters (102) |

## 6. Decisions taken (no input was asked for)

The first 22 are in the shared document's decisions table. Added while fixing:

| Area | Decision | Why |
|---|---|---|
| Day status | Leave > holiday > rest day | The handoff's order; a worked holiday on a rest day earns the premium |
| Tier chains | A chain set to tier X serves tiers 1..X, the narrowest first, the default chain last; the lowest tier cannot be chosen (it would be everybody) | D6 (1 = head) and the chain builder's own wording |
| Pick-lists | User and role names need WORKFLOW_CONFIGURE | Only the chain builder uses them; usernames are half a sign-in |
| Deploy guard | The API names missing scripts in its log and on `/health`; test deploys refuse, production deploys warn | A missing script fails far from its cause |
| Salary rows | One open row per employee, type and currency; a later row supersedes from its start date | A raise paid both rows |
| Stale runs | Compared by values, not timestamps; runs generated before 103 need one regenerate | Timestamps change without the inputs changing |
| NSSF / tax | A new version closes the previous one automatically | Two versions were both applied |
| Settlements | The catch-up goes back to the first approved primary only | Older months were settled outside the system |
| Leavers | The login stays on for a rehire on another record or for the last account that can manage users; open requests are listed, not cancelled | Never lock everyone out; cancelling is the workflow engine's job |
| Remove | Allowed after leaving, when every employed month is in a locked primary and nothing is open | Removing must not drop pay |
| Leave reversal on paid days | Refused; HR raises an adjustment | One correction path after a lock |
| Shifts | Worked shifts keep their times; HR creates a new shift | Past days must not be re-judged |

## 7. Not fixed here

| Item | Why | Next step |
|---|---|---|
| Website pay token for `/pay` and `/release` | The website is another repo; the server-side hole is closed | Add a per-booking secret on the website |
| Base-only workflow procedures (Reject, Cancel, Hold, Resume, Delegate) lack the new lock pattern | Their live text is not in the repo | Script them from production, then add the lock |
| `usp_Booking_SetStatus` same-date overlap; `fn_LocalNow` on the 25 October DST change | Live-only code | Check on the test VM |
| A live snapshot of the procedures newer than the repo (CON-7); verify the live `usp_ExitPermission_Decide` | Needs the production database | Script `sys.sql_modules` into a numbered snapshot |
| 107 when the live submit's text differs from the repo's | Rewriting unseen code blind is unsafe | 107 prints an OWNER CHECK with the lines; change them by hand |
| "Tier" approver steps (walking up the hierarchy) | Base-only | Check on the test VM |
| Report filing by the branch of the day (REL-15) | Needs the live report procedures | Next pass |
| A termination recorded after its month was locked: the extra days paid are not recovered automatically | Needs a decision on clawback | Raise an adjustment |
| A leaver's open requests are listed, not cancelled or re-routed | The engine's base procedures | Workflow follow-up |
| Clearing a termination date does not switch the login back on or restore PINs | Rare; by hand | HR re-enables |
| `ClearMachineLog` gap (a punch erased between pull and clear) | Device protocol | Documented |
| Booking features: discount and deposit-tier editing; refunds and discounts in the report | Features, not defects | Backlog |
| Read-committed snapshot (RCSI) against deadlocks during payroll generation | A database setting | Owner decides; recommended |
| `BOOKING_VIEW` seed; moving a PIN to another employee; "use approved permissions again" button | Small follow-ups | Backlog |
| `tests/qa` and `tests/qa2` were updated but not re-run | They need their own environment | Run on the test VM |

## 8. Applying the fixes

1. **Back up** both databases first.
2. **Test (VM):** `bash deploy/sync-test.sh` on the laptop; on the VM apply the scripts **in order** to the test
   database: `deploy/test-env/apply-sql-test.sh docs/98_qa3_security.sql docs/99_qa3_leave.sql
   docs/100_qa3_attendance.sql docs/101_qa3_workflow.sql docs/102_qa3_roster.sql docs/103_qa3_payroll.sql
   docs/104_qa3_booking.sql docs/105_qa3_security.sql docs/106_qa3_webhr.sql docs/107_qa3_tier_chains.sql`. Re-run
   `deploy/test-env/neutralise-test-db.sql`. Then `bash ~/test-env/deploy-test.sh`; it stops the test API and lists the
   scripts if any is missing.
3. **Read each script's OWNER CHECK lines:** 99 (R3 duplicates with different days), 100 (repairs R1–R7), 102 (pending
   approved months), 103 ("PAID TWICE in locked months", same-day salary starts, payouts that differ from the balance,
   rates ≤ 0), 106 (Operations Manager grant), 107 (the rule the live submit follows and the active tier chains).
4. **After the API is up:** regenerate each open payroll run once; Operations Managers sign in again; review who is on
   tier 1 (query in 106's header); preview the first leavers' sweep with
   `BEGIN TRAN; EXEC hr.usp_Employee_ApplyDueTerminations; ROLLBACK;`.
5. **Production ("to production"):** merge `dev` into `main`, `sync-prod.sh`, apply 98–107 in order with
   `sqlcmd -C -I -b`, then `bash deploy/deploy-api.sh` (it also rewrites the nginx client-IP map and warns if a script is
   missing), `bash deploy/deploy-web.sh`, `HSTS_ONLY=1 bash deploy/enable-tls.sh`, and re-run
   `enable-google-gate.sh --test|--all` if the gate is on. `/health` must say `"schema":"ok"`.

## 9. Test state

| Suite | Result |
|---|---|
| `dotnet test` with the rebuilt database (`MOKACO_TEST_CONNECTION`) | 1736 / 1736 |
| `dotnet test` without a database | all pass; the database tests skip |
| `tests/qa3/*/*.sql` (attendance 7, booking 7, leave 6, payroll 6, roster 8, security 4, webhr 6, workflow 9) | 53 / 53 |
| QA3 scripts 98–107 applied twice | no error, no change the second time |
| Web: `tsc -b`, `npm test`, `npm run lint`, `vite build` | clean, 168 / 168, 0 errors, ok |
| `npm audit`, `dotnet list package --vulnerable` | 0, none |
