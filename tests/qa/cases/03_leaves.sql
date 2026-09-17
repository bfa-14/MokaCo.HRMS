/* ============================================================================
   cases/03_leaves.sql — L1 (year opening), ledger/balance checks for L2, L3, L5, L6.
   The request/approval traffic for L2..L7 runs in api-tests.mjs phase1.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @E1 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E1');
DECLARE @E2 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E2');
DECLARE @E5 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E5');
DECLARE @E6 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E6');
DECLARE @E8 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E8');
DECLARE @E9 INT = (SELECT EmployeeId FROM hr.EMPLOYEE WHERE FullName = N'QA E9');
DECLARE @Annual INT = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'Annual');
DECLARE @Sick INT = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'Sick');
DECLARE @Unpaid INT = (SELECT LeaveTypeId FROM hr.LEAVE_TYPE WHERE Name = N'Unpaid');
DECLARE @HrUser INT = (SELECT UserId FROM security.[USER] WHERE Username = N'qa.hr');
DECLARE @exp NVARCHAR(600), @act NVARCHAR(600), @pass BIT, @t NVARCHAR(1000), @n INT, @n2 INT;
DECLARE @tier0 DECIMAL(6,2) = (SELECT AnnualDays FROM hr.LEAVE_ACCRUAL_TIER WHERE LeaveTypeId = @Annual AND MinServiceYears = 0);
DECLARE @tier5 DECIMAL(6,2) = (SELECT AnnualDays FROM hr.LEAVE_ACCRUAL_TIER WHERE LeaveTypeId = @Annual AND MinServiceYears = 5);
EXEC dbo.QA_Note 'L1 rules read from hr.usp_LeaveYear_Open: full tier days when hired before 1 Jan (tier by whole service years at 1 Jan); hired this year -> ROUND(tier x (13 - hire month) / 12 x 2, 0) / 2 i.e. months from the hire month to December, rounded to 0.5; only the current year can be opened; skips employees who already have the year''s "Annual entitlement" accrual row.';

/* ---- L1 ---- */
DECLARE @realBefore INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER l JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId WHERE e.FullName NOT LIKE N'QA %');
DECLARE @open TABLE (LeaveTypeName NVARCHAR(60), EmployeesOpened INT, DaysGranted DECIMAL(9,2), ProratedEmployees INT, DaysCarriedOver DECIMAL(9,2), DaysExpired DECIMAL(9,2));
INSERT INTO @open EXEC hr.usp_LeaveYear_Open @Year = 2026, @ActedByUserId = @HrUser;
SET @t = (SELECT 'usp_LeaveYear_Open 2026 re-run in this file (the first run is part of seed.sql): ' + ISNULL(STRING_AGG(CONCAT(LeaveTypeName, ': opened=', EmployeesOpened, ' days=', DaysGranted, ' prorated=', ProratedEmployees), '; '), 'no rows') FROM @open);
EXEC dbo.QA_Note @t;
DECLARE @realAfter INT = (SELECT COUNT(*) FROM hr.LEAVE_LEDGER l JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId WHERE e.FullName NOT LIKE N'QA %');
SET @exp = CAST(@realBefore AS NVARCHAR(10)); SET @act = CAST(@realAfter AS NVARCHAR(10)); SET @pass = CASE WHEN @realBefore = @realAfter THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1-real', 'opening the year adds nothing for real employees (they already have their 2026 accrual)', @exp, @act, @pass;

