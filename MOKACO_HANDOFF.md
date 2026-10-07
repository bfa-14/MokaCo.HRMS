# MokaCo HRMS + Online Booking — developer handoff

**Version:** 2026-10-07 · **Status:** live on a production VM, in rehearsal use · **Audience:** a developer or an AI agent taking over the codebase.

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

**attendance** — `DEVICE`, `RAW_LOG` (punches; `DEVICE_PUNCH_QUARANTINE` is a view over punches with no employee), `ATTENDANCE_RECORD` (one row per employee-day), `SHIFT`, `SHIFT_ASSIGNMENT` (the roster), the roster month/header row with its approval state, anomalies, corrections, `fn_AttributedWorkDate`, `usp_Attendance_ComputeDay` (**the** day rule), `usp_Attendance_ProcessRawLogs`, `usp_Attendance_ReprocessDay`, `usp_Attendance_MarkAbsentees`, `usp_Attendance_MarkLeaveDays`, `usp_Attendance_PayrollReadiness`, `usp_Attendance_GetWorkedWithoutRoster`.

**workflow** — `REQUEST_TYPE`, `REQUEST_DEFINITION` (versioned chains) and its steps, `REQUEST_INSTANCE`, `REQUEST_STEP`, `WORKFLOW_SIGNATURE`, `REQUEST_REVERSAL`, typed payload tables (`LEAVE_REQUEST`, `EXIT_PERMISSION`, `OVERTIME`, `SHIFT_SWAP`, `SALARY_ADVANCE_REQUEST`, `PAYROLL_ADJUSTMENT_REQUEST`, `EXPENSE_REIMBURSEMENT`, `TIP_DISTRIBUTION`, `ONBOARDING`, `SEPARATION`, `AVAILABILITY_CHANGE`, `ROSTER_APPROVAL`), `fn_ResolveApprover`, `fn_CanUserActOnStep`, `usp_Request_Submit/Approve/Reject/Hold/Resume/Cancel/RetractLastDecision/WithdrawDecision/Reopen/MoveToVersion`, `usp_Request_ApplyApprovalEffects`.

**payroll** — `SALARY_COMPONENT` (per employee, effective-dated), `PAYROLL_RUN`, `PAYROLL_RUN_RATE` (frozen rates), `PAYSLIP`, `PAYSLIP_LINE`, `SALARY_ADVANCE`, `PAYROLL_ADJUSTMENT`, NSSF/tax configuration tables, `fn_ToPrimary`, `fn_RunRate`, `fn_IsPeriodPaid`, `usp_AssertPeriodOpen`, `usp_PayrollRun_Create/Generate/SendToReview/Approve/Cancel`, `usp_Payslip_SetPayment`, `usp_Payslip_GetMyStatus`.

**booking** — `ROOM`, `ROOM_HOURS` (`OpenMin`/`CloseMin`), `ROOM_ADDON`, `ROOM_DISCOUNT` (by hours; `RoomId NULL` = applies to all), `DEPOSIT_TIER`, `BOOKING` (+ computed `StartMin`/`EndMin`/`Hours`, `BookingRef`, `DepositPercent`, `DiscountPercent/Amount`, `HoldExpiresUtc`, gateway ids, `CancelledBy`, `RefundAmount`, `RefundStatus`), `BOOKING_ADDON`, `BOOKING_PAYMENT` (refunds are negative rows with `IsRefund = 1`), `BOOKING_BLOCK` (staff blocks), `fn_LocalNow`, `fn_DepositPercent`, `fn_PriceQuote`, `fn_RefundDue`, `fn_MailKindForStatus`, and the public procedures listed in §7.8.

**report** — reporting procedures (daily/monthly attendance, payroll, bookings).

---

## 5. Roles and permissions

Roles in use: **Owner**, **General Manager** (also spelled `GeneralManager` in some procedures), **HR**, **Admin**, **Operations Manager**, **Manager** (branch manager), **Employee**.

Permission codes (`security.PERMISSION`, shown as module cards on Security → Role Permissions):

