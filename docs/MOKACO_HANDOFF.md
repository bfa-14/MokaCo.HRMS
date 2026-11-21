# MokaCo HRMS + Online Booking — developer handoff

**Version:** 2026-11-14 · **Status:** live on a production VM, in rehearsal use · **Audience:** a developer or an AI agent taking over the codebase.

This document is the single briefing for continuing the project: what the business is, what exists, every rule the software enforces, why it was built that way, and what is still open. It contains no passwords, keys or tokens — those live only in `appsettings.Local.json` (developer machine, git-ignored) and `/etc/mokaco/api.env` (server, root-owned).

---

## 1. The business

**Moka & Co** (brand "MOKA & CŌ", tagline *Grounded in History*) is a specialty-coffee company in Beirut, Lebanon. It runs branches with shift-based staff (baristas, waiters, supervisors, office roles), and it rents **meeting rooms and a podcast studio by the hour** to guests.

Two sides of the same system:

1. **HRMS** — the back office for the staff: employees, rosters, fingerprint attendance, leaves, requests and approvals, Lebanese payroll in USD and LBP, reports.
2. **Online booking** — the public website takes room bookings that land directly in the same database and appear to staff in the HRMS.

Rooms (the room **code** is the contract between website and HRMS; never change a code):

| Code | Room | Seats | Price/hour |
|---|---|---|---|
| `r1` | Mokha | 6 | 20 USD |
| `r2` | Sana'a | 8 | 22 USD |
| `r3` | Haraz | 10 | 26 USD |
| `r4` | Aden | 6 | 20 USD |
| `pod` | The Podcast Room | 4 | 38 USD |

Opening hours for rooms: 07:00 → 01:00 (next day). Prices, hours, add-ons and availability are served **live from HRMS**; the website only renders them.

---

## 2. System landscape

| Piece | Repo / location | Stack |
|---|---|---|
| Database | `MokaCo_HRMS` (SQL Server 2025) | T-SQL, 8 schemas, ~270+ stored procedures |
| API | GitLab `bfa.27092024-group/mokaco.hrms_backend` → local `MokaCo.HRMS` | .NET 8, Dapper, Quartz jobs, SignalR, QuestPDF |
| Back-office web | GitLab `bfa.27092024-group/mokaco-web-native` → local `mokaco-web-mantine` | React 19, Vite, Mantine 8, TanStack Table, react-hook-form, i18next (en/ar + RTL) |
| Public website | GitHub `ridarammal/mokanco-lb` | Astro 7, zero-JS except the booking scripts, strict CSP |
| Attendance device | ZKTeco **UA300 Pro**, SN BZD5251201566, LAN 192.168.45.12, TCP 4370 | pull worker (LAN) or ADMS push to `/iclock` |

Local development paths (Ubuntu 26.04, user `bilal`):

```
/home/bilal/VSProjects/Mokaco-Project/MokaCo.HRMS          # API + SQL scripts (docs/) + test suites (tests/)
/home/bilal/VSProjects/Mokaco-Project/mokaco-web-mantine   # HRMS web app
/home/bilal/VSProjects/Mokaco-Project/mokanco-lb           # public website
```

Dev ports: API `5078`, HRMS web `5173` (Vite proxies `/api` and `/hubs` to 5078), website `4321`.
Databases on the laptop: `MokaCo_HRMS` (reference copy of real data) and `MokaCo_HRMS_Dev` (where development and the QA suites run).

Production: a Linux VM (public IP), SQL Server **Express** (free for production; Developer edition is not licensed for production), API behind nginx with TLS, HRMS web served as static files, secrets in `/etc/mokaco/api.env`, nightly `BACKUP DATABASE` from cron (Express has **no SQL Server Agent**).

---

## 3. Conventions that the code depends on

These are not preferences; breaking them has broken the system before.

1. **Procedures only.** The repository layer (Dapper) calls stored procedures. A handful of places use inline or dynamic SQL (the nightly reconciler, the generic reference-counter), which is why the application login needs `db_datareader` + `db_datawriter` + `EXECUTE`, not `EXECUTE` alone.
2. **`QUOTED_IDENTIFIER ON` always.** Filtered unique indexes exist; a procedure compiled with the option off breaks DML at runtime, not at creation. Apply scripts with the VS Code *SQL Server (mssql)* extension or `sqlcmd -I`. Never plain `sqlcmd`.
3. **Refusals are `RAISERROR(msg, 16, 1)` followed by `RETURN`** (and `ROLLBACK` inside a transaction). RAISERROR does **not** abort the batch, not even under `XACT_ABORT`; a missing `RETURN` lets the procedure continue and commit. This single mistake caused several historic data bugs.
4. **Nested procedure results are captured with `INSERT … EXEC` and then checked** (`IF NOT EXISTS(SELECT 1 FROM @Result) ROLLBACK; RETURN;`). A nested refusal is invisible otherwise.
5. **Idempotent numbered scripts.** Every schema or logic change is a new numbered file in `MokaCo.HRMS/docs/` (`CREATE OR ALTER`, `IF NOT EXISTS` guards, re-runnable). The live database is never changed by hand.
6. **Beirut time everywhere.** `TimeZoneInfo` "Middle East Standard Time" / `AT TIME ZONE`; never `DateTime.Now` or bare `GETDATE()` for "today". Punch times are the terminal's wall clock.
7. **Money is explicit.** USD is the primary currency; LBP amounts are converted with the **rate snapshotted on the payroll run**, stored as `DECIMAL(28,12)`.
8. **Secrets never in git.** `appsettings.json` holds placeholders; real values in `appsettings.Local.json` (dev, ignored) and `/etc/mokaco/api.env` (prod, `root:600`, read by the systemd unit as `ConnectionStrings__…`, `Jwt__…`, `MPGS_*`).
9. **One source of truth per repo.** HRMS develops on **GitLab** and the server pulls from GitLab; the website lives on **GitHub**. Never chain GitLab → GitHub → server.

---

## 4. Database map

Schemas: `core`, `security`, `hr`, `attendance`, `workflow`, `payroll`, `report`, `booking`.

Objects worth knowing (names are the live ones; verify with `sys.sql_modules` before editing):

**core** — `SETTING` (the configuration table behind the Settings page: key, value, data type, description, section, sort), `EXCHANGE_RATE` (one row per from/to/type), `EMAIL_OUTBOX` (all notifications), `HOLIDAY` + `fn_IsHoliday`.

**security** — `USER`, `ROLE`, `USER_ROLE`, `PERMISSION`, `ROLE_PERMISSION`; password hashing with Argon2; signature passwords for approvals.