DECLARE @g DECIMAL(6,2), @e DECIMAL(6,2);
SET @g = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E1 AND LeaveTypeId = @Annual AND MovementType = 'Accrual' AND PeriodYearMonth = '2026-01');
SET @exp = CAST(@tier5 AS NVARCHAR(10)); SET @act = ISNULL(CAST(@g AS NVARCHAR(10)), 'none'); SET @pass = CASE WHEN @g = @tier5 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1a', 'E1 (hired 2020-01-01, 6 years of service) gets the full 5+ years tier', @exp, @act, @pass;
SET @g = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E8 AND LeaveTypeId = @Annual AND MovementType = 'Accrual' AND PeriodYearMonth = '2026-01');
SET @e = ROUND(@tier0 * (13 - 7) / 12.0 * 2, 0) / 2;
SET @exp = CAST(@e AS NVARCHAR(10)); SET @act = ISNULL(CAST(@g AS NVARCHAR(10)), 'none'); SET @pass = CASE WHEN @g = @e THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1b', 'E8 hired 10 July this year gets the prorated amount rounded to 0.5 (15 x 6/12 = 7.5)', @exp, @act, @pass;
SET @g = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E2 AND LeaveTypeId = @Annual AND MovementType = 'Accrual' AND PeriodYearMonth = '2026-01');
SET @e = ROUND(@tier0 * (13 - 8) / 12.0 * 2, 0) / 2;
SET @exp = CAST(@e AS NVARCHAR(10)); SET @act = ISNULL(CAST(@g AS NVARCHAR(10)), 'none'); SET @pass = CASE WHEN @g = @e THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1c', 'E2 hired 15 August this year: 15 x 5/12 = 6.25 -> rounded to 0.5 = 6.5', @exp, @act, @pass;
SET @g = (SELECT SUM(Days) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E9 AND LeaveTypeId = @Annual AND MovementType = 'Accrual' AND PeriodYearMonth = '2026-01');
SET @exp = CAST(@tier5 AS NVARCHAR(10)); SET @act = ISNULL(CAST(@g AS NVARCHAR(10)), 'none'); SET @pass = CASE WHEN @g = @tier5 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1d', 'E9 (hired 2020-06-01, 5 full years at 1 Jan 2026) gets the 5+ years tier', @exp, @act, @pass;
/* run twice */
SELECT @n = COUNT(*) FROM hr.LEAVE_LEDGER l JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId WHERE e.FullName LIKE N'QA %' AND l.MovementType = 'Accrual';
DELETE FROM @open;
INSERT INTO @open EXEC hr.usp_LeaveYear_Open @Year = 2026, @ActedByUserId = @HrUser;
SELECT @n2 = COUNT(*) FROM hr.LEAVE_LEDGER l JOIN hr.EMPLOYEE e ON e.EmployeeId = l.EmployeeId WHERE e.FullName LIKE N'QA %' AND l.MovementType = 'Accrual';
SET @exp = CONCAT('accrual rows stay ', @n); SET @act = CAST(@n2 AS NVARCHAR(10)); SET @pass = CASE WHEN @n = @n2 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L1e', 'running usp_LeaveYear_Open twice does not double the opening', @exp, @act, @pass;

/* ---- L2: ledger and balance view for E5's approved 3-day annual leave ---- */
DECLARE @rl2 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'req.l2') AS INT);
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(MovementType, ' ', Days, ' (', PeriodYearMonth, ', eff ', CONVERT(VARCHAR(10), EffectiveDate, 23), ')'), '; '), 'no rows')
            FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rl2);
SELECT @n = COUNT(*) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rl2 AND l.MovementType = 'Usage' AND l.Days = -3;
SET @pass = CASE WHEN @n = 1 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L2f', 'approved annual 3 days -> exactly one ledger Usage -3 row for that request', 'Usage -3 (2026-08)', @act, @pass;
DECLARE @rem DECIMAL(9,2) = (SELECT SUM(Remaining) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E5 AND LeaveTypeId = @Annual);
DECLARE @used DECIMAL(9,2) = (SELECT SUM(Used) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E5 AND LeaveTypeId = @Annual);
DECLARE @acc DECIMAL(9,2) = (SELECT SUM(Accrued) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E5 AND LeaveTypeId = @Annual);
SET @act = CONCAT('accrued=', @acc, ' used=', @used, ' remaining=', @rem); SET @pass = CASE WHEN @acc = 15 AND @used = 3 AND @rem = 12 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L2g', 'hr.vw_LEAVE_BALANCE for E5 annual: accrued 15, used 3, remaining 12', 'accrued=15.00 used=3.00 remaining=12.00', @act, @pass;
DECLARE @bal TABLE (LeaveTypeName NVARCHAR(60), IsPaid BIT, AnnualEntitlementDays DECIMAL(5,1), CurrentBalance DECIMAL(9,2), TotalUsed DECIMAL(9,2));
INSERT INTO @bal EXEC hr.usp_Leave_GetBalance @EmployeeId = @E5, @LeaveTypeId = @Annual;
SET @act = NULL; SET @pass = 0;
SELECT @act = CONCAT('entitlement=', AnnualEntitlementDays, ' balance=', CurrentBalance, ' used=', TotalUsed), @pass = CASE WHEN CurrentBalance = 12 AND TotalUsed = 3 THEN 1 ELSE 0 END FROM @bal;
SET @act = ISNULL(@act, 'no row');
EXEC dbo.QA_Check 'L2h', 'usp_Leave_GetBalance (employee page) agrees: balance 12, used 3', 'balance=12.00 used=3.00', @act, @pass;
DECLARE @rlc INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'req.lcancel') AS INT);
SELECT @n = COUNT(*) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rlc;
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L2i', 'a cancelled (never approved) leave request has no ledger rows; balance untouched', '0 rows', @act, @pass;