```
EMP_VIEW, EMP_EDIT, EMP_VIEW_ALL
ATTENDANCE_VIEW, ATTENDANCE_CORRECT, ATTENDANCE_IMPORT, ATTENDANCE_MANAGE, DEVICE_MANAGE
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
- **Signature passwords**: steps (or approvers) marked as requiring a signature need the user's password with every decision; it is verified *before* any procedure runs, so a wrong password writes nothing. There is no grace period — every signed decision asks again.
- **Employee role hygiene**: the Employee role must not hold `REQUEST_RAISE_OTHERS`, `REQUEST_VIEW_ALL` or `WORKFLOW_CONFIGURE`.
- `SYSTEM_RESET` / setting `AllowSystemReset` wipes transactional data. Keep it off.

---

## 6. Settings that change behaviour

All in `core.SETTING`, surfaced on the Settings page grouped by section.

**Attendance** — `AttendanceToleranceMinutes` (default 10), `PunchDirectionMode` (`Alternate`), `PunchDebounceMinutes` (1), `OvernightAttributionHours` (4), `FullDayThreshold` (1.00), `ExitLeaveBasis` (`Actual` | `Approved`), `StandardWorkDayHours`, `MachinePullEnabled`, `MachinePullAutoProcess`.

**Leave** — `LeaveCountsRestDays` (0), `LeaveAllowNegativeBalance` (0), `LeaveCarryOverMaxDays`, `LeaveCarryOverExpiresOn` (MM-DD, empty = never), `LeavePayoutOnTermination` (1).

**Payroll** — `StandardWorkingDaysPerMonth` (26), `PayrollRateType` (`Official` | `NonOfficial` — which exchange rate a run snapshots), `TaxFamilyDeductionAnnualUsd`, NSSF rates and ceiling, `HolidayWorkRate` (2.0).

**Booking** — `BookingWebsiteEnabled`, `BookingApiKey` (server-to-server callers), `BookingCorsOrigins`, `BookingSiteUrl`, `BookingNotifyEmail`, `BookingDepositRequired`, `BookingDepositFloor`, `BookingHoldMinutes` (15), `BookingTimeZone`, `BookingLeadMinHours`, `BookingLeadMaxDays`, `BookingMaxHours`, `BookingCancelHours`, `BookingTurnaroundMinutes` (5), `BookingDepositRefundableOnGuestCancel` (0), `BookingFromEmail` (`bookings@mokanco.com.lb`), `BookingFromName`, `BookingSmtpHost/Port/User/Password`, `BookingEmailOnRequest/OnConfirm/OnCancel/OnRefund`, `BookingStaffAlert`, `BookingWhatsAppOnRequest/OnConfirm/OnCancel`, `BookingWhatsAppTemplate`, `BookingWhatsAppLang`.

**Notifications** — SMTP host/port/user/password/SSL for HR mail, `WhatsAppEnabled`, `WhatsAppApiUrl`, `WhatsAppPhoneNumberId`, `WhatsAppToken`, `WhatsAppTemplate`.

API-level configuration (not in the database): `ConnectionStrings:MokaCo`, `Jwt:*`, `MPGS_BASE`, `MPGS_MERCHANT_ID`, `MPGS_API_PASSWORD`, `MPGS_API_VERSION`, `MPGS_TEST_3DS_BYPASS`, `BOOKING_SITE_URL`, `API_PUBLIC_URL`.

---

## 7. Modules, features and business rules

### 7.1 Employees and organisation

Employees belong to a branch, a department and a position, and carry a **seniority tier** (`APPROVAL_TIER`, **1 = head** of the hierarchy, 9 = lowest; the direction was flipped deliberately — decision D6). Tiers drive approval chains and salary bands: a tier may define `MinBasicSalary` / `MaxBasicSalary`, and a trigger on `SALARY_COMPONENT` refuses a basic salary outside the employee's band.

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
ExitActualMinutes  = MidDayGapMinutes + EarlyExitMinutes
ExitApprovedMinutes= Σ approved exit-permission minutes for that employee/date (recomputed every run)
OvertimeMinutes    = max(0, LastOut − ShiftEnd)                -- payable = min(approved, detected)
WorkedMinutes      = (min(LastOut, ShiftEnd) − EffectiveIn) − Break − MidDayGapMinutes
CoveredMinutes     = exit-permission minutes that overlap the late/early window
                   + minutes inside the tolerance
                   + anomaly minutes whose HR decision is Excuse (or Overtime/Ignore disposition)
DayFraction        = min(1, (WorkedMinutes + CoveredMinutes) / Standard)
```