**hr** — `EMPLOYEE` (with `Email`, `Phone`, `PreferredLanguage`, `NssfNumber`, `BranchId` = *today's* branch), `EMPLOYEE_BRANCH_HISTORY` + `fn_EmployeeBranchOn`, `BRANCH`, `DEPARTMENT`, `POSITION`, `APPROVAL_TIER` (seniority tiers, 1 = head, with `Min/MaxBasicSalary` bands), `LEAVE_TYPE`, `LEAVE_POLICY`, `LEAVE_LEDGER`, `vw_LEAVE_BALANCE`, `COMPONENT_TYPE`, `DOCUMENT`.

**attendance** — `DEVICE`, `RAW_LOG` (punches; `DEVICE_PUNCH_QUARANTINE` is a view over punches with no employee), `ATTENDANCE_RECORD` (one row per employee-day), `SHIFT`, `SHIFT_ASSIGNMENT` (the roster), the roster month/header row with its approval state, anomalies, corrections, `fn_AttributedWorkDate`, `usp_Attendance_ComputeDay` (**the** day rule), `usp_Attendance_ProcessRawLogs`, `usp_Attendance_ReprocessDay`, `usp_Attendance_MarkAbsentees`, `usp_Attendance_MarkLeaveDays`, `usp_Attendance_PayrollReadiness`, `usp_Attendance_GetWorkedWithoutRoster`. Script 108 (days that are not on the roster): `UNROSTERED_DAY_DECISION` (every decision, with who, when and the punches it answered), `fn_UnrosteredDays` (the one definition of such a day), `fn_MayDecideUnrostered`, `usp_UnrosteredDay_GetList` / `_Decide` / `_Reopen`, and `usp_PayrollReadiness_Get` (the readiness answer the API reads; the older procedure keeps its 11 columns for SQL callers).

**workflow** — `REQUEST_TYPE`, `REQUEST_DEFINITION` (versioned chains) and its steps, `REQUEST_INSTANCE`, `REQUEST_STEP`, `WORKFLOW_SIGNATURE`, `REQUEST_REVERSAL`, typed payload tables (`LEAVE_REQUEST`, `EXIT_PERMISSION`, `OVERTIME`, `SHIFT_SWAP`, `SALARY_ADVANCE_REQUEST`, `PAYROLL_ADJUSTMENT_REQUEST`, `EXPENSE_REIMBURSEMENT`, `TIP_DISTRIBUTION`, `ONBOARDING`, `SEPARATION`, `AVAILABILITY_CHANGE`, `ROSTER_APPROVAL`), `fn_ResolveApprover`, `fn_CanUserActOnStep`, `usp_Request_Submit/Approve/Reject/Hold/Resume/Cancel/RetractLastDecision/WithdrawDecision/Reopen/MoveToVersion`, `usp_Request_ApplyApprovalEffects`.

**payroll** — `SALARY_COMPONENT` (per employee, effective-dated), `PAYROLL_RUN`, `PAYROLL_RUN_RATE` (frozen rates), `PAYSLIP`, `PAYSLIP_LINE`, `SALARY_ADVANCE`, `PAYROLL_ADJUSTMENT`, NSSF/tax configuration tables, `fn_ToPrimary`, `fn_RunRate`, `fn_IsPeriodPaid`, `usp_AssertPeriodOpen`, `usp_PayrollRun_Create/Generate/SendToReview/Approve/Cancel`, `usp_Payslip_SetPayment`, `usp_Payslip_GetMyStatus`.

**booking** — `ROOM`, `ROOM_HOURS` (`OpenMin`/`CloseMin`), `ROOM_ADDON`, `ROOM_DISCOUNT` (by hours; `RoomId NULL` = applies to all), `DEPOSIT_TIER`, `BOOKING` (+ computed `StartMin`/`EndMin`/`Hours`, `BookingRef`, `DepositPercent`, `DiscountPercent/Amount`, `HoldExpiresUtc`, gateway ids, `CancelledBy`, `RefundAmount`, `RefundStatus`), `BOOKING_ADDON`, `BOOKING_PAYMENT` (refunds are negative rows with `IsRefund = 1`), `BOOKING_BLOCK` (staff blocks), `GATEWAY` / `GATEWAY_CONFIG` (script 119: the mode in use and the encrypted keys of the two payment gateways), `PAYMENT_EVENT` (the payment log), `GATEWAY_TEST` (test payments opened from HRMS), `BOOKING.PaymentMode`, `fn_LocalNow`, `fn_DepositPercent`, `fn_PriceQuote`, `fn_RefundDue`, `fn_MailKindForStatus`, and the public procedures listed in §7.8.

**report** — reporting procedures (daily/monthly attendance, payroll, bookings).

---

## 5. Roles and permissions

Roles in use: **Owner**, **General Manager** (also spelled `GeneralManager` in some procedures), **HR**, **Admin**, **Operations Manager**, **Manager** (branch manager), **Employee**.

Permission codes (`security.PERMISSION`, shown as module cards on Security → Role Permissions):

```
EMP_VIEW, EMP_EDIT, EMP_VIEW_ALL
ATTENDANCE_VIEW, ATTENDANCE_CORRECT, ATTENDANCE_IMPORT, ATTENDANCE_MANAGE, DEVICE_MANAGE
OFFROSTER_TODAY, OFFROSTER_PAST, BOOKING_ROOMS, BOOKING_REPORT, BOOKING_PAYMENTS, BOOKING_PAYMENTS_MANAGE, GATEWAY_ADMIN, SHIFTS_VIEW_BRANCH, PREP_BOOK_VIEW, PREP_BOOK_MANAGE
LEAVE_POLICY_MANAGE, ORG_MANAGE, COMPONENT_MANAGE, CORE_MANAGE, SETTING_MANAGE
PAYROLL_VIEW, PAYROLL_RUN, PAYROLL_APPROVE
REQUEST_RAISE_SELF, REQUEST_RAISE_OTHERS, REQUEST_VIEW_ALL
WORKFLOW_CONFIGURE, WORKFLOW_VERSION_MOVE, SIGNATURE_MANAGE
ROLE_MANAGE, USER_MANAGE, REPORT_VIEW, BOOKING_MANAGE, SYSTEM_RESET
```

Rules:

- **The database is the authority** for workflow acts (who may approve, delegate, retract). The API maps SQL refusals to clean HTTP statuses; the UI only hides what the user may not do. Every other write endpoint carries `[HasPermission(...)]`, and `Program.cs` sets a fallback policy requiring an authenticated user (with `[AllowAnonymous]` on login, the public booking endpoints, the SignalR negotiate route and the device `[DeviceApiKey]` endpoints).
- **Attendance can only be edited by permission.** No employee may edit attendance — their own included; they raise a correction or an exit-permission request instead. (This was a real hole: every logged-in user could edit any attendance record.)
- **Branch scoping (`EMP_VIEW_ALL`).** Holders (Owner, General Manager, HR, Admin) see everyone. Anyone else sees only themselves plus the employees of the branches they manage, where "branch" means the employee's branch **on the day the row is about** (`fn_EmployeeBranchOn`), so a transfer doesn't rewrite history. Implemented inside the procedures through a trailing `@CallerUserId` parameter (NULL = the system itself: jobs and procedure-to-procedure calls see everything). Scoped procedures: employee list, attendance lists (range, anomalies, exit variances, worked-without-roster, pending corrections), roster reads (range, gaps). **Operations Manager and Manager are scoped** — grant them `EMP_VIEW_ALL` if they should see all branches.
- **Who decides a day that is not on the roster (`OFFROSTER_TODAY`, `OFFROSTER_PAST`, script 108).** A day somebody punched on that the approved roster does not know is decided by whoever holds the permission of its date: today's days, or past days. It is read **from the role tables by the procedure at the moment of the decision** (not from the token), inside the same branch scope as everything else, so ticking or un-ticking it on Security → Role Permissions counts at once. The same two permissions guard the Roster page (`usp_Roster_AssertEditable`): a missing past day of an approved month needs `OFFROSTER_PAST` (it used to be "whoever holds `EMP_VIEW_ALL`"), and a missing row for today for somebody who has already punched needs `OFFROSTER_TODAY`. Default grants were made **once**, when script 108 created the codes: today to Manager, HR and every role holding `ATTENDANCE_MANAGE`; past days to HR and every role holding both `ATTENDANCE_MANAGE` and `EMP_VIEW_ALL` - so nobody lost what they could do before. A re-run never grants again.
- **Signature passwords**: steps (or approvers) marked as requiring a signature need the user's password with every decision; it is verified *before* any procedure runs, so a wrong password writes nothing. There is no grace period — every signed decision asks again.
- **Employee role hygiene**: the Employee role must not hold `REQUEST_RAISE_OTHERS`, `REQUEST_VIEW_ALL` or `WORKFLOW_CONFIGURE`.
- `SYSTEM_RESET` / setting `AllowSystemReset` wipes transactional data. Keep it off.

---

## 6. Settings that change behaviour

All in `core.SETTING`, surfaced on the Settings page grouped by section.

**Attendance** — `AttendanceToleranceMinutes` (default 10), `PunchDirectionMode` (`Alternate`), `PunchDebounceMinutes` (1), `OvernightAttributionHours` (4), `FullDayThreshold` (1.00), `ExitLeaveBasis` (`Actual` | `Approved`), `MachinePullEnabled`, `MachinePullAutoProcess`. The length of a working day is NOT a setting (`StandardWorkDayHours` was removed by script 117): it is each shift's own hours.

**Leave** — `LeaveCountsRestDays` (0), `LeaveAllowNegativeBalance` (0), `LeaveCarryOverMaxDays`, `LeaveCarryOverExpiresOn` (MM-DD, empty = never), `LeavePayoutOnTermination` (1).

**Payroll** — `StandardWorkingDaysPerMonth` (26), `PayrollRateType` (`Official` | `NonOfficial` — which exchange rate a run snapshots), `TaxFamilyDeductionAnnualUsd`, NSSF rates and ceiling, `HolidayWorkRate` (2.0), `OffRosterBlocksPayrollFrom` (a month `yyyy-MM`, DataType `month`: from that month on, an undecided day that is not on the roster blocks the payroll run of its month; before it such days are only counted; empty = never. Script 108 set it to the month after the one it was first applied in).

**Booking** — `BookingWebsiteEnabled`, `BookingApiKey` (server-to-server callers), `BookingCorsOrigins`, `BookingSiteUrl`, `BookingNotifyEmail`, `BookingDepositRequired`, `BookingWhishEnabled` (offers Whish beside the card; script 118), `BookingDepositFloor`, `BookingHoldMinutes` (15), `BookingTimeZone`, `BookingLeadMinHours`, `BookingLeadMaxDays`, `BookingMaxHours`, `BookingCancelHours`, `BookingTurnaroundMinutes` (5), `BookingDepositRefundableOnGuestCancel` (0), `BookingFromEmail` (`bookings@mokanco.com.lb`), `BookingFromName`, `BookingSmtpHost/Port/User/Password`, `BookingEmailOnRequest/OnConfirm/OnCancel/OnRefund`, `BookingStaffAlert`, `BookingWhatsAppOnRequest/OnConfirm/OnCancel`, `BookingWhatsAppTemplate`, `BookingWhatsAppLang`.

**Notifications** — SMTP host/port/user/password/SSL for HR mail, `WhatsAppEnabled`, `WhatsAppApiUrl`, `WhatsAppPhoneNumberId`, `WhatsAppToken`, `WhatsAppTemplate`.

API-level configuration (not in the database): `ConnectionStrings:MokaCo`, `Jwt:*`, `MPGS_BASE`, `MPGS_MERCHANT_ID`, `MPGS_API_PASSWORD`, `MPGS_API_VERSION`, `MPGS_TEST_3DS_BYPASS`, `BOOKING_SITE_URL`, `API_PUBLIC_URL`, and for Whish `WHISH_BASE`, `WHISH_CHANNEL`, `WHISH_SECRET`, `WHISH_WEBSITE_URL`. Since script 119 the two gateways' KEYS can also be entered in HRMS (Settings → Payment gateways), for test and for live, stored encrypted in `booking.GATEWAY_CONFIG`; the server file's keys are then the fallback (see §7.7). `BOOKING_SITE_URL` and `API_PUBLIC_URL` stay in the server file.

---

## 7. Modules, features and business rules

### 7.1 Employees and organisation

Employees belong to a branch, a department and a position, and carry a **seniority tier** (`APPROVAL_TIER`, **1 = head** of the hierarchy, 9 = lowest; the direction was flipped deliberately — decision D6). Tiers drive approval chains and salary bands: a tier may define `MinBasicSalary` / `MaxBasicSalary`, and a trigger on `SALARY_COMPONENT` refuses a basic salary outside the employee's band. **An employee saved without a tier gets the lowest tier**, never tier 1 (script 106; the form requires one).

**Leaving** (script 106): access ends the day after the termination date. The nightly job disables the login (not for a rehire on another record, nor the last account that can manage users), vacates the branch-manager post and frees the device PINs, and logs each effect in `hr.EMPLOYEE_TERMINATION_EFFECT` with the open requests still waiting on the person (listed, not cancelled). Attendance, rosters and payroll count only hire date … termination date. **Remove** (soft delete) is refused until the person has left, every month they worked is in a locked primary run and nothing is open; a removed employee with activity in a period is still paid. A branch with active people cannot be deactivated.

- Creating an employee **requires phone and e-mail** (notifications depend on them). Editing an older employee without them only warns.
- **Branch transfers are dated.** Changing the branch asks for an effective date and writes `EMPLOYEE_BRANCH_HISTORY`; `EMPLOYEE.BranchId` always means "the branch today" and a future-dated transfer becomes current on its day via a nightly job (`usp_EmployeeBranch_ApplyDue`). A transfer is refused before the hire date, before a later transfer already on file, or inside a period already paid for that employee. Everything that reports by branch resolves the branch **as of the work date**.
- Reference data (leave types, component types, positions, departments, branches) is **hard-deleted only when nothing references it**; otherwise the refusal names what uses it ("used by 12 employees and 340 payslip lines") and offers *Deactivate*. Inactive rows are hidden from pick-lists and can be reactivated.
- Org chart, documents per employee, salary tab, leave tab (with balances), attendance tab.

### 7.2 Attendance

**Punches.** The device pushes (ADMS → `/iclock`) or is pulled over TCP 4370 by `MachinePullWorker`. Punches are de-duplicated by hash and by `PunchDebounceMinutes`; direction is derived in `Alternate` mode. A punch from a device user id that maps to no employee is **quarantined** (visible to HR as "Unknown device punches"); mapping it to an employee replays those punches into the correct days. Punches arriving for a day that was already processed trigger an automatic re-derive of that day.

**Which day a punch belongs to** — `fn_AttributedWorkDate`: an early-morning punch within `OvernightAttributionHours` (4h) after the end of an overnight shift belongs to the **previous** work date; guards prevent stealing today's own shift. Reprocessing selects punches by *attributed* date, not calendar date (a bug that once stranded 27 overnight punches and blocked payroll).

**The day rule** — one object, `usp_Attendance_ComputeDay(@EmployeeId, @WorkDate)`; every path calls it (process, reprocess, exit-permission apply, leave marking, absentee marking). Given the rostered shift (Start, End, Break, Grace, Standard = End − Start − Break) and the punches:

```
EffectiveIn        = max(FirstIn, ShiftStart)                  -- early arrival is not work
                     (unless an approved OVERTIME request covers pre-shift minutes)
LateMinutes        = FirstIn − ShiftStart, when ≥ tolerance; else 0
EarlyExitMinutes   = ShiftEnd − LastOut, when ≥ tolerance; else 0
MidDayGapMinutes   = max(0, Σ mid-day gaps − Break)
ExitActualMinutes  = MidDayGapMinutes                         -- the early exit is judged on its own, as EarlyExitMinutes
ExitApprovedMinutes= Σ approved exit-permission minutes for that employee/date (recomputed every run)
OvertimeMinutes    = max(0, LastOut − ShiftEnd)                -- payable = min(approved, detected)
WorkedMinutes      = (min(LastOut, ShiftEnd) − EffectiveIn) − Break − MidDayGapMinutes
CoveredMinutes     = exit-permission minutes that overlap the late/early window
                   + minutes inside the tolerance
                   + anomaly minutes whose HR decision is Excuse (or Overtime/Ignore disposition)
DayFraction        = min(1, (WorkedMinutes + CoveredMinutes) / Standard)
```

Status precedence for a day: **approved leave → public holiday → rostered rest day → punches**. A leave day stays `Leave` even if the employee punched; a rest day worked is `RestDay` with the worked minutes visible (paid as overtime only when an approved overtime request exists); a holiday is paid and never an absence. No roster row **in an approved roster month** = no record and no deduction. Where the month's roster is not approved, the roster is not read at all: a punched day gets a record judged against one global standard day (`core.fn_StandardDayMinutes`), with no late or early rule.

**Daily attendance has three views** (web only, no script): **Today** (who is at work, not in yet with how long since the shift started, left, on leave, rest day, punched without being on today's roster; it opens by default on a phone and refreshes itself), **Days** (the grid, with Branch and Shift columns, period shortcuts Today / Yesterday / This week / This month, quick filters with counts — Late, Short day, Absent, Missing punch, In progress, Overtime detected, Manual, Rest/leave/holiday — and Export to a CSV that Excel opens, of every row that passes the filters) and **Punches**. On a phone the days are cards with the reasons in words, and the roster has a "By day" list. A day with a plain missing In or Out has **Enter time in / out** on the row and in the day drawer: one field opened on the shift's time, saved as a Correct ruling on that day's missing-punch anomaly (ATTENDANCE_CORRECT; the machine's punches are kept and the day is re-derived at once).

**My attendance** (`/my-attendance`, every signed-in person linked to an employee; `GET /api/me/attendance?month=yyyy-MM`, authentication only, the employee taken from the token): today's punches, the next seven days' shifts and one month day by day with HR's decisions on each (excused, deducted, corrected, waiting; a day not on the roster: waiting or dismissed). HR's notes are never sent. No script.

**The days behind "N day(s) short"** (script 109): the payslip line stays one total (`payroll.fn_ShortDays`); `payroll.fn_ShortDayList` is the same rule per day and `payroll.usp_Payslip_ShortDays @PayslipId` lists a payslip's days, up to `PAYROLL_RUN.GeneratedUpTo`. `GET /api/payroll/payslips/{id}/short-days` has the payslip's own access rule (PAYROLL_VIEW, or the employee's own once approved); the payslip page opens it under the line ("See the days") and warns when attendance changed after the run was generated. Nothing that pays changed.

**"Something is wrong with this day"** (script 110, `attendance.DAY_REPORT`): the employee reports their own day, the branch manager a day of the branches they manage (`POST /api/day-reports`, sign-in only; the procedure checks who). HR's queue is `GET /api/day-reports` (ATTENDANCE_CORRECT, branch-scoped, never one's own day). **Accept** raises a correction with the reported times, requested by the reporter, approves it and marks the report - one transaction (`DayReportRepository.AcceptAsync`); it needs an attendance record for the day and at least one reported time. **Reject** needs a note the reporter reads; the reporter may withdraw while it is open; one open report per employee-day. Reports do not block payroll.

**Weekly shifts** (web only): Attendance > Weekly shifts (`ATTENDANCE_VIEW`) draws a branch's roster as the MOKA&CŌ poster, one column per shift and one row per day, OFF for a day nobody works, people on approved leave for the whole day left out; a week or up to 14 days, Print / PDF gives one full-bleed A4 sheet. **My branch's shifts** (script 112, `SHIFTS_VIEW_BRANCH`, `GET /api/me/team-shifts`): the same poster for an employee, their own branch only (the token's employee, never the request), one week at a time; it sends a name, a day and a shift, no attendance and no leave. Granted once, on creation, to every role holding REQUEST_RAISE_SELF; script 112 has no procedure, so it is not on `Scripts.Required` (check-scripts.sql checks the permission row).

**Bookings: rooms and report** (script 111): the Rooms page and the room writes of the API need `BOOKING_ROOMS`, the bookings report `BOOKING_REPORT` (they needed BOOKING_MANAGE / BOOKING_VIEW, so the booking desk saw both). Granted once, on creation, to Admin (roles with ROLE_MANAGE or USER_MANAGE), Owner and General Manager; reading the rooms stays BOOKING_VIEW (the calendar needs them).

**A day that is not on the roster** (script 108). Punches on a day the approved roster does not know have no attendance record, so the Days grid cannot show them: the Daily attendance page lists them above the grid as "Not on roster" (the Anomalies page has the same list), with the punches behind each. Nothing is paid or deducted until a person decides what the day was - **the system proposes a shift (the one starting nearest the first punch) and never adds a roster row itself**:

- *A working day, on a shift* - the day joins the roster on that shift and is derived from its punches at once (lateness and early leaving measured against the shift);
- *A rest day that was worked* - it joins as a rest day; nothing is deducted, and the time is paid only up to overtime approved for that day;
- *Not work* - a reason is required; nothing is written to the roster or to attendance. **A dismissal answers the punches it saw** (count, first, last): a punch arriving later opens the day again, and a dismissal can be taken back by hand.

Every decision is kept with who, when and the punches it answered (`attendance.UNROSTERED_DAY_DECISION`); adding the day on the Roster page files the same decision. A paid period is read-only (payroll adjustment); a day outside the employment, or in a month whose roster is waiting for approval, can be dismissed but not added. Adding a day changes the approved roster, so the month reads "changed since approval", as after any roster change. Who may decide: section 5. Payroll: section 7.5.

**Tolerance and anomalies.** Late arrival or early departure **below** `AttendanceToleranceMinutes` is ignored. Equal or above, it creates an anomaly (`LateArrival`, `EarlyDeparture`, `HalfDayAbsence`, missing punch…) that HR or the Operations Manager decides: **Excuse** (paid), **Deduct** (the minutes reduce the day) or **Correct time** (fix the punch). Until decided the day is paid in full, but **undecided anomalies block payroll readiness** for the period. A shift's `GraceMinutes` may override the setting (NULL = use the setting). Decisions survive reprocessing and a tolerance change; they are cleared, with a note, when the punch itself changes (a correction, a late-arriving punch), because the decision answered a fact that no longer holds.

**Exit permissions** (leaving during the shift) are approved through the workflow with a time window. The approved window covers the matching late arrival or early departure, so only the uncovered part becomes an anomaly; remaining approved minutes cover mid-day gaps. Several permissions on one day are allowed. At period close, used permission minutes are converted to leave (`ExitLeaveBasis` decides *actual* vs *approved* minutes), **once per day**; minutes beyond the remaining leave balance become an unpaid-leave deduction instead of a negative balance.

**Corrections** are manual records or punch fixes by permission; they survive reprocessing and are refused on a period already paid for that employee ("This period is paid — raise a payroll adjustment instead").

**Shift hours are dated** (script 117; before it, script 100 froze the hours of a worked shift and HR had to create a new shift). `attendance.SHIFT_HOURS` holds each shift's history - "from this day the shift runs start-end, break, grace, overnight" - and a day is judged against the row in force ON THAT DAY (`attendance.fn_ShiftHoursOn`); `attendance.SHIFT` shows the hours in force today (`usp_Shift_SyncCurrent`, run by every change and by the nightly job). Attendance > Shifts > Edit: new hours take a **From** day and an optional **Until** day - with an end, the hours before come back the day after (one entry for winter or Ramadan hours); the dialog lists the history and takes a change back. A change reaching into the past derives the touched days again; **a paid day keeps its hours**, so a change may not start inside a paid period. **A day without a rostered shift** is measured against the shift its first punch fits (the active shift starting nearest, `attendance.fn_ShiftByPunch`; remembered in `ATTENDANCE_RECORD.RelatedShiftId`): that shift gives the day its length and break - still no late/early rule without a roster. `core.fn_StandardDayMinutes` is now only the fallback (the most rostered active shift's length, else 8 h). Money that was priced per hour of the old setting follows the day's own shift: an hour of overtime = day rate / the hours of that day's shift (`payroll.fn_DayStandardMinutes`), a holiday worked on a rest day is a share of the employee's own day, and exit-permission minutes become leave as a share of that day (`core.fn_MinutesToLeaveDaysOn`). Lists that only show a leave-day figure still divide by the default day. Past days keep their figures until re-derived. Not covered: `attendance.fn_AttributedWorkDate` (production's own text, not in the repo) still reads an OVERNIGHT shift's present end time, and the correction / day-report forms its present overnight flag - after changing an overnight shift's hours, check the nights around the change. Holiday and transfer recomputes stop at today. Approving a roster month re-derives its completed days (script 102); HR also has "Re-derive month", and a nightly net catches what was missed.

