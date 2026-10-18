# Auto-roster (6/5 rhythm, fair weekends)

One action per branch and month that drafts the roster: every employee alternates a **6-day week**
(1 rest day) and a **5-day week** (2 rest days), Saturdays and Sundays off are **shared fairly**, and
leaves, public holidays, locks and the manager's own edits are respected. The draft is shown in the
roster grid, edited there, and saved in one atomic call; the month is then submitted for approval
exactly as before. Nothing is saved on its own.

This file is the specification the code follows (SQL `docs/96_auto_roster.sql`, C#
`Services/Attendance/AutoRoster/*`, `AutoRosterController`, web `RosterPage` + `AutoRoster*`).

---

## 1. Decisions (defaults; each is a setting or a drawer option unless marked fixed)

| # | Decision | Default |
|---|---|---|
| D1 | Week | Monday–Sunday (fixed; every existing mask and pattern is Monday-first). Week index `W(d) = (d − 1900-01-01) div 7` (1900-01-01 is a Monday). |
| D2 | Rhythm start | **Aligned** (setting `RosterRhythmStart`): an employee's first planned week is a **6-day week**, then 5, 6, 5… continuously, never restarting at a month end. *Staggered* (option) starts half the team on a 5-day week so the number on duty is even week to week. |
| D3 | Rhythm memory | The starting week is stored once (`attendance.ROSTER_RHYTHM`) on the first save; the manager can flip it ("this week is a 5-day week"). |
| D4 | Public holiday | An **extra day off**: no row (as copy-period already does). It does not use up the week's rest days (`RosterHolidayCountsAsRest = 0`). Cover per holiday is chosen in the drawer, default 0 (closed); cover goes to the people with the fewest holidays worked in the last 12 months. |
| D5 | Leave (Approved, Pending, OnHold) | A leave day is **never a rest day**. An existing row inside a leave is never changed; an empty leave day gets a working row (so the leave costs exactly what it was priced at and payroll's unpaid-leave deduction does not move). If the week has no room for its rest days outside the leave, the rest is **absorbed by the leave** (info issue `REST_ABSORBED_BY_LEAVE`). A half-day leave day is a working day. Rest rows on leave days count neither as rest nor in the weekend ledger. |
| D6 | Weekly-pattern rest days | **Preference** (setting `RosterPatternRestDays = Preference`): preferred for the weekday rest; fairness and the 6/5 rule win. `Unavailable` makes them fixed rest days. Working on a pattern rest day is reported (info `PATTERN_REST_WORKED`). |
| D7 | Consecutive working days | Hard cap `RosterMaxConsecutiveWorkDays = 7`; preferred ≤ `RosterPreferredMaxConsecutiveWorkDays = 6`. Leave days, holidays off and rest days break a run. |
| D8 | Staffing | Optional minimum/target on duty per branch per weekday, optionally per shift (`attendance.STAFFING_REQUIREMENT`). Without any, rest days are spread so the number on duty is level across the week. **Rest days beat staffing**: nobody loses a rest day to cover; a day below the minimum is flagged `SHORT_STAFFED`. |
| D16 | Shifts to cover | **Every shift the branch runs is covered every day** (morning and evening), not only a total on duty. Which shifts: the branch's stored per-shift staffing rows (a minimum of 0 = "need not be covered"); without any, the shifts it runs, found from its roster (§2.6, `ShiftCoverDetector`), each with a minimum of 1. Rest days are spread so every day holds enough people for all its shifts, and a shift still short takes someone from a shift that can spare them (reason `WORK_SHIFT_COVER`). Rest days still beat staffing: a shift nobody can cover is flagged `SHIFT_UNCOVERED`. |
| D9 | Weekend fairness | Saturday and Sunday counted separately with a fair-share **owed** balance recomputed from real rows (26 weeks, `RosterFairnessLookbackWeeks`) plus the plan so far. Nothing stored. |
| D10 | Never touched | Paid days; days before today (Beirut) in **any** month state; days with an attendance record; pinned days; rows inside a leave; facts outside the target month. The whole branch-month is refused while a roster approval is waiting. |
| D11 | Modes | `FillEmpty` (default on the first run: only empty days), `ReplanAuto` (default afterwards: empty + days still equal to what the generator wrote; manual edits survive), `ReplanAll` (everything except pinned/locked/leave; the drawer asks for confirmation). |
| D12 | Who may run it | `ATTENDANCE_MANAGE` (as every roster write), scoped to the branches the caller may see (`hr.fn_CallerScope`: EMP_VIEW_ALL, or the branch's manager). No role grant is changed. |
| D13 | Automatic monthly run | Not in v1: it never saves on its own. |
| D14 | Payroll `StandardWorkingDaysPerMonth` | Unchanged (26). The preview shows the rostered work days per person so HR can compare (6/5 gives ≈ 24). |
| D15 | Legal hours | Warnings only: weekly rest < 36 h (`RosterMinWeeklyRestHours`), < 11 h between shifts (`RosterMinHoursBetweenShifts`). |

---

## 2. The planner (pure C#, deterministic: no clock, no randomness, no I/O)

### 2.1 Window and day classes

- Target month `M`. Window = Monday on/before the 1st → Sunday on/after the last day. History =
  `RosterFairnessLookbackWeeks` weeks before the window (rows, leave, holidays).
- Staff = employees (not deleted) employed on at least one window day whose branch of that day
  (`hr.fn_EmployeeBranchOn`) is the target branch, minus those the drawer marks **off rotation**
  (stored `ROSTER_RHYTHM.OnRotation = 0`). Off-rotation staff are shown, never planned.
- Every staff × window day is classified (first match wins):

| Class | Meaning | Planner treats it as |
|---|---|---|
| `NotEmployed` | before hire, after termination | nothing (no row is ever written) |
| `OtherBranch` | employed, branch of day ≠ target | fact if a row exists, else unknown (not plannable, not rest) |
| `Locked` | in month: paid, before today, has an attendance record (any month state) | fact (row as it is, or none) |
| `Outside` | window day outside `M` | fact if a row exists; **ghost** (plannable, never saved) if no row and not before today; else unknown |
| `Pinned` | `ROSTER_CELL.IsPinned = 1` and a row exists | fact |
| `Leave` | full-day leave | existing row: fact (frozen); no row: **work** (fixed) |
| `HalfLeave` | half-day leave | existing row: fact; no row: work (fixed) |
| `Holiday` | public holiday of the branch | cover chosen (§2.4): work (fixed); else **holiday off** (desired: no row) — unless an existing row is protected by the mode (then fact) |
| `Draft` | a manager edit sent with the preview (`draftCells`) | fixed as sent |
| `Unavailable` | pattern rest day when `RosterPatternRestDays = Unavailable` | rest (fixed) |
| `Existing` | a row exists | `FillEmpty`: fact. `ReplanAuto`: plannable if it equals the stored auto value, else fact (manual). `ReplanAll`: plannable |
| `Empty` | no row | plannable |

A fact is never changed. Plannable days become **rest** or **work**.

### 2.2 Rhythm (6/5)

- `T(e,w)` = `AnchorWorkDays` if `W(w) − W(AnchorWeekStart)` is even, else `11 − AnchorWorkDays`.
- No stored rhythm: anchor = the first window week in which the employee is employed.
  - Aligned: `AnchorWorkDays = 6`, unless the facts of that week already hold ≥ 2 rest rows → 5.
  - Staggered: employees without a stored rhythm are ordered by (PositionId, HireDate, EmployeeId) and
    given 6/5 so that, together with the stored rhythms of the branch, the count of 6-day and 5-day
    first weeks differs by at most 1; ties start on 6.
- `rhythmOverrides` from the drawer set (anchor week, work days) for an employee; they are saved on commit.
- Each new or overridden rhythm is returned in the preview and saved by the commit (`ROSTER_RHYTHM`).

### 2.3 Rest quota per week

```
employed(e,w)   = employed days of e in week w (any branch)
quota(e,w)      = max(0, employed(e,w) − T(e,w) − (HolidayCountsAsRest ? holidaysOff(e,w) : 0))
fixedRests(e,w) = rest facts + Unavailable + Draft rests in the week (rests on leave days do not count)
need(e,w)       = max(0, quota − fixedRests)          fixedRests > quota → info RHYTHM_OVER
plannable P     = plannable days of the week that are not leave/half-leave/holiday
need > |P|      → need = |P|; if the cause is leave → info REST_ABSORBED_BY_LEAVE else warning RHYTHM_SHORT
```

A full week gives 1 rest day (6-day week) or 2 (5-day week). Someone hired on a Thursday works
Thu–Sun with no rest that week (4 − 6 < 0).

### 2.4 Holidays first

For each holiday `h` of the branch in `M` (all-branch rows or the branch's own): `cover(h)` from the
drawer (default 0). Working facts on `h` count as cover. Choose the remaining cover among plannable
staff that day by fewest holidays worked in the last 12 months, then EmployeeId rotated by `W(h)`.
Chosen → work (fixed, reason `WORK_HOLIDAY_COVER`). Others → holiday off (`HOLIDAY_OFF`): no row; an
existing row that the mode lets us change is **deleted**. A rest **fact** on a holiday hides it
(rest outranks holiday in the day rule): warning `HOLIDAY_HIDDEN_BY_REST`.

### 2.5 Week by week (oldest first)

```
for each week w in window:
  1 options(e) = every subset S ⊆ P(e,w) with |S| = need(e,w) such that
        - the working runs it creates (counting the run carried in from previous days, and the
          next known rest/leave/holiday/unknown day after the week) never exceed the hard cap;
        - the run left at Sunday stays ≤ the look-ahead for (e,w): computed backward from the end
          of the window, the longest run that lets every later week keep its 6/5 without an extra
          rest or a breach; for the last week it uses the saved rows after the window (up to
          HorizonTo = WindowTo + cap; no row counts as a break).
     none feasible → relax the cap for this person and week (error CONSECUTIVE_CAP when planned
     days create the breach, warning when facts already do).
  2 slots: target rests per day by water-filling Σ need over the week's days:
        give the next slot to the day with the highest (onDuty(d) − slots(d) − min(d)) among days
        where some person with need can rest; ties → fewer slots, then calendar order.
     onDuty(d) = staff who would work d if no more rests were placed; min(d) from staffing (0 if none),
     at least Σ the minimums of the shifts d must cover (D16); target(d) likewise Σ their targets.
  3 forced: a person all of whose options contain a weekend day takes it (consumes the slot).
  4 weekend (Saturday first in even weeks, Sunday first in odd weeks), for each weekend day x:
        eligible = need left > 0, x not already chosen, and some remaining option ⊇ (chosen ∪ {x})
        order    = owed(x) desc, owedTotal desc, consecutive weekends worked desc, rotation(e,w)
        take up to slots(x) people → reason REST_WEEKEND_OWED
        after each pick: options(e) ← options containing all chosen days
     people not picked for x: drop options containing x (unless that leaves none → they are forced).
  5 weekdays: people with need left, most constrained (fewest options) first, choose the option with
     the lowest cost:
        Σ load(d) above target for chosen days            (keeps on-duty level / ≥ min)
        + per person the shift this person starts on (§2.6) would fall below its minimum (D16)
        − pair bonus (5-day week, adjacent rest days)       RosterPairRestDays
        − pattern bonus (pattern rest day, Preference)
        − stability bonus (equals the current AUTO value)
        + penalty for runs > preferred max
        + penalty for a large run left at Sunday
     reasons: REST_LEVEL | REST_PAIR | REST_PATTERN | REST_CONSECUTIVE
  6 repair: a day below min(d) → move one rest of someone resting that day to another day of one of
     their options that stays ≥ min; else warning SHORT_STAFFED (rest days are kept). Days of the
     target month only: a ghost day is never saved, so a repair that read it would move a saved rest
     at every regenerate.
  7 ledger: add the week's Saturday/Sunday results (facts and plan) to the owed balances.
```

**Weekend ledger** (`WeekendLedger`), per weekend day `x ∈ {Sat, Sun}` over history + plan so far:
pool(d) = staff employed on d, with a row on d, not on leave, not holiday off. For each d of kind x:
`rested(d) = |{e ∈ pool : rest row}|`; each e in pool earns `rested(d)/|pool|` and is debited 1 if it
rested. `owed(e,x) = earned − rested`. Rest rows on leave days are ignored.

### 2.6 Shifts for working days, and the shifts to cover (D16)

**Start shift** of a working day: pattern shift for that weekday (active) → else the employee's most
frequent shift in the 4 weeks before the window → else the drawer's default shift → else the first
active shift. Overnight shifts belong to their start day. Inactive shifts are never written.

**Shifts to cover** (`PlannerInput.ShiftCover`): the branch's stored per-shift staffing rows when it has
any; otherwise found by `ShiftCoverDetector` — an active shift worked in the branch on at least a quarter
of the days the branch worked in the 8 weeks before the window (and on 4 days at least), or named by the
weekly patterns of the staff on rotation on 2 weekdays or more — each with minimum 1, every day. A closed
holiday needs none; an open one (cover > 0) needs every shift its cover allows.

**Covering them**, day by day, oldest first (only working days the run decides move — never a fact, a
draft edit or a leave day's row):
1. someone who worked a shift to cover yesterday that was not their own (moved, or set by hand) stays on
   it when going back would be a turnaround under `RosterMinHoursBetweenShifts`, if their shift can spare
   them (the evening's cover does not start at seven the next morning);
2. the shift furthest below its minimum takes the cheapest person from a shift above its own minimum or a
   shift nobody has to cover;
3. then a shift below its target, from a shift above its own target (or minimum), never into a turnaround.

Move cost, largest first: 50 turnaround (the day before, or the day after when the person could not stay
on the shift then); 20 an evening, one day off, then a morning under `RosterMinWeeklyRestHours`; 10 leaving
a shift nobody has to cover; 8 leaving the shift the generator saved there (−8 going back to it: a
regenerate moves the same people); 4 leaving the weekly pattern's shift, and 4 staying on the shift the
next day too; 3 per day already worked off one's own shift this month (moves are shared); 2 a shift not
worked in the last 8 weeks. Ties turn with the day. A ghost day is the next month's: it never decides who
covers, and on the first one after the month a cover from the last day carries on.

### 2.7 Validator (`RosterPlanValidator`, also run by the commit on the submitted cells)

| Code | Severity | When |
|---|---|---|
| `MONTH_LOCKED` | error | a roster approval is waiting for this branch-month |
| `WORK_WITHOUT_SHIFT` | error | a working cell without an active shift |
| `REST_ON_HOLIDAY` | error | a planned/edited rest row on a holiday |
| `CONSECUTIVE_CAP` | error (planned) / warning (facts) | run > hard cap |
| `HOLIDAY_HIDDEN_BY_REST` | warning | a rest fact on a holiday |
| `RHYTHM_SHORT` / `RHYTHM_OVER` | warning / info | rests in a week ≠ quota |
| `REST_ABSORBED_BY_LEAVE` | info | rest could not be placed outside a leave |
| `SHORT_STAFFED` | warning | on duty below the minimum (day, or a shift that has somebody) |
| `SHIFT_UNCOVERED` | warning (info on an open holiday) | a shift to cover (D16) with nobody on it |
| `TURNAROUND` | warning | < min hours between two shifts |
| `WEEKLY_REST_HOURS` | warning | longest weekly rest < min hours |
| `PATTERN_REST_WORKED` | info | working on a weekly-pattern rest day |
| `LONG_RUN` | info | run > preferred max (≤ hard cap) |

### 2.8 Result

For every target-month cell (never ghosts): desired state vs the current row →
`insert | update | delete | unchanged | kept` (kept = fact). Counters: per employee work days, rest
days, Saturdays off, Sundays off, owed Sat/Sun, and the week strip (type, rests, ok); per day on
duty vs min/target, and on each shift to cover vs its min/target.

---

## 3. SQL — `docs/96_auto_roster.sql`

Idempotent (`IF NOT EXISTS`, `CREATE OR ALTER`), `QUOTED_IDENTIFIER ON`, no `USE`, refusals
`RAISERROR(msg,16,1)` + `RETURN 1` (and `ROLLBACK` in a transaction), Beirut today =
`CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE)`.

### 3.1 Tables

```
attendance.ROSTER_RHYTHM (
  EmployeeId INT NOT NULL PK FK hr.EMPLOYEE,
  AnchorWeekStart DATE NULL  CHECK (DATEDIFF(DAY,'19000101',AnchorWeekStart) % 7 = 0),  -- a Monday
  AnchorWorkDays TINYINT NULL CHECK (AnchorWorkDays IN (5,6)),
  -- CK_RosterRhythm_Anchor: both set or both NULL. NULL = taken off rotation before any rhythm was
  -- known; the flag alone is stored, and a comeback starts on a 6-day week (D2).
  OnRotation BIT NOT NULL DEFAULT 1,
  UpdatedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), UpdatedBy INT NULL)

attendance.ROSTER_CELL (
  EmployeeId INT NOT NULL, WorkDate DATE NOT NULL, PK (EmployeeId, WorkDate), FK hr.EMPLOYEE,
  AutoState VARCHAR(10) NULL CHECK (AutoState IN ('work','rest','none')),  -- what the generator wrote; NULL = manual
  AutoShiftId INT NULL, AutoRunId INT NULL,
  ReasonCode VARCHAR(40) NULL, ReasonArgs NVARCHAR(400) NULL,
  IsPinned BIT NOT NULL DEFAULT 0, PinnedBy INT NULL, PinnedAt DATETIME2(3) NULL,
  UpdatedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME())
  -- a row is AUTO while SHIFT_ASSIGNMENT equals AutoState/AutoShiftId ('none' = no row);
  -- any other writer (Upsert, CopyPeriod, swap) makes it manual without being changed.

attendance.ROSTER_AUTO_RUN (
  RunId INT IDENTITY PK, BranchId INT NOT NULL, MonthDate DATE NOT NULL, Mode VARCHAR(20) NOT NULL,
  ParamsJson NVARCHAR(MAX) NULL, RowsInserted INT, RowsUpdated INT, RowsDeleted INT, IssueCount INT,
  CreatedBy INT NULL, CreatedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME())

attendance.STAFFING_REQUIREMENT (
  StaffingRequirementId INT IDENTITY PK, BranchId INT NOT NULL FK hr.BRANCH,
  DayOfWeek TINYINT NULL CHECK (DayOfWeek BETWEEN 1 AND 7),   -- NULL = every day
  ShiftId INT NULL FK attendance.SHIFT,                        -- NULL = any shift
  MinOnDuty INT NOT NULL CHECK (MinOnDuty >= 0), TargetOnDuty INT NULL,
  IsActive BIT NOT NULL DEFAULT 1,
  CHECK (TargetOnDuty IS NULL OR TargetOnDuty >= MinOnDuty))
  -- precedence: a weekday row beats an every-day row (same ShiftId).
```

### 3.2 Settings (`core.SETTING`, Section `'Roster'`, SortOrder 10..90)

| Key | Value | DataType |
|---|---|---|
| RosterRhythmStart | `Aligned` (`Aligned` \| `Staggered`) | string |
| RosterHolidayCountsAsRest | `0` | bool |
| RosterMaxConsecutiveWorkDays | `7` | int |
| RosterPreferredMaxConsecutiveWorkDays | `6` | int |
| RosterFairnessLookbackWeeks | `26` | int |
| RosterPairRestDays | `1` | bool |
| RosterPatternRestDays | `Preference` (`Preference` \| `Unavailable`) | string |
| RosterMinHoursBetweenShifts | `11` | int |
| RosterMinWeeklyRestHours | `36` | int |

### 3.3 Procedures (caller is always the **last** parameter)

**`attendance.usp_AutoRoster_GetContext @BranchId INT, @MonthDate DATE, @LookbackWeeks INT = NULL, @CallerUserId INT = NULL`**
Refuses `'Branch not found.'`; `'You can only plan rosters for the branches you manage.'` (caller not
EMP_VIEW_ALL and not `hr.BRANCH.ManagerEmployeeId`). `@LookbackWeeks NULL` → the setting.
Result sets, in this order:

1. **Header**: `BranchId, BranchName, MonthDate, WindowFrom, WindowTo, HistoryFrom, Today, MonthStatus, OpenRequestId`
2. **Settings**: `SettingKey, SettingValue` (keys `Roster%`)
3. **Staff**: `EmployeeId, FullName, PositionId, Position, HireDate, TerminationDate`
4. **StaffDays**: `EmployeeId, WorkDate, BranchId` — every employed day HistoryFrom..WindowTo (branch of that day)
5. **Rows**: `EmployeeId, WorkDate, ShiftId, IsRestDay` — SHIFT_ASSIGNMENT of the staff, HistoryFrom..HorizonTo (WindowTo + RosterMaxConsecutiveWorkDays, clamped 1..31), **all branches** (read after the branch is authorised)
6. **Locks**: `EmployeeId, WorkDate, Reason` (`Paid` | `Past` | `Recorded`) — target-month staff days
7. **Holidays**: `HolidayDate, BranchId, IsPaid, Name` — 12 months before WindowFrom .. WindowTo, rows with BranchId NULL or = @BranchId
8. **HolidaysWorked**: `EmployeeId, Days` — working rows on those holidays in the 12 months before WindowFrom
9. **Leaves**: `EmployeeId, FromDate, ToDate, HalfDay, Status, IsPaid` — Approved/Pending/OnHold, overlapping HistoryFrom..HorizonTo
10. **Shifts**: `ShiftId, Name, StartTime, EndTime, CrossesMidnight, BreakMinutes, IsActive` (all)
11. **Patterns**: `EmployeeId, DayOfWeek, ShiftId, IsRestDay` (IsActive = 1)
12. **Rhythm**: `EmployeeId, AnchorWeekStart, AnchorWorkDays, OnRotation` (the anchor pair may be NULL: no rhythm yet)
13. **Cells**: `EmployeeId, WorkDate, AutoState, AutoShiftId, ReasonCode, IsPinned` (window)
14. **Staffing**: `DayOfWeek, ShiftId, MinOnDuty, TargetOnDuty` (branch, active)
15. **LastRun**: `RunId, MonthDate, Mode, ParamsJson, CreatedAt` (latest for the branch, 0 or 1 row)

Recursive date CTEs: `OPTION (MAXRECURSION 400)`.

**`attendance.usp_AutoRoster_Commit @BranchId INT, @MonthDate DATE, @Mode VARCHAR(20), @ChangesJson NVARCHAR(MAX), @RhythmJson NVARCHAR(MAX) = NULL, @ParamsJson NVARCHAR(MAX) = NULL, @IssueCount INT = 0, @CallerUserId INT = NULL`**

`@ChangesJson` (camelCase): `[{ "employeeId", "workDate", "action": "upsert"|"delete", "shiftId", "isRestDay", "expectedExists", "expectedShiftId", "expectedIsRestDay", "isAuto", "reasonCode", "isPinned" }]`
`@RhythmJson`: `[{ "employeeId", "anchorWeekStart", "anchorWorkDays", "onRotation" }]` — the anchor pair may be left out
(the flag alone is stored). Optional expected state, flat `expectedAnchorWeekStart, expectedAnchorWorkDays, expectedOnRotation`
or nested `expected: {…}`: when given and the stored row differs, the commit is refused as stale (409). The API does not
send it yet. Changing the flag or replacing an existing anchor needs the person's branch today or a future transfer
into a branch the caller manages (`'… belongs to another branch now — …'`, 403).

1. Scope as GetContext. `'Choose a real mode.'` for anything but FillEmpty/ReplanAuto/ReplanAll.
2. Each change: in the month; branch of day = @BranchId (`'… is not in this branch on …'`);
   employed; upsert: rest ⇒ shiftId NULL, work ⇒ active shift (`'Shift … is not active.'`), never
   (NULL, 0); no rest on a holiday (`'A holiday is not a rest day — leave the day empty.'`);
   delete of a row referenced by an attendance record refused.
3. `BEGIN TRAN`; read the current rows `WITH (UPDLOCK, HOLDLOCK)`; any cell whose current state ≠
   expected → `'The roster changed since the preview — preview again.'`; a pinned cell →
   `'This day is pinned — unpin it before re-planning it.'`
4. `#roster_change` = cells that really change (upserts that differ, deletes of existing rows);
   `EXEC @rc = attendance.usp_Roster_AssertEditable`; `@rc <> 0` → ROLLBACK, RETURN 1.
5. UPDATE / INSERT / DELETE `SHIFT_ASSIGNMENT` (changed cells only, so unchanged cells never mark the
   month "changed since approval"); MERGE `ROSTER_CELL` (isAuto → AutoState/AutoShiftId/AutoRunId,
   else NULL; ReasonCode; IsPinned when given); MERGE `ROSTER_RHYTHM`; INSERT `ROSTER_AUTO_RUN`.
6. COMMIT; `SELECT RunId, RowsInserted, RowsUpdated, RowsDeleted`.

**`attendance.usp_RosterCell_SetPin @EmployeeId INT, @WorkDate DATE, @IsPinned BIT, @CallerUserId INT = NULL`** — scope by branch of day;
`'Only a saved day can be pinned.'` when no row; MERGE ROSTER_CELL. Writes no roster row.

**`attendance.usp_RosterCell_GetRange @BranchId INT, @FromDate DATE, @ToDate DATE, @CallerUserId INT = NULL`** —
`EmployeeId, WorkDate, IsPinned, IsAuto, ReasonCode` for days whose branch of day = @BranchId.

**`attendance.usp_StaffingRequirement_GetByBranch @BranchId INT, @CallerUserId INT = NULL`**, **`attendance.usp_StaffingRequirement_Save @BranchId INT, @RowsJson NVARCHAR(MAX), @CallerUserId INT = NULL`** (replaces the branch's rows; `[{ "dayOfWeek", "shiftId", "minOnDuty", "targetOnDuty" }]`).

**`attendance.usp_RosterRhythm_Save @RowsJson NVARCHAR(MAX), @CallerUserId INT = NULL`** (`[{ "employeeId", "onRotation", "anchorWeekStart", "anchorWorkDays" }]`; anchor fields optional).

Nothing existing is altered: `SHIFT_ASSIGNMENT`, its trigger, the guard and the other generators stay as they are.

---

## 4. API — `api/roster/auto` (`AutoRosterController`; caller = `User.UserId()`)

| Verb + route | Permission | Body / query → result |
|---|---|---|
| GET `setup?branchId&month=yyyy-MM` | ATTENDANCE_VIEW | → `AutoRosterSetup` |
| POST `preview` | ATTENDANCE_MANAGE | `AutoRosterRequest` → `AutoRosterPreview` (writes nothing, no notify) |
| POST `commit` | ATTENDANCE_MANAGE | `AutoRosterCommitRequest` → `AutoRosterCommitResult`; error-level issues → 400 `{ error, issues }`; notify `attendance`,`dashboard` on success only |
| GET `cells?branchId&from&to` | ATTENDANCE_VIEW | → `RosterCellInfo[]` |
| PUT `pin` | ATTENDANCE_MANAGE | `{ employeeId, workDate, isPinned }` → 204; notify `attendance` |
| PUT `staffing?branchId` | ATTENDANCE_MANAGE | `StaffingRequirementDto[]` → 204; notify `attendance` |
| PUT `rhythm` | ATTENDANCE_MANAGE | `RosterRhythmDto[]` → 204; notify `attendance` |

JSON is camelCase; dates are `"yyyy-MM-dd"` (`DateOnly`). Enumerations are strings.

```
AutoRosterRequest { branchId, month ("2026-12"), mode ("FillEmpty"|"ReplanAuto"|"ReplanAll"),
  rhythmStart? ("Aligned"|"Staggered"), defaultShiftId?, holidayCover: [{ date, count }],
  offRotationEmployeeIds: [int], rhythmOverrides: [{ employeeId, weekStart, workDays }],
  draftCells: [{ employeeId, workDate, shiftId?, isRestDay, isPinned? }] }

AutoRosterPreview { branchId, monthDate, windowFrom, windowTo,
  cells: [{ employeeId, workDate, state ("work"|"rest"|"none"), shiftId?, origin
            ("planned"|"fact"|"locked"|"pinned"|"leave"|"holiday"|"draft"|"ghost"|"outside"),
            change ("insert"|"update"|"delete"|"unchanged"|"kept"), reasonCode?, reasonArgs?,
            expected: { exists, shiftId?, isRestDay? } }],
  rhythm: [{ employeeId, anchorWeekStart, anchorWorkDays, isNew }],
  perEmployee: [{ employeeId, workDays, restDays, saturdaysOff, sundaysOff, owedSaturday, owedSunday,
                  weeks: [{ weekStart, workDays (6|5), rests, quota, ok }] }],
  perDay: [{ date, onDuty, min?, target?, shifts: [{ shiftId, onDuty, min, target? }] }],
  issues: [{ severity ("error"|"warning"|"info"), code, employeeId?, date?, shiftId? (D16), message }],
  summary: { inserts, updates, deletes, unchanged, kept } }

AutoRosterCommitRequest = AutoRosterRequest + { cells: [{ employeeId, workDate, action ("upsert"|"delete"),
  shiftId?, isRestDay, expected: { exists, shiftId?, isRestDay? }, isAuto, reasonCode?, isPinned? }],
  rhythm: [{ employeeId, anchorWeekStart, anchorWorkDays, onRotation }] }
AutoRosterCommitResult { runId, rowsInserted, rowsUpdated, rowsDeleted }

AutoRosterSetup { branchId, monthDate, settings: {…keys of §3.2 as camelCase…},
  staff: [{ employeeId, fullName, position, onRotation, anchorWeekStart?, anchorWorkDays?, firstWeekWorkDays }],
  staffing: [StaffingRequirementDto], shiftCover: [StaffingRequirementDto] (D16, as the planner reads it),
  shiftCoverDetected (true = found from the roster, nothing stored), holidays: [{ date, name, isPaid }],
  shifts: [{ shiftId, name }] (active, in the order they start), lastParams?: AutoRosterRequest, monthStatus?, openRequestId? }
RosterCellInfo { employeeId, workDate, isPinned, isAuto, reasonCode? }
StaffingRequirementDto { dayOfWeek? (1..7), shiftId?, minOnDuty, targetOnDuty? }
RosterRhythmDto { employeeId, onRotation, anchorWeekStart?, anchorWorkDays? }
```

New refusal sentences mapped in `WorkflowSqlErrors.MapMessage`: 409 for `"The roster changed since"`,
`"This day is pinned"`; 403 for `"You can only plan rosters for the branches you manage"`.

---

## 5. Web (`mokaco-web-mantine`)

- RosterPage toolbar: **Auto-roster (6/5)…** (`variant="default"`), shown with `canManage`, disabled
  (tooltip) on "All branches" or while the month is read-only.
- `AutoRosterDrawer`: month and branch (from the page), mode (FillEmpty / ReplanAuto / ReplanAll with
  confirmation), rhythm start, default shift (active shifts), staff list with *On rotation* and *This
  month's first week: 6 / 5* (flip), holiday cover per holiday, **shifts to cover every day** (tick,
  minimum, target per shift — prefilled with what was found) and minimum/target on duty per weekday
  (both saved per branch). **Preview**.
- Draft overlay in the same `roster-table`: `draft.get(key) ?? lookup.get(key)`; dashed outline for
  planned days, a lock glyph on locked days, holiday shading, a border before every Monday.
- `AutoRosterPreviewCard` (sticky above the grid): summary counts, issues (click → scroll to the day),
  **Save**, **Regenerate** (sends the manager's draft edits as `draftCells`), **Discard**.
- During preview the existing drag-select + Set-day dialog edit the draft (no server call); the dialog
  gains **Keep when regenerating** (pin).
- Counters: per employee Work / Rest / Sat off / Sun off and a 6·5 week strip (red when broken);
  footer row with on duty per day against the minimum, and while a draft is open one row per shift to
  cover (red when short). Pure helpers in `rosterCounters.ts` (`npm test`).
- A working row under leave is the normal state now (shown as leave, no conflict outline).
- i18n: `attendance.roster.auto.*` in `en.json` and `ar.json` (Arabic plurals), issue and reason codes
  translated.

---

## 6. Tests

Pure planner (xUnit, no database): alternation 6/5 from the anchor across Oct→Nov→Dec 2026 in both
generation orders; month starting on a Sunday (Nov 2026) and on a Monday (Jun 2026); February;
fairness (7–8 equal people over 8–12 weeks: Sat spread ≤ 1, Sun spread ≤ 1); history catch-up;
holidays (no row, never rest, cover by fewest holidays worked; a holiday added after a save deletes
rows and moves rest days); leave (working rows, never rest inside, absorbed rest reported, half day);
staffing (minimum met when possible, SHORT_STAFFED otherwise, rest kept); consecutive cap across
weeks and months, pinned-Monday joint weekend case; modes/pins/locks; stability (regenerate = 0
changes); transfer mid-week; hire mid-week; small branches (2, 3, 4 people); determinism under input
shuffling; shift cover (found from the roster or patterns, stored rows win, a morning person covers
the evening on its person's days off without a turnaround, moves shared, targets, holidays, drafts never
moved, the commit reports an emptied shift, regenerate = 0 changes); a seeded property loop (≥ 300
scenarios) where every hard rule holds or is reported — including: no shift short while someone the
run decides sits on a shift that could spare them.
Controller: preview never notifies; commit notifies once on success, never on refusal; error issues
→ 400; MapMessage 409/403. Web: `rosterCounters`, `rosterDraftCells` and `shiftCover` tests (the
shift-cover editor's rows: ticked/unticked, found vs stored, weekday rules kept, validation; the
per-shift footer under draft edits).

## 7. As built — where the code departs from the plan, and what is still open

Departures (kept on purpose):
- A week that cannot fit its 6/5 within the cap first takes one extra rest; the cap is relaxed only
  when that fails too. The extra rest is reported as RHYTHM_OVER.
- Rest slots left over after water-filling go to the days of the week in a rotating order, so
  no weekday always takes the remainder.
- A Saturday or Sunday off is given only to people within one day of the most owed (D9 ledger).
- The cost of dropping below a day's minimum grows with how far below it goes.
- Stability holds by construction: ReplanAuto keeps every saved week that still fits and changes as
  few days as possible in one that does not. ReplanAll plans from scratch (so a changed setting or
  pattern can take effect).

- D16's repair works on the target month's days only, and the turnaround check never reads a ghost
  day: both made a regenerate move people. A shift that changes only because the day before did
  (someone stays on a covered night) follows that day's change.

Open:
- The commit's rhythm staleness check (`expected*` in @RhythmJson) is in the SQL but the API does
  not send it yet.
- `ValidateSubmission` raises WORK_WITHOUT_SHIFT for an unchanged submitted day on a retired shift
  (the SQL accepts it). The web never sends such a day.