/* ---- L3: discretionary -> Usage -3 AND Adjustment +3 ---- */
DECLARE @rl3 INT = TRY_CAST((SELECT [Value] FROM dbo.QA_STATE WHERE [Key] = 'req.l3') AS INT);
SET @act = (SELECT ISNULL(STRING_AGG(CONCAT(MovementType, ' ', Days), '; ') WITHIN GROUP (ORDER BY LeaveLedgerId), 'no rows')
            FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rl3);
SELECT @n = COUNT(*) FROM hr.LEAVE_LEDGER l JOIN workflow.LEAVE_REQUEST lr ON lr.LeaveRequestId = l.LeaveRequestId WHERE lr.RequestInstanceId = @rl3 AND ((MovementType = 'Usage' AND Days = -3) OR (MovementType = 'Adjustment' AND Days = 3));
SET @rem = (SELECT SUM(Remaining) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E1 AND LeaveTypeId = @Annual);
SET @act = CONCAT(@act, '; remaining=', @rem); SET @pass = CASE WHEN @n = 2 AND @rem = 21 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L3c', 'E1 discretionary 3 days: ledger has Usage -3 and Adjustment +3; remaining stays at the 21-day entitlement', 'Usage -3.00; Adjustment 3.00; remaining=21.00', @act, @pass;

/* ---- L5: sick leave ledger ---- */
SET @t = (SELECT 'L5 ledger for E5 sick: ' + ISNULL(STRING_AGG(CONCAT(MovementType, ' ', Days), '; '), 'no rows') + ' (Sick has no LEAVE_ACCRUAL_TIER row, so its balance is purely negative usage; pay tiers decide the money).' FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E5 AND LeaveTypeId = @Sick);
EXEC dbo.QA_Note @t;

/* ---- L6: unpaid leave counted on the Unpaid type, annual balance untouched ---- */
SELECT @n = COUNT(*) FROM hr.LEAVE_LEDGER WHERE EmployeeId = @E6 AND LeaveTypeId = @Unpaid AND MovementType = 'Usage' AND Days = -2;
SET @rem = (SELECT SUM(Remaining) FROM hr.vw_LEAVE_BALANCE WHERE EmployeeId = @E6 AND LeaveTypeId = @Annual);
SET @act = CONCAT('unpaid usage rows=', @n, ', annual remaining=', @rem); SET @pass = CASE WHEN @n = 1 AND @rem = 15 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L6b', 'E6 unpaid leave: Usage -2 on the Unpaid type; annual balance still 15', 'unpaid usage rows=1, annual remaining=15.00', @act, @pass;

/* ---- one Usage per approved request; discretionary requests carry exactly one give-back ---- */
SELECT @n = COUNT(*) FROM workflow.LEAVE_REQUEST lr JOIN workflow.REQUEST_INSTANCE ri ON ri.RequestInstanceId = lr.RequestInstanceId
JOIN hr.EMPLOYEE e ON e.EmployeeId = lr.EmployeeId
WHERE e.FullName LIKE N'QA %' AND ri.[Status] = 'Approved'
  AND ((SELECT COUNT(*) FROM hr.LEAVE_LEDGER l WHERE l.LeaveRequestId = lr.LeaveRequestId AND l.MovementType = 'Usage') <> 1
    OR (SELECT COUNT(*) FROM hr.LEAVE_LEDGER l WHERE l.LeaveRequestId = lr.LeaveRequestId AND l.MovementType = 'Adjustment') <> CAST(lr.IsDiscretionary AS INT));
SET @act = CAST(@n AS NVARCHAR(10)); SET @pass = CASE WHEN @n = 0 THEN 1 ELSE 0 END;
EXEC dbo.QA_Check 'L-ledger', 'every approved QA leave request has exactly one Usage row (and one Adjustment only when discretionary)', '0 requests off', @act, @pass;
GO