**Rosters.** Monthly, per branch: shifts (with overnight support), rest days, copy-from-previous-period (copies the most frequent shift per weekday and never rosters a working shift on a public holiday), apply pattern, gaps report. A month is submitted as a `ROSTER_APPROVAL` workflow request (one open request per branch and month; re-submission after rejection; a change after approval supersedes the old request). When the last approver signs, `usp_Request_ApplyApprovalEffects` sets the month to Approved and stamps `AppliedAt` — without this the shifts are never used (a real blocker: a whole month was processed as "unrostered"). After approval, past days and days with recorded attendance are locked; future days may be changed by permission holders, which flags `ChangedSinceApproval` and asks for re-submission. The one thing that may still be added to the past is a **missing** day with no record, by a holder of `OFFROSTER_PAST`; a missing row for **today** for somebody who has already punched needs `OFFROSTER_TODAY` (script 108) - both are derived at once. A roster may be cleared only while Draft/Rejected and with no processed attendance.

**Nightly job** — process raw logs, mark absentees, mark leave days, apply exit permissions, apply overtime, sweep approved-but-unapplied workflow effects, apply due branch transfers, expire leave carry-over. Everything is idempotent.

### 7.3 Leaves

- **Types** with their policy: paid/unpaid, requires certificate, fixed entitlement (e.g. maternity 70 days — counted in calendar days) or entitlement by tenure tier, carry-over allowed, discretionary.
- **The leave year is opened from the policy grid** (`usp_LeaveYear_Open`), not accrued monthly (decision D7 — the monthly accrual machinery was deleted). Entitlement = the tier's days for the employee's whole years of service at 1 January; someone hired during the year gets `ROUND(tier × (13 − hire month) / 12 × 2, 0) / 2` (half-day granularity). The current year only, idempotent, with `usp_LeaveYear_Undo`.
- **Carry-over**: capped at `LeaveCarryOverMaxDays`; unused carried days expire on `LeaveCarryOverExpiresOn` with an `Expiry` ledger line (usage consumes carried days first). The job is idempotent.
- **What a leave costs**: the employee's **rostered working days** in the range (`LeaveCountsRestDays = 0`). Rest days cost nothing, public holidays of the employee's branch cost nothing, a day with no roster row counts as a working day. Fixed-entitlement types count calendar days. The request shows "N working days" before submission.
- **Half-day leave** (`HalfDay = 'AM' | 'PM'`, one-day requests): 0.5 of the balance; the other half is measured from the punches (absent → half-day absence anomaly).
- **Ledger**: every movement is a row (`Opening`, `Usage`, `Adjustment`, `CarryOver`, `Expiry`) with the source request. Usage is posted **per month** — a leave crossing a month end posts one row per month (reports and balances are monthly). A partial approval keeps the first days of the range.
- **Balance check at submission**: a request beyond the balance is refused by name and number (pending requests count as committed) unless `LeaveAllowNegativeBalance = 1`; discretionary types skip the check.
- **Discretionary grant at approval**: the approver ticks "discretionary" and adds a note (required); the ledger gets a `Usage −N` and an `Adjustment +N` pair, so payroll still counts the day as taken but the balance is not charged. Retracting the approval removes **both** rows (an old bug minted leave days).
- **Retract / reopen restore attendance too**: taking back an approval restores the ledger *and* re-derives the days, so a day the employee actually worked stops showing as leave.
- **Termination**: unused balance is paid out (`LeavePayoutOnTermination = 1`) as a payslip line at the day rate, or deducted when negative; skipped when an approved separation settlement already pays it.