Status precedence for a day: **approved leave → public holiday → rostered rest day → punches**. A leave day stays `Leave` even if the employee punched; a rest day worked is `RestDay` with the worked minutes visible (paid as overtime only when an approved overtime request exists); a holiday is paid and never an absence. No roster row **in an approved roster month** = no record and no deduction (the day is listed under "Worked without roster" when there are punches). Where the month's roster is not approved, days are still derived from the default pattern.

**Tolerance and anomalies.** Late arrival or early departure **below** `AttendanceToleranceMinutes` is ignored. Equal or above, it creates an anomaly (`LateArrival`, `EarlyDeparture`, `HalfDayAbsence`, missing punch…) that HR or the Operations Manager decides: **Excuse** (paid), **Deduct** (the minutes reduce the day) or **Correct time** (fix the punch). Until decided the day is paid in full, but **undecided anomalies block payroll readiness** for the period. A shift's `GraceMinutes` may override the setting (NULL = use the setting). Decisions survive reprocessing and a tolerance change; they are cleared, with a note, when the punch itself changes (a correction, a late-arriving punch), because the decision answered a fact that no longer holds.

**Exit permissions** (leaving during the shift) are approved through the workflow with a time window. The approved window covers the matching late arrival or early departure, so only the uncovered part becomes an anomaly; remaining approved minutes cover mid-day gaps. Several permissions on one day are allowed. At period close, used permission minutes are converted to leave (`ExitLeaveBasis` decides *actual* vs *approved* minutes), **once per day**; minutes beyond the remaining leave balance become an unpaid-leave deduction instead of a negative balance.

**Corrections** are manual records or punch fixes by permission; they survive reprocessing and are refused on a period already paid for that employee ("This period is paid — raise a payroll adjustment instead").

**Rosters.** Monthly, per branch: shifts (with overnight support), rest days, copy-from-previous-period (copies the most frequent shift per weekday and never rosters a working shift on a public holiday), apply pattern, gaps report. A month is submitted as a `ROSTER_APPROVAL` workflow request (one open request per branch and month; re-submission after rejection; a change after approval supersedes the old request). When the last approver signs, `usp_Request_ApplyApprovalEffects` sets the month to Approved and stamps `AppliedAt` — without this the shifts are never used (a real blocker: a whole month was processed as "unrostered"). After approval, past days and days with recorded attendance are locked; future days may be changed by permission holders, which flags `ChangedSinceApproval` and asks for re-submission. A roster may be cleared only while Draft/Rejected and with no processed attendance.

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

Behaviour:

- **Submit** resolves every step. A step with no resolvable approver (sole member, the requester themself, no deputy) is skipped with a recorded reason. If every step skips, the request is auto-approved — and the effects are applied explicitly (historically they were silently skipped, so an approved advance never created the advance).
- **Deputies** sign only when the main approver is genuinely absent (approved leave today, or a disabled account) or when the main approver explicitly delegated that step; delegation can be reclaimed, and the delegator is locked out while it is handed over (decision D8). Organisational types (e.g. roster approval) are exempt from the "never your own request" rule (D8).
- **Advisory rejection**: a rejection before the final step is advisory; the final approver may overrule with a note.
- **Hold / Resume**: a step can be put on hold, optionally "waiting on the requester", who may then resume it.
- **Retract last decision** (same day, by the last signer, password-gated), **Withdraw decision** (while the request is still open), **Reopen** (rejected or cancelled requests; a *two-signature* GM + Owner act, order-free, which re-checks the block reason at the second signature).
- **Reversals** undo effects: leave ledger rows removed and attendance re-derived, advances and adjustments deleted, swaps reversed. `fn_ReversalBlockReason` refuses what cannot be undone.
- **Cancel** is gated in the procedure (requester, the subject employee, HR or Admin) as well as in the API.
- **Decisions are concurrency-safe**: the step update checks the expected previous status and the row count.
- **Notifications**: on close, the e-mail/WhatsApp outbox gets a message with a PDF of the request; manual resend exists for every role.