### 7.4 Workflow engine (requests and approvals)

The engine is generic; each request type adds a payload table and a `_Decide` procedure that applies its effect.

**Types**: leave request, exit permission, overtime, shift swap, salary advance, payroll adjustment, expense reimbursement, tip distribution, onboarding, separation, availability change, roster approval.

**Chains** are versioned definitions with ordered steps. A step names its approver by type: role, **tier** (walking up the hierarchy with `EscalationLevels`), specific user, or the employee's manager. Steps may require a comment, a password signature, or allow the approver to adjust the figure (`CanAdjust`, which snapshots `ValueBefore`).

**Which chain a requester follows** (script 107): a chain set to tier X serves tier X and every more senior tier (1..X, since D6); a requester follows the narrowest chain that serves them, the default chain (no tier) last. The lowest tier cannot be chosen (it would be everybody). `workflow.usp_TierChains_Probe` tells which rule the live submit follows.

Behaviour:

- **Submit** resolves every step. A step with no resolvable approver (sole member, the requester themself, no deputy) is skipped with a recorded reason. If every step skips, the request is auto-approved — and the effects are applied explicitly (historically they were silently skipped, so an approved advance never created the advance).
- **Deputies** sign only when the main approver is genuinely absent (approved leave today, or a disabled account) or when the main approver explicitly delegated that step; delegation can be reclaimed, and the delegator is locked out while it is handed over (decision D8). Organisational types (e.g. roster approval) are exempt from the "never your own request" rule (D8).
- **Advisory rejection**: a rejection before the final step is advisory; the final approver may overrule with a note.
- **Hold / Resume**: a step can be put on hold, optionally "waiting on the requester", who may then resume it.
- **Retract last decision** (same **Beirut** day, by the last signer, password-gated), **Withdraw decision** (while the request is still open), **Reopen** (rejected or cancelled requests; a *two-signature* GM + Owner act by two different people, order-free, which re-checks the create-time guards at the second signature; HR's one-signature reopen is for cancelled requests only). A cancelled request cannot be retracted back to life.
- **Reversals** undo effects for leave, salary advance, payroll adjustment, exit permission, overtime and roster approval (attendance re-derived, the original figure restored); other types, a paid period, converted exit minutes and consumed advances or adjustments are refused.
- **Cancel** is gated in the procedure (requester, the subject employee, HR or Admin) as well as in the API.
- **Decisions are concurrency-safe** (script 101): the request is locked before it is read, the step update checks the expected step and status, and a race answers "This step was decided a moment ago — reload." Reject, Cancel, Hold, Resume and Delegate are base-only and do not have this yet.
- **Notifications**: on close, the e-mail/WhatsApp outbox gets a message with a PDF of the request; manual resend exists for every role.

### 7.5 Payroll

**Inputs**: salary components per employee (effective-dated, standing or one-off), attendance (`DayFraction`, anomaly decisions, unpaid leave, overtime), approved adjustments and advances, exchange rates, NSSF and tax configuration.

**Runs**: `Primary` (one per period, creatable on any day of the period) and `Supplemental` (any time, pays approved, unconsumed adjustments; one open at a time). Lifecycle: Create → Generate → Send to review → Approve (Owner) → locked → payslips marked paid. A run **snapshots the exchange rates** it uses (`PAYROLL_RUN_RATE`): a Draft re-reads them at each Generate, and from Review they are frozen, so later rate changes never move historical pay; a currency without a rate is refused. Readiness refuses to run while the period has unprocessed punches, undecided anomalies or unmapped device punches **on completed days** (a shift still in progress does not count), and Generate and Approve check it again. An eighth count (script 108) is the completed days somebody punched on that are **not on the roster and not decided**: always shown, and blocking from the month of setting `OffRosterBlocksPayrollFrom` on (before it the count is amber and the run can be created). Every input of every payslip is fingerprinted: **Approve refuses a run whose inputs changed** ("Regenerate the run"), and the run page names who and what changed. A Primary cannot be approved before the period's last day unless the Owner ticks "early lock". Viewing payroll needs `PAYROLL_VIEW`, preparing `PAYROLL_RUN`, approving and paying `PAYROLL_APPROVE`; employees see their own payslips under "My payslips".

**Salary rows** are set from a date and ended, never edited in place: a later row of the same type and currency supersedes the earlier one from its start date. **Settlements and leave payouts** not paid in the leaving month are paid by the next open Primary (a settlement-only payslip), and a payout writes a `TerminationPayout` ledger row so it is never paid twice. Component types used by payroll have a `SystemCode` and cannot be renamed or removed; NSSF and tax keep one version in force at a time.

**Generation, in order**:

- **A — Standing components**, each prorated over **its own effective dates** intersected with the employee's employment in the period: `days(max(period start, hire, component from) … min(period end, termination, component to)) / days in month`. The line explains itself ("Prorated 15/31 of the month: 2026-08-01 to 2026-08-15"). *A mid-month salary change used to pay **both** salaries in full — the single worst bug found.*
- **B — Attendance deductions**: Σ(1 − DayFraction) × DayRate over days that are real working days (`RestDay`, `Leave`, `Holiday` and days with no roster are excluded), computed from **exact minutes**, not a rounded fraction.
- **C — Unpaid leave**: days × DayRate. `DayRate = Basic / StandardWorkingDaysPerMonth` (26).
- **D — Overtime**: approved and detected minutes at the hour rate.
- **E — Holiday work**: minutes × (DayRate / Standard) × (`HolidayWorkRate` − 1), because the holiday itself is already paid. Wage-like: inside the NSSF and tax base. An **unpaid** holiday costs whoever was rostered one day.
- **F — Leave payout / deduction on termination** (outside the NSSF and tax base).
- **G — Sick-leave tiers** (year-to-date), gifts and bulk adjustments (each consumed once, at lock).
- **H — Statutory**: NSSF base = salary + overtime + leave + attendance lines in the primary currency. Employee NSSF = 3 % of min(base, ceiling 2500). Employer = (8 % + 6 %) on min(base, ceiling) + EOSI 8.5 % on the **full** base. Income tax = Lebanese brackets applied to (base − employee NSSF) × 12 − `TaxFamilyDeductionAnnualUsd`, divided by 12.
- **I — Salary advances**: the instalment is **capped at what is left of the payslip** (oldest advance first, per currency); the remainder carries to the next run with a note on the line. Never a negative net.
- Indemnity is only produced from a prepared **Separation** request, never from a termination date alone.

Worked check (the shape to reproduce in tests): basic 3 500 USD + 6 000 000 LBP allowance at 90 000 → base 3 566.67 before deductions; employee NSSF 75.00 (ceiling); employer 2 500 × 14 % + base × 8.5 %; annual taxable (base − 75) × 12 → brackets 2 % / 4 % / 7 % / 11 % → divided by 12.

**Locked period guard** (`fn_IsPeriodPaid`, `usp_AssertPeriodOpen`) is **per employee**: a locked run protects only the people it paid. Automatic processing never raises on a paid day — it leaves the day as paid and carries on; every HR-facing writer refuses with the sentence above.

### 7.6 Bookings (back office)

Rooms with hours per weekday (`OpenMin`/`CloseMin`, where a close ≤ 06:00 means "next day" and is stored as > 1440), add-ons (fixed or per hour), hour-based discounts, deposit tiers, and a 5-minute **turnaround** so the next guest's slot starts after cleaning ("Wrap up by …" on the booking).

Times are **minutes from midnight of the booking date** everywhere (`StartMin`, `EndMin ≤ 1800`), which is what makes 22:00 → 01:00 a single-day row and keeps overlap checks from crossing dates.

- **Statuses**: Pending (a website request or an unpaid hold) → Confirmed → Cancelled / NoShow. Every booking has a public reference `MC-XXXXXXXX`.
- **Deposit** = the lead-time tier (≥168 h → 20 %, ≥48 h → 30 %, else 50 %) applied to the discounted total including add-ons, with a floor (`BookingDepositFloor`). A hold expires only when a payment session was actually opened (`BookingHoldMinutes`, swept every 5 minutes); in step 1, without `BookingDepositRequired`, a website booking is a request with no expiry that staff confirm.
- **Discounts** by booked hours (`ROOM_DISCOUNT`, per room or default) apply to the room price only, not to add-ons.
- **Cancellation and refunds**: staff cancel → full refund due; the guest cancels (online within `BookingCancelHours`, or staff records it as "guest asked") → refund = paid − deposit (`BookingDepositRefundableOnGuestCancel = 0`). Refunds are recorded as **negative** `BOOKING_PAYMENT` rows (`IsRefund = 1`); `RefundStatus` moves None → Due → Partial → Refunded.
- **Notifications** are raised by a database trigger into the outbox, never by the API: a staff alert and a "request received" mail on creation, the confirmation only when staff press Confirm, cancellation and refund mails on those events. `fn_MailKindForStatus` refuses a message that contradicts the booking's status ("The booking is Cancelled — a Confirmation message cannot be sent"), which fixed guests getting "confirmed" mail while the booking was still pending. Booking mail uses its own sender and SMTP account (`bookings@mokanco.com.lb`).
- **Staff UI**: calendar (per room, hour by hour, with the axis extending past midnight), all-bookings grid, rooms and hours editor, deposit tiers and discounts, report, blocks, manual booking, confirm/cancel/no-show, record payment and refund, live updates over SignalR.

### 7.7 Online booking (website ↔ HRMS)

The website has **no database**. The booking wizard calls the HRMS public API directly from the browser; bookings land in `booking.BOOKING` and appear in the HRMS immediately.

Contract (`{API}/api/public/booking`), JSON, Beirut wall-clock, every response carrying `timeZone` and ISO moments with offset:

| Method & path | Purpose |
|---|---|
| `GET /catalog` | rooms, hours, add-ons, deposit tiers, discounts, rules (cache 60 s) |
| `GET /availability?room=&date=` | open/close, taken and free ranges, earliest start, turnaround (live) |
| `GET /availability/month?room=&month=` | per-day status: past / unavailable / closed / full / partial / open (cache 60 s) |
| `POST /quote` | server-side price, discount, deposit |
| `POST /` | create = a Pending booking with its `MC-` reference |
| `GET /{ref}` | public recap (never phone, e-mail or gateway ids) |
| `POST /{ref}/release` | free an unpaid hold |
| `POST /{ref}/cancel` | guest cancellation with phone verification |
| `GET /verify?ref=` | gateway return → idempotent confirm (step 2) |
| `POST /{ref}/pay` | open the deposit payment; optional `{ "method": "card" \| "whish" }` (absent = card) → `sessionId` (card) or `collectUrl` (Whish) |
| `GET /whish/callback?ref=&t=` | Whish's server-to-server signal → status check + settle; answers 200 |
| `GET /whish/return?ref=` | the guest's return from Whish's page → settle → 302 to the same three site targets as `/verify` |

Errors are `{ error, code }` with codes `invalid_input`, `room_unavailable`, `closed`, `lead_time`, `slot_taken` (409), `hold_expired` (409), `not_found`, `paused` (503), `unauthorized`, `cancel_window`, `not_cancellable`. Access: a browser from an origin in `BookingCorsOrigins`, or a server sending `X-Booking-Key` equal to `BookingApiKey`; rate-limited per IP. `BookingWebsiteEnabled = 0` pauses online booking and the site shows the WhatsApp fallback.

**SignalR** `/hubs/booking`: group `staff` (authenticated) receives `BookingChanged`; group `booking:{ref}` (anonymous, joined with a valid reference) receives `BookingStatus`. The confirmation page uses it and falls back to a 30-second poll.

**Card payments (MPGS, Bank of Beirut)** — hosted checkout: a session is opened at create time when a deposit is required, `usp_Booking_SetGateway` stores the order and session ids, the gateway returns to `/verify`, and `usp_Booking_ConfirmPaid` is idempotent by gateway reference. Configuration keys `MPGS_BASE`, `MPGS_MERCHANT_ID`, `MPGS_API_PASSWORD`, `MPGS_API_VERSION`, `MPGS_TEST_3DS_BYPASS`.

**Whish Pay (doc v2.0.0), the second way to pay the deposit** (script 118; `WhishClient`, `WhishOptions`, `WhishDecisionTable`) — a second gateway behind the SAME pipeline, not a second pipeline: `usp_Booking_StartPayment` stamps the hold, `OnlineDepositService.SettleAsync` settles, `usp_Booking_ConfirmOnlinePayment` records (method name `Whish`). What differs is who is asked. A Whish payment link allows ONE attempt and lives 5 minutes, so each try has its own id - the reference plus an attempt number, `MC-K7Q2M9PW-A1`, `-A2`, ... (`usp_Booking_StartWhishAttempt`) - stored as the booking's `GatewayOrderId`; that is also how the settlement code tells the methods apart (the bare reference = a card order). `POST /{ref}/pay {"method":"whish"}` answers `{ method, collectUrl, ref, deposit, currency, holdExpiresUtc, expiresAt }`; the site redirects to `collectUrl` (Whish's own page shows the QR code and six-digit code). The outcome ALWAYS comes from `POST /payment/collect/status`, never from which callback or redirect fired: `success` → paid (the payer's phone is kept, `BOOKING.WhishPayerPhone`); `failed` (the link expired unpaid) → released; `pending` → unconfirmed while the link can still be paid - which is also what a failed attempt reads until the link expires - and "never paid" once the link is over (+1 min); `refunded` / `unknown` / no answer → unconfirmed, staff alerted by the job. A second `/pay` settles the stored attempt first: 409 `payment_unconfirmed` while its link is open, otherwise a fresh id and link. The reconciliation job also re-asks about the last 5 earlier attempts (an attempt paid in its last second after a new one was opened). Whish's envelope is judged by its body (`status`/`code`), never the HTTP status; `status:false, code:"500"` is PENDING and is retried with the SAME externalId. The catalogue's `rules.depositMethods` lists what is on offer: `card` when MPGS is configured, `whish` when the `WHISH_*` keys are set AND `BookingWhishEnabled` is on. Refunds: `WhishClient.RefundAsync` exists and is tested but is NOT wired to cancellation yet (Whish must whitelist the server's egress IP first; refunds stay manual as for cards). Verified end to end against Whish's sandbox on 21 Nov 2026 (create, replay, Simulate Success → Confirmed, Simulate Failure → pending, callback token, idempotent replays). The website side (method choice, redirect to `collectUrl`) is Reda's.

**The payment gateways in HRMS** (script 119; `PaymentGateways`, `GatewayKeyProtector`, `GatewayAdminService`, `PaymentDeskService`, `PaymentEventLog`) — three screens over the same pipeline, none of which turns anything on for guests (`BookingWhishEnabled` and `BookingDepositRequired` are not touched):
- **Settings → Payment gateways** (permission `GATEWAY_ADMIN`: Admin roles and Owner). The keys of Whish (channel, secret, website URL) and of the bank's gateway (address, merchant ID, API password, version), each for **test** and for **live**, and the **mode in use** per gateway. A key is typed once, encrypted by the API before it is stored (AES-256-GCM; the key is derived with HKDF from the server's `Jwt:SecretKey`, bound to gateway + mode) and never sent back: the page shows the end of a secret at most. A database copy restored on another server cannot open them (they read "enter them again" - a test server never inherits production's keys); changing `Jwt:SecretKey` means entering them again. Resolution (`IPaymentGateways`): the mode in use = what was chosen in HRMS, else the mode of the server file's keys, else test; a mode's keys = those saved in HRMS, else the server file's when they are of that mode. Nothing saved = exactly the behaviour before script 119. The gateway options are read at every call (a 20-second cache, cleared on save), so no restart is needed; a database without script 119 falls back to the server file.
- **A payment is settled with the mode it was OPENED in** (`booking.BOOKING.PaymentMode`, stamped beside `usp_Booking_StartPayment`): switching a gateway to test never loses a live payment in flight, and a refund goes to the gateway that took the money.
- **The payment log** (`booking.PAYMENT_EVENT`): one row per step - opened, the gateway asked (by the guest's return, Whish's callback, the job, staff) and what it said, paid, released, staff e-mailed, refunded - never a key. The same check with the same answer is counted on its row (`Repeats`). Writing it never breaks a payment (`PaymentEventLog` swallows and warns).
- **Bookings → Payments** (`BOOKING_PAYMENTS` to see, `BOOKING_PAYMENTS_MANAGE` to act; `GET/POST /api/booking-payments…`). One row per booking a payment was opened or recorded for (`booking.fn_PaymentRows`), state Paid / Open / Unconfirmed / NeedsStaff / RefundDue / Refunded / NotPaid, totals per currency (payments made in test mode are tagged TEST and never counted as money). "Ask the gateway now" reads what the gateway holds and, when the payment is not on the books, settles it through `SettleAsync` exactly as the job would (`SettleTrigger.StaffCheck`, no staff e-mail). "Refund on Whish" calls `POST /payment/whish/refund` (the whole payment; Whish must have registered the server's egress IP, otherwise `auth.error`) and then records the refund through `usp_Refund_Add` under the reference `Whish refund <externalId>`; only on a cancelled booking, only once, only while nothing was refunded by hand. Card refunds stay in the bank's portal.
- **Bookings → Gateway test** (`GATEWAY_ADMIN`; `/api/payment-gateways…`). A connection check that moves no money (Whish: `GET /payment/account/balance`; the bank: RETRIEVE_ORDER of an order that cannot exist), test payments (reference `GT-XXXXXXXX`, table `booking.GATEWAY_TEST`, never a booking, at most USD 20), and a lookup of what a gateway holds for any reference. The mode is chosen per test, independently of the mode in use, so production can be tried without switching the website. A test's trip back uses the real public addresses (`/verify`, `/whish/callback`, `/whish/return` recognise a `GT-` reference) and lands on the HRMS page it was opened from (the request's own `Origin`). A card test's payment page is the website's `/pay/#session=`; a card test is refunded in the bank's portal, a Whish test from the page.
- Verified on 21 Nov 2026 against Whish's sandbox with keys saved through the page: connection check, test payment paid with Simulate Success and followed by the page, a website booking paid on Whish and confirmed, and a refund refused with `auth.error` (the sandbox does not know this machine's address) leaving everything unchanged.