### 7.5 Payroll

**Inputs**: salary components per employee (effective-dated, standing or one-off), attendance (`DayFraction`, anomaly decisions, unpaid leave, overtime), approved adjustments and advances, exchange rates, NSSF and tax configuration.

**Runs**: `Primary` (one per period, creatable on any day of the period) and `Supplemental` (any time, pays approved, unconsumed adjustments; one open at a time). Lifecycle: Create → Generate → Send to review → Approve (Owner) → locked → payslips marked paid. A run **snapshots the exchange rates** it uses (`PAYROLL_RUN_RATE`), so later rate changes never move historical pay. Readiness refuses to run while the period has unprocessed punches, undecided anomalies or unmapped device punches **up to today** (later days in the month don't block).

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

Errors are `{ error, code }` with codes `invalid_input`, `room_unavailable`, `closed`, `lead_time`, `slot_taken` (409), `hold_expired` (409), `not_found`, `paused` (503), `unauthorized`, `cancel_window`, `not_cancellable`. Access: a browser from an origin in `BookingCorsOrigins`, or a server sending `X-Booking-Key` equal to `BookingApiKey`; rate-limited per IP. `BookingWebsiteEnabled = 0` pauses online booking and the site shows the WhatsApp fallback.

**SignalR** `/hubs/booking`: group `staff` (authenticated) receives `BookingChanged`; group `booking:{ref}` (anonymous, joined with a valid reference) receives `BookingStatus`. The confirmation page uses it and falls back to a 30-second poll.

**Card payments (MPGS, Bank of Beirut)** — hosted checkout: a session is opened at create time when a deposit is required, `usp_Booking_SetGateway` stores the order and session ids, the gateway returns to `/verify`, and `usp_Booking_ConfirmPaid` is idempotent by gateway reference. Configuration keys `MPGS_BASE`, `MPGS_MERCHANT_ID`, `MPGS_API_PASSWORD`, `MPGS_API_VERSION`, `MPGS_TEST_3DS_BYPASS`.

### 7.8 Notifications

One outbox (`core.EMAIL_OUTBOX`) for both channels. Rows carry the booking or request id, the mail kind, language, channel, attempt count, and — for booking mail — the sender address, name, SMTP account and template. `usp_Email_GetPending` **claims** rows (double-send proof; it once sent the same mail eleven times), retries three times at five-minute intervals, and the worker attaches a QuestPDF document for closed requests. Bodies are bilingual (English / Arabic) by the employee's preferred language. WhatsApp uses the same outbox and sends when the Meta credentials are filled.

### 7.9 Reports and dashboards

Daily and monthly attendance, payroll runs and payslips, bookings (period, room, discounts, refunds), leave balances, tier violations, workflow monitors (stalled requests, role health, chain state). Role-based dashboard cards: my salary status, pending approvals, today's attendance, bookings of the day.

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

**Rules settled during the deep QA pass** (full list in `tests/qa2/QA_REPORT_2.md`): exit permissions cover by *window*; what a permission covers is not an anomaly at all; "unrostered day" only applies inside an approved roster month; a decision answers a fact, so it survives reprocessing but is cleared when the punch changes; "the period is paid" is per employee; a leave costs rostered working days (fixed-entitlement types count calendar days); partial approval keeps the first days; the balance check counts pending requests and is skipped for discretionary types; carry-over is consumed first; a transfer is dated and `EMPLOYEE.BranchId` means today; an attendance record belongs to the employee's branch of that day, not the terminal's; proration is per component's own dates; leave payout sits outside the NSSF and tax base while holiday work sits inside; an advance instalment is capped per currency, oldest first.

---

## 9. Quality: the test suites

| Suite | Where | What it is |
|---|---|---|
| `tests/qa` | `MokaCo.HRMS/tests/qa` (`bash tests/qa/run.sh`) | 216 checks: rosters, attendance, leaves, payroll, bookings, permissions, cultures, responsive smoke |
| `tests/qa2` | `MokaCo.HRMS/tests/qa2` (`bash tests/qa2/run.sh`) | 67 checks of **complex** scenarios: same-day combinations, overnight + DST + month end, leave edge cases, roster changes, payroll proration and statutory math, plus browser checks |
| unit tests | `dotnet test` | 332 tests |

Both suites seed everything with a `QA ` / `QA2 ` prefix, run inside transactions where the data is real (payroll), and `cleanup.sql` removes their rows and **verifies integrity**: real row counts plus checksums of rosters, attendance records and the leave ledger must match the baseline taken at seed time. Reports: `QA_REPORT.md` and `tests/qa2/QA_REPORT_2.md` (bug table, rules decided, features added, disposition per finding).

Current state: `qa2` 67/67, `qa` 216/216, `dotnet test` 332/332.

If a suite is interrupted, run its `cleanup.sql` before anything else — it also restores the settings the suite changed.

---

## 10. Environments, deployment and operations

**Development (laptop)** — Ubuntu, .NET 8 SDK (`~/.dotnet`), Node 22, SQL Server 2025, VS Code with the *SQL Server (mssql)* extension (Schema Compare, Database Projects) and *Remote - SSH*. `npm run dev` in `mokaco-web-mantine` starts the API and the web together (concurrently); the Vite proxy must point at `http://localhost:5078`.

**Production (VM)** — SQL Server **Express**, the API as a systemd unit reading `/etc/mokaco/api.env`, nginx with TLS proxying `/api` and `/hubs` (WebSocket upgrade headers) to Kestrel on 127.0.0.1, the HRMS web built and served as static files, `ufw` allowing 22/80/443 only (1433 never public), timezone `Asia/Beirut`.

**Deploy flow** (agreed): develop on a branch → merge to `main` on GitLab → tag → on the VM a script backs up the database, checks out the tag, applies any new `docs/*.sql` in order, builds, restarts the service, health-checks, and rolls back to the previous tag on failure. The VM authenticates to GitLab with a read-only **deploy token**. Deploy at closing time. The website deploys from GitHub by its own owner.

**Database on the server**: built by **restoring a backup** of the developer database, not by replaying `docs/*.sql` (those are only the later patches; the base schema, the seeds and the real data are not in the repo). A backup restores only onto the same or a newer SQL Server major version — check `SELECT @@VERSION` on both sides first; if the versions don't line up, move it as a `.bacpac` with `sqlpackage`.

**Backups**: Express has no SQL Server Agent, so a cron job runs `BACKUP DATABASE` nightly, keeps 14 days and copies every file **off** the VM. Every deploy starts with a backup.

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
12. The API refuses to start when the MPGS keys are missing — including on a developer machine. Fix it so the gateway is only required when online deposits are enabled (see open items).

---

## 12. Open items

**Decisions needed from the owner**

- Should the "unrostered day = no record" rule apply everywhere, or only inside approved roster months (current behaviour)?
- Does the Operations Manager need `EMP_VIEW_ALL` (see all branches)?

**Work queued**

1. Make the MPGS configuration **conditional** on online deposits being enabled, so a missing gateway key cannot stop payroll and attendance from starting.
2. Finish the deploy scripts on the VM (`deploy.sh`, `rollback.sh`, nightly backup cron) and do one rehearsal deploy + rollback.
3. Settle the August 2026 payroll difference with HR: `docs/august-2026-recalc.md` lists 495.10 USD of under-withholding caused by the two blockers (rest days deducted, LBP counted as zero) in the locked run 17; pay it through adjustment requests in a Supplemental run. Run 17 itself stays untouched.
4. Decide the two outstanding attendance anomalies of 19 August that block August readiness.
5. Rotate the `sa` password and move the application to its least-privilege login; the old password is in git history.
6. Roster page: wire the branch filter (the API already takes `branchId` as of the work date).
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