### 7.8 Notifications

One outbox (`core.EMAIL_OUTBOX`) for both channels. Rows carry the booking or request id, the mail kind, language, channel, attempt count, and — for booking mail — the sender address, name, SMTP account and template. `usp_Email_GetPending` **claims** rows (double-send proof; it once sent the same mail eleven times), retries three times at five-minute intervals, and the worker attaches a QuestPDF document for closed requests. Bodies are bilingual (English / Arabic) by the employee's preferred language. WhatsApp uses the same outbox and sends when the Meta credentials are filled.

### 7.9 Reports and dashboards

Daily and monthly attendance, payroll runs and payslips, bookings (period, room, discounts, refunds), leave balances, tier violations, workflow monitors (stalled requests, role health, chain state). Role-based dashboard cards: my salary status, pending approvals, today's attendance, bookings of the day.

**Auto-roster, fixed rotation** (script 116, `docs/AUTO_ROSTER.md` §9): a second method in the auto-roster drawer that follows the owner's spreadsheet rule - days off alternate two and one per week and move two weekdays every two weeks, two leads alternate morning and evening opposite each other, everybody else is balanced between the two shifts down the list. The branch's start date, its two shifts and the list are stored (`PUT api/roster/auto/rotation`); the rule is `RotationRule.cs`, tested cell for cell against the spreadsheet. Facts, leave and holidays win over the rule; a long run it creates is a warning, not a refusal.

**Recipes** (the drink recipes; `/recipes` on the web, `GET /api/prep-book...`, script 115): the bar's Drink Preparation Guide and the MC MIX labels as a searchable page - type a drink (typos, partial words and Arabic names work), read its ingredients and steps, switch hot/iced, open the scanned guide page. **The guide is confidential and both repositories are public, so no recipe, amount or scan is ever committed** - not in the code, not in the website's files, not in the tests (they use invented recipes). An admin (`PREP_BOOK_MANAGE`) uploads the recipe book as one .zip on the Recipes page (`recipes.json` + `pages/guide-NN.jpg` + `labels/label-NN.jpg` + optional `thumbs/guide-NN.jpg`); `PrepBookPackageReader` checks every file by its own bytes and refuses with a sentence; the book is stored in `core.PREP_BOOK` (JSON with the thumbnails inside) and `core.PREP_BOOK_SCAN`, replaced whole in one transaction, and served only to a signed-in user with `PREP_BOOK_VIEW` (granted once to every role with REQUEST_RAISE_SELF and to Admin). Scans are fetched with the token as blobs, answers are `private`. A new version of the guide = build a new .zip and upload it; the owner keeps the .zip (it is not in the repository). **The guide can be uploaded as a PDF itself**: the upload is a PDF or a recipe book by its own first bytes; for a PDF the API draws every page (`PrepBookPdfReader`: PDFium through the PDFtoImage package, pages 1800 px on the longer side, a 320 px picture of each inside the book, PdfPig for the text layer) and publishes a book of PAGES - one entry per page, category `pages`, `"source": "pdf"` - which the page shows as a grid of pictures with a previous/next viewer. A page is found by a word only when the PDF has text; a PDF made of pictures (the present guide: 49 scanned pages) is browsed, or opened by page number. Recipe CARDS (ingredients, steps, search by drink) exist only in the recipe book (.zip); a PDF chosen over a book of cards asks first. No database change (script 115's tables hold both). The server needs the packages' Linux libraries (`libpdfium.so`, `libSkiaSharp.so`: they come with `dotnet publish`; the SkiaSharp.NativeAssets.Linux.NoDependencies version must equal the SkiaSharp version PDFtoImage resolves).

**Worked time** (Reports > Worked time, `GET /api/reports/worked-time`, REPORT_VIEW, branch-scoped; scripts 113 and 114): per employee for any period up to 93 days, days and hours worked, average per day, extra time, missing-punch days, leave days, holidays and **progress** = worked / expected. Worked time is the attendance days (the Daily attendance read, never raw punches), so it agrees with the day shown and paid: first in to last out with the gaps out, and on a day with an approved roster shift the shift window plus the overtime after it (so it means the same with or without a roster), a day HR credited counting too; without an approved roster those days are measured against the standard day, which is what makes the report work with no roster. Expected = `StandardWorkingDaysPerMonth` x `StandardWorkDayHours` (26 x 8 h, payroll's settings) spread over the calendar days of each month, for the days employed in the branch (`report.usp_Report_WorkedTime_Days`, branch as of the day; every attendance, leave and to-decide day is matched to that calendar, and the scope is checked per day by the branch of the day); a public holiday expects nothing, approved leave nothing (half a day, half). Counted up to yesterday (Beirut). Punched days of an approved month missing from its roster (`fn_UnrosteredDays`, not dismissed) count like any day worked: script 114 (`report.usp_Report_WorkedTime_PunchDays`) measures them from their punches exactly as `usp_Attendance_ComputeDay` measures a day with no shift (attribution, debounce, direction mode, pairing, gaps out, missing punch; proved equal by `tests/qa3/attendance/11_worked_time_punch_days.sql`), and they are marked "not on the roster" so they can still be decided. A dismissed day is not counted. Rules are in `WorkedTimeReportService.Build` (pure, tested). Rows open to the day list; Print (landscape) and CSV (decimal hours). Since script 117 the expected time is the working days of a month × the hours of **each person's own shift** (the most frequent standard of their days in the period; the default day when none), and a punched day missing from the roster is measured against the shift its first punch fits (`report.usp_Report_WorkedTime_PunchDaysByShift`; script 114's procedure stays as that script's marker).

**Hourly punch processing** (`HourlyPunchProcessingJob`, every hour at :30): runs the processor (`usp_Attendance_ProcessRawLogs`, all unprocessed punches, serialized by an application lock) so attendance days are at most an hour old. The nightly job then re-processes yesterday once (a roster approved during the day re-derives only up to the day before). Absentees, leave days, exit permissions and overtime stay in the 01:00 nightly job. Today's open day reads as a missing punch until its Out arrives (the pages show it as a shift in progress).

---

## 8. Decisions and why

| # | Decision | Reason |
|---|---|---|
| D1 | Audit from the schema script; data-level checks deferred to the live app | the exported script had no data rows |
| D2 | Procedure inventory corrected to ~270 | the first count missed `CREATE   PROCEDURE` with extra spaces |
| D3 | Missing indexes were an export artefact | the live database has 65 non-clustered indexes; hot paths covered |
| D4 | Fix the engine first, then replatform the UI | no point porting screens over broken rules |
| D5 | Dual front-end parity during the port, then retire the old DevExtreme app | the new Mantine app is now *the* system |
| D6 | Seniority tier **1 = head** | matches how management talks; the dictionary and reports were flipped accordingly |
| D7 | Leave is a **yearly opening** from the policy grid; monthly accrual deleted | the business grants days per year by tenure; accrual produced numbers nobody recognised |
| D8 | Deputy signs only on absence or explicit delegation; organisational request types exempt from the self-approval ban | approvals were being bypassed; but a roster must be submittable by the manager who owns it |
| D9 | Lateness model = **tolerance + HR decision** (Excuse / Deduct / Correct), no automatic late deduction | the owner wants a person to judge; automatic deductions were wrong in both directions |
| D10 | Reference data: delete only when unused, otherwise refuse with a sentence and offer Deactivate; phone + e-mail required for new employees | history must not break; notifications need contact details |
| D11 | Payroll runs: one Primary per period, creatable any day; Supplemental any time with unconsumed approved adjustments; one open Supplemental | the café pays mid-month advances and corrections constantly |
| D12 | Everything for the booking lives **inside** the existing stack (same database, same API, same web app) | the owner's explicit constraint: one system, one database, one login |
| D13 | The website calls the API directly from the browser; no serverless layer | the Cloudflare functions were retired; fewer moving parts, prices stay live |
| D14 | Local development runs against a **copy** (`MokaCo_HRMS_Dev`); the real data stays in `MokaCo_HRMS`, and production is the VM | experiments must not touch real payroll |

**Rules settled on 14 November 2026** (script 108, the owner's decisions): attendance is visible whether or not the roster knows the day - a punched day that is not on the approved roster is listed where attendance is read, never hidden; **rosters are never created automatically** from punches (a guessed shift would invent lateness and deductions and change a signed roster); such a day pays nothing by itself - it is added to the roster or dismissed by a named person; who that is, for today and for past days, is set on the Role Permissions page; undecided days warn for one month and block payroll from the next.

**Rules settled during the third QA pass** (19 October 2026; full list in `tests/qa3/QA_REPORT_3.md` §6): salaries are visible to HR, payroll and the employee only; the HRMS starts without the card-gateway keys (online deposits off); a partly approved leave keeps its first days and a leave is re-priced on the approved roster, never inside a paid period; worked shifts keep their times; day precedence is leave > holiday > rest day; reversals only for types that can be undone, on the same Beirut day; a Primary is not locked before month end unless the Owner chooses to; a stale run is never approved; unpaid settlements go on the next Primary; access ends the day after leaving; new employees get the lowest tier; a tier chain serves its tier and every more senior one; the Operations Manager sees all branches (`EMP_VIEW_ALL`); the unrostered-day rule stays limited to approved months.

**Rules settled during the deep QA pass** (full list in `tests/qa2/QA_REPORT_2.md`): exit permissions cover by *window*; what a permission covers is not an anomaly at all; "unrostered day" only applies inside an approved roster month; a decision answers a fact, so it survives reprocessing but is cleared when the punch changes; "the period is paid" is per employee; a leave costs rostered working days (fixed-entitlement types count calendar days); partial approval keeps the first days; the balance check counts pending requests and is skipped for discretionary types; carry-over is consumed first; a transfer is dated and `EMPLOYEE.BranchId` means today; an attendance record belongs to the employee's branch of that day, not the terminal's; proration is per component's own dates; leave payout sits outside the NSSF and tax base while holiday work sits inside; an advance instalment is capped per currency, oldest first.

---

## 9. Quality: the test suites

| Suite | Where | What it is |
|---|---|---|
| `tests/qa` | `MokaCo.HRMS/tests/qa` (`bash tests/qa/run.sh`) | 216 checks: rosters, attendance, leaves, payroll, bookings, permissions, cultures, responsive smoke |
| `tests/qa2` | `MokaCo.HRMS/tests/qa2` (`bash tests/qa2/run.sh`) | 67 checks of **complex** scenarios: same-day combinations, overnight + DST + month end, leave edge cases, roster changes, payroll proration and statutory math, plus browser checks |
| `tests/qa3` | `MokaCo.HRMS/tests/qa3/<area>/*.sql` (`sqlcmd -I -b -d <db> -i <file>`) | 59 SQL scenarios for the scripts 98–119; each runs in a transaction it rolls back and prints `ok <name>`. Report: `tests/qa3/QA_REPORT_3.md` |
| unit + database tests | `dotnet test` | 1976 tests; the database ones run when `MOKACO_TEST_CONNECTION` points at a database with the scripts, otherwise they skip |

Both suites seed everything with a `QA ` / `QA2 ` prefix, run inside transactions where the data is real (payroll), and `cleanup.sql` removes their rows and **verifies integrity**: real row counts plus checksums of rosters, attendance records and the leave ledger must match the baseline taken at seed time. Reports: `QA_REPORT.md` and `tests/qa2/QA_REPORT_2.md` (bug table, rules decided, features added, disposition per finding).

Current state (14 November 2026): `dotnet test` 1791/1791 against a stand-in database with every numbered script up to 110, `tests/qa3` 56/56 (the new 09_payslip_short_days and 10_day_reports included), web `npm test` 218/218 with `tsc`, lint and build clean; the "Not on roster" screens were also driven in a browser (desktop and phone). The stand-in is rebuilt from the repo scripts on an inferred base, so overnight attribution (`attendance.fn_AttributedWorkDate`) is only approximated there: check it on the test VM. `qa` and `qa2` were last run at 216/216 and 67/67; their cases were updated for QA3 but not re-run (they need the test VM).

If a suite is interrupted, run its `cleanup.sql` before anything else — it also restores the settings the suite changed.

---

## 10. Environments, deployment and operations

**Development (laptop)** — Ubuntu, .NET 8 SDK (`~/.dotnet`), Node 22, SQL Server 2025, VS Code with the *SQL Server (mssql)* extension (Schema Compare, Database Projects) and *Remote - SSH*. `npm run dev` in `mokaco-web-mantine` starts the API and the web together (concurrently); the Vite proxy must point at `http://localhost:5078`.

**Production (VM)** — SQL Server **Express**, the API as a systemd unit reading `/etc/mokaco/api.env`, nginx with TLS proxying `/api` and `/hubs` (WebSocket upgrade headers) to Kestrel on 127.0.0.1, the HRMS web built and served as static files, `ufw` allowing 22/80/443 only (1433 never public), timezone `Asia/Beirut`.

**Deploy flow** (agreed): develop on a branch → merge to `main` on GitLab → tag → on the VM a script backs up the database, checks out the tag, applies any new `docs/*.sql` in order, builds, restarts the service, health-checks, and rolls back to the previous tag on failure. The VM authenticates to GitLab with a read-only **deploy token**. Deploy at closing time. The website deploys from GitHub by its own owner.

**Without a laptop** the VM fetches the code itself: `deploy/fetch-code.sh test` (dev -> `~/src-test`) or `prod` (main -> `~/src`), then the usual `deploy-test.sh` / `update-prod.sh`. For private repositories `fetch-code.sh token` saves a read-only fine-grained GitHub token on the VM (hidden prompt, `~/.config/mokaco/github-token`); never in a chat or a tracked file.

**Scripts before the API (deploy guard).** The API knows the numbered scripts it calls (`Scripts.Required` in `MokaCo.HRMS.Repository/Common/Scripts.cs`). At startup it logs `DATABASE SCRIPTS NOT APPLIED: …` for any that are missing, and `/health` answers `"schema":"behind"` (status `degraded`, still HTTP 200) until they are applied; no restart is needed after. `deploy/test-env/deploy-test.sh` stops the test API and lists them; `deploy/deploy-api.sh` warns. A new numbered script that the API calls goes on that list in the same commit. To see every numbered script a database lacks (older ones included), run the read-only `deploy/check-scripts.sql` against it; it ends with the missing ones in apply order. To compare production with the tested database object by object after an update, run the read-only `deploy/compare-schema.sql` (`-v REF=MokaCo_HRMS_Test TARGET=MokaCo_HRMS`): procedures, functions, views and triggers by text, tables by columns, indexes, permission codes; the last line counts the differences. On production all of it is one command on the VM after `sync-prod.sh`: `bash ~/src/MokaCo.HRMS/deploy/update-prod.sh` backs up `MokaCo_HRMS`, applies the missing scripts in number order (stopping at the first error, before the API), runs `deploy-api.sh` and checks `/health` and `/api/access`, adds HSTS, re-runs the Google gate's mode if it is on, and previews the night's leavers' sweep; `--web` adds `deploy-web.sh`, `--check` only reports. (`deploy-api.sh`'s port check refused every redeploy until 20 Oct: the API runs as `dotnet`; it now compares PIDs.)

**Database on the server**: built by **restoring a backup** of the developer database, not by replaying `docs/*.sql` (those are only the later patches; the base schema, the seeds and the real data are not in the repo). A backup restores only onto the same or a newer SQL Server major version — check `SELECT @@VERSION` on both sides first; if the versions don't line up, move it as a `.bacpac` with `sqlpackage`.

**Backups**: Express has no SQL Server Agent, so a cron job runs `BACKUP DATABASE` nightly, keeps 14 days and copies every file **off** the VM. Every deploy starts with a backup. Express also refuses `BACKUP ... WITH COMPRESSION` (Msg 1844): the first `install-db-backup.sh` asked for it, so the nightly backup could not make a single backup on production; fixed 21 Oct (the program now carries `# mokaco-db-backup v2`), and `update-prod.sh` installs the fixed one when it finds the old one or none.

**The attendance device cannot be pulled from the cloud** (it sits on the café LAN at 192.168.45.12). On the server set `MachinePullEnabled = 0` and switch the UA300 to **push** (ADMS) to the API's `/iclock` endpoint, or add a VPN. Many ZKTeco units cannot do TLS, so `/iclock` may need a plain-HTTP server block protected by the device API key. Only one system may collect punches: when production goes live, turn the laptop's pull off.

**Go-live checklist**: public API address listed in `BookingCorsOrigins`; the website deployed with `PUBLIC_BOOKING_API` pointing at it; SMTP and WhatsApp credentials filled; `AllowSystemReset` off; Employee role stripped of the three permissions it shouldn't have; the `sa` password rotated (an old one is in git history) and the application using its own least-privilege login; nightly backup verified by restoring one.

---

## 11. Traps that have already bitten this codebase

1. `RAISERROR` does not abort — always `RETURN` (and `ROLLBACK`).
2. A nested procedure's refusal is invisible without `INSERT … EXEC` + a row check.
3. `QUOTED_IDENTIFIER OFF` breaks saves on tables with filtered indexes, at runtime only.
4. `DECIMAL(18,4)` silently rounded 1/90 000 to **0** and wiped every LBP amount from a locked payroll run. Rates are `DECIMAL(28,12)`.
5. Reading `event.currentTarget` inside a React state updater (or after an `await`) throws "Cannot read properties of null" and the error boundary blanks the whole page. Read the value first, or use `Checkbox.Group`.
6. A number input that parses "8." on every keystroke turns 8.2 into 0. Keep the raw string in state; coerce on submit.
7. `GETDATE()` on a UTC server is not "today" in Beirut; the nightly job marked the wrong day.
8. Reprocessing by calendar date strands overnight punches and blocks payroll readiness.
9. Computed persisted columns cannot reference other computed columns; minutes-from-midnight columns are derived from `DATEPART` on the base times.
10. Triggers must not return result sets to procedures that use `INSERT … EXEC` (hence the `@Quiet` parameters).
11. The Vite dev proxy pointing at the IIS/https port gives "Bad Gateway" on login; the API must be on `http://localhost:5078`.
12. ~~The API refused to start when the MPGS keys were missing.~~ Fixed (QA3): it starts with online deposits off and says so in the log.
13. **The unnumbered scripts are older than production** for at least 16 procedures (QA3 CON-7): `workflow_core.sql`'s `usp_Request_Submit` returns 5 columns where the live one returns 6, `usp_Request_Reject` lacks `@SignedWithPassword`, the device and settings procedures lack later columns, and so on. **Never re-run an unnumbered script** on a live database, and never redefine a procedure from one: a numbered script either edits the live text or stops when `sys.parameters` shows a parameter it does not know (the guard every QA3 script uses). Columns drift too: production dropped `hr.LEAVE_TYPE.AccrualPerMonth` (D7) while `core_hr_schema_and_procedures.sql` still creates it; a copied body that names a dropped column fails with Msg 207.
14. `INSERT … EXEC` cannot be nested: a procedure that captures another's result set cannot itself be captured. Pass answers back through `OUTPUT` parameters (`usp_TierChains_Probe`).
15. SQL Server stores `CREATE OR ALTER PROCEDURE` as `CREATE   PROCEDURE` (three spaces) in `sys.sql_modules`; a text search for `CREATE PROCEDURE` misses it (see D2).
16. A function used by a default constraint cannot be altered (`hr.fn_ApprovalTier_Lowest`): drop the constraint first.
17. A "script applied" marker must be something the script introduces, never an object it only redefines: production has procedures the repo never created. `hr.usp_LeaveYear_Undo` (production's own, named in the 7 Oct handover) marked 99 as applied, so production skipped 99 and stopped at 100 (19-21 Oct). 99 is now checked by `ApprovedToDate`, `hr.usp_LeaveLedger_Reprice` and its report version; `SchemaCheckTests` refuses a marker production had before QA3.
18. Production is SQL Server **Express**: no `BACKUP ... WITH COMPRESSION` (Msg 1844), no SQL Agent. Test a deploy step against Express, not the Developer edition.

---
19. A numbered script must not re-create ANOTHER script's marker object (`Scripts.Required`; `SchemaCheckTests` fails): the guard could no longer tell whether the older script ran. Script 117 changed the Worked time punch-days procedure, the marker of script 114 - so the changed body has its own name (`usp_Report_WorkedTime_PunchDaysByShift`) and the API reads that one.
20. `attendance.SHIFT` shows TODAY's hours; a past day must be read with `attendance.fn_ShiftHoursOn(ShiftId, WorkDate)`. A shift with no `SHIFT_HOURS` row falls back to the `SHIFT` row, so `usp_Shift_SetHours` writes the first row (the present hours, from 2000-01-01) before it adds a change - otherwise the days before the change would be read with the new hours.
21. A procedure that sets `XACT_ABORT ON` and refuses with `RAISERROR` leaves a CALLER's open transaction uncommittable once the refusal is caught: in the SQL scenario tests the refusals come last.
22. `ISNULL(@a, 'longer text')` returns the TYPE OF ITS FIRST ARGUMENT: with `@a VARCHAR(4)` the text is cut to four characters ('the server file' became 'the '). Use `COALESCE` when the fallback is longer (script 119's mode history).
23. In React, `event.currentTarget` is gone by the time a state UPDATER runs: `setX(c => ({ ...c, f: event.currentTarget.value }))` crashed the gateway keys form on the first key press. Read the value first, then call the setter.
24. A browser check with a hand-made token for an admin's user id shows every page whatever permissions the token names: the web app asks the server who the user is. Test "may not see it" with a token for a user who really lacks the permission.

## 12. Open items

**Decisions needed from the owner** — none open. QA3 settled the two that were here: the "unrostered day = no record" rule stays limited to approved roster months, and the Operations Manager gets `EMP_VIEW_ALL` (script 106; they sign in again to pick it up).

**From QA3 (19 October 2026), still open** — details in `tests/qa3/QA_REPORT_3.md` §7:

- Apply 98–107 in order on test, read each script's OWNER CHECK lines, then production (report §8). Regenerate every open payroll run once after 103.
- Snapshot the live procedures that are newer than the repo (CON-7) into a numbered script, and check the live `usp_ExitPermission_Decide`, `usp_Booking_SetStatus` overlap, `fn_LocalNow` across the 25 October DST change, and the "tier" approver steps.
- Give the base-only Reject, Cancel, Hold, Resume and Delegate the lock pattern of script 101.
- Website: a per-booking secret for `/pay` and `/release` (the server side is closed).
- Reports filed by the branch of the day (REL-15); a leaver's open requests cancelled or re-routed automatically; recovery of days paid when a termination is recorded after its month was locked.
- Decide on read-committed snapshot (RCSI) to avoid deadlocks while payroll generates.

**Work queued**

1. ~~Make the MPGS configuration conditional on online deposits being enabled.~~ Done (QA3).
2. Finish the deploy scripts on the VM (`deploy.sh`, `rollback.sh`, nightly backup cron) and do one rehearsal deploy + rollback.
3. Settle the August 2026 payroll difference with HR: `docs/august-2026-recalc.md` lists 495.10 USD of under-withholding caused by the two blockers (rest days deducted, LBP counted as zero) in the locked run 17; pay it through adjustment requests in a Supplemental run. Run 17 itself stays untouched.
4. Decide the two outstanding attendance anomalies of 19 August that block August readiness.
5. Rotate the `sa` password and move the application to its least-privilege login; the old password is in git history.
6. ~~Roster page: wire the branch filter.~~ Done; QA3 also made copy and apply patterns branch-only.
7. Website month calendar (step 3): the site still asks day by day.
8. Front-end breadth testing: the suites cover the engine, not every page and role. Next pass should walk every page in both languages and at phone width, and exercise the workflow types the suites don't touch (onboarding, separation, shift swap, expenses, tips).
9. Real delivery checks: e-mail and WhatsApp are verified as *queued*, not as *received*; the fingerprint device has not been tested against the production API in push mode.
10. Run one full month (rosters → attendance → anomalies → payroll) in parallel with the old method before anyone is paid from the system.

---

## 13. Where to look first

| I need to… | Read |
|---|---|
| understand the day rule | `attendance.usp_Attendance_ComputeDay` and the QA-2 report |
| understand pay | `payroll.usp_PayrollRun_Generate` section by section |
| understand approvals | `workflow.usp_Request_Submit`, `_Approve`, `fn_CanUserActOnStep`, `usp_Request_ApplyApprovalEffects` |
| understand bookings | `booking.fn_PriceQuote`, `usp_Booking_Create`, `usp_Availability_GetDay`, the public controller |
| see what changed and why | `MokaCo.HRMS/docs/*.sql` (numbered, in order) and the two QA reports |
| know the project history | the "Programming" project docs: `PROGRESS.md`, `SQL_FINDINGS.md`, `BE_FINDINGS.md`, `S3_FINDINGS.md`, `WEBSITE_BOOKING.md`, `ENVIRONMENT.md`, `DEPLOYMENT.md` |

**Rules for whoever continues**: one prompt per feature, naming the folder it works in; SQL as numbered idempotent scripts applied with `-I`; no secrets in tracked files; the database is changed only by scripts; every deploy starts with a backup; and the live server is never edited by hand.
