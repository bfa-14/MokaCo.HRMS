/* ============================================================================
   deploy/check-scripts.sql - which numbered scripts of docs/ this database has. READ-ONLY: it changes
   nothing, so it is safe on production.

   Run it against the database to check, e.g. on the VM:
     sqlcmd -S 127.0.0.1 -U sa -C -d MokaCo_HRMS      -i deploy/check-scripts.sql     (production)
     sqlcmd -S 127.0.0.1 -U sa -C -d MokaCo_HRMS_Test -i deploy/check-scripts.sql     (test)

   Each script is recognised by something only it creates, or, for a script that only rewrites existing
   procedures, by words its version puts in them and later scripts keep. The last lines list what is
   missing, in apply order. Admin tools (91, 92, 94, 95) are reported but never needed by the API.
   A marker must be something the script INTRODUCES: production carries objects the repo never defined. 99 was first
   checked by hr.usp_LeaveYear_Undo, which production already had, so 99 read as applied there when it never ran (21 Oct).
   Written after the QA3 roll-out on test, which found the test copy without 74, 79, 80, 88-90, 93, 96, 97.
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @S TABLE (No INT PRIMARY KEY, Script NVARCHAR(60), Applied BIT, Admin BIT DEFAULT 0, CheckedBy NVARCHAR(200));
DECLARE @def NVARCHAR(MAX);

INSERT INTO @S (No, Script, Applied, CheckedBy) VALUES
 (51, N'51_email_notifications.sql',              IIF(OBJECT_ID('core.usp_Email_QueueClosedRequests') IS NOT NULL, 1, 0), N'core.usp_Email_QueueClosedRequests'),
 (70, N'70_ref_data_delete_rules.sql',            IIF(OBJECT_ID('hr.usp_Branch_Delete') IS NOT NULL, 1, 0), N'hr.usp_Branch_Delete'),
 (71, N'71_employee_contact_required.sql',        IIF(CHARINDEX(N'Phone number and e-mail are required', ISNULL(OBJECT_DEFINITION(OBJECT_ID('hr.usp_Employee_Create')), N'')) > 0, 1, 0), N'usp_Employee_Create requires phone and e-mail'),
 (72, N'72_roster_submit_guard_and_clear.sql',    IIF(COL_LENGTH('attendance.ROSTER_MONTH', 'LastChangedUtc') IS NOT NULL, 1, 0), N'ROSTER_MONTH.LastChangedUtc'),
 (73, N'73_leave_balance_and_users.sql',          IIF(OBJECT_ID('security.usp_User_SetRoles') IS NOT NULL, 1, 0), N'security.usp_User_SetRoles'),
 (74, N'74_booking_refund_check.sql',             IIF(EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_PAY_Amount' AND definition LIKE N'%IsRefund%'), 1, 0), N'CK_PAY_Amount allows refunds'),
 (75, N'75_roster_approval_applies_and_locks.sql', IIF(CHARINDEX(N'ROSTER_APPROVAL', ISNULL(OBJECT_DEFINITION(OBJECT_ID('workflow.usp_Request_ApplyApprovalEffects')), N'')) > 0, 1, 0), N'approval effects apply rosters'),
 (76, N'76_attendance_single_day_rule.sql',       IIF(OBJECT_ID('attendance.usp_Attendance_ReprocessDay') IS NOT NULL, 1, 0), N'attendance.usp_Attendance_ReprocessDay'),
 (77, N'77_attendance_tolerance_anomalies.sql',   IIF(OBJECT_ID('attendance.ATTENDANCE_ANOMALY') IS NOT NULL, 1, 0), N'attendance.ATTENDANCE_ANOMALY'),
 (78, N'78_payroll_rest_days_rate_precision.sql', IIF(OBJECT_ID('payroll.fn_ToPrimary') IS NOT NULL, 1, 0), N'payroll.fn_ToPrimary'),
 (79, N'79_booking_guest_cancel_phone.sql',       IIF(OBJECT_ID('booking.fn_PhoneDigits') IS NOT NULL, 1, 0), N'booking.fn_PhoneDigits'),
 (80, N'80_booking_expire_holds_refs.sql',        IIF(CHARINDEX(N'inserted.BookingRef', ISNULL(OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_ExpireHolds')), N'')) > 0, 1, 0), N'expired holds return their references'),
 (81, N'81_payroll_run_timing.sql',               IIF(CHARINDEX(N'An open supplemental for this period already exists', ISNULL(OBJECT_DEFINITION(OBJECT_ID('payroll.usp_PayrollRun_Create')), N'')) > 0, 1, 0), N'one open supplemental per period'),
 (82, N'82_qa2_foundation.sql',                   IIF(OBJECT_ID('core.usp_Holiday_GetAll') IS NOT NULL AND OBJECT_ID('payroll.fn_IsPeriodPaid') IS NOT NULL, 1, 0), N'core.usp_Holiday_GetAll, payroll.fn_IsPeriodPaid'),
 (83, N'83_qa2_attendance.sql',                   IIF(OBJECT_ID('attendance.usp_DevicePunchQuarantine_GetAll') IS NOT NULL, 1, 0), N'attendance.usp_DevicePunchQuarantine_GetAll'),
 (84, N'84_qa2_leaves.sql',                       IIF(OBJECT_ID('attendance.usp_Attendance_RecomputeLeaveRange') IS NOT NULL, 1, 0), N'attendance.usp_Attendance_RecomputeLeaveRange'),
 (85, N'85_qa2_rosters.sql',                      IIF(CHARINDEX(N'fn_EmployeeBranchOn(c.EmployeeId, c.WorkDate) = rm.BranchId', ISNULL(OBJECT_DEFINITION(OBJECT_ID('attendance.trg_ShiftAssignment_Modified')), N'')) > 0, 1, 0), N'roster changes follow the branch of the day'),
 (86, N'86_qa2_payroll.sql',                      IIF(COL_LENGTH('attendance.ATTENDANCE_RECORD', 'ExitUnpaidDays') IS NOT NULL, 1, 0), N'ATTENDANCE_RECORD.ExitUnpaidDays'),
 (87, N'87_branch_scoping_role_hygiene.sql',      IIF(OBJECT_ID('hr.fn_CallerScope') IS NOT NULL, 1, 0), N'hr.fn_CallerScope'),
 (88, N'88_booking_online_deposit.sql',           IIF(OBJECT_ID('booking.usp_Booking_SetPaymentSession') IS NOT NULL AND COL_LENGTH('core.EMAIL_OUTBOX', 'SmtpAccount') IS NOT NULL, 1, 0), N'booking.usp_Booking_SetPaymentSession, EMAIL_OUTBOX.SmtpAccount'),
 (89, N'89_booking_midnight_start.sql',           IIF(CHARINDEX(N'@PrevDow', ISNULL(OBJECT_DEFINITION(OBJECT_ID('booking.usp_Booking_Validate')), N'')) > 0, 1, 0), N'usp_Booking_Validate checks the previous night'),
 (90, N'90_currency_delete_unused.sql',           IIF(OBJECT_ID('core.usp_Currency_Delete') IS NOT NULL, 1, 0), N'core.usp_Currency_Delete'),
 (93, N'93_identity_cache_off.sql',               IIF(EXISTS (SELECT 1 FROM sys.database_scoped_configurations WHERE name = 'IDENTITY_CACHE' AND TRY_CONVERT(INT, value) = 0), 1, 0), N'IDENTITY_CACHE = OFF'),
 (96, N'96_auto_roster.sql',                      IIF(OBJECT_ID('attendance.usp_AutoRoster_Commit') IS NOT NULL AND OBJECT_ID('attendance.usp_RosterRhythm_Save') IS NOT NULL, 1, 0), N'attendance.usp_AutoRoster_Commit'),
 (97, N'97_google_signin_gate.sql',               IIF(OBJECT_ID('security.usp_Gate_SignOutEveryone') IS NOT NULL, 1, 0), N'security.usp_Gate_SignOutEveryone'),
 (98, N'98_qa3_security.sql',                     IIF(OBJECT_ID('hr.usp_Scope_CallerSees') IS NOT NULL, 1, 0), N'hr.usp_Scope_CallerSees'),
 (99, N'99_qa3_leave.sql',                        IIF(COL_LENGTH('workflow.LEAVE_REQUEST', 'ApprovedToDate') IS NOT NULL AND OBJECT_ID('hr.usp_LeaveLedger_Reprice') IS NOT NULL
                                                     AND CHARINDEX(N'the stale copy still read it', ISNULL(OBJECT_DEFINITION(OBJECT_ID('report.usp_Report_LeaveBalance')), N'')) > 0, 1, 0),
                                                 N'LEAVE_REQUEST.ApprovedToDate, hr.usp_LeaveLedger_Reprice, and its usp_Report_LeaveBalance'),
 (100, N'100_qa3_attendance.sql',                 IIF(OBJECT_ID('attendance.usp_DevicePunchQuarantine_Dismiss') IS NOT NULL, 1, 0), N'attendance.usp_DevicePunchQuarantine_Dismiss'),
 (101, N'101_qa3_workflow.sql',                   IIF(OBJECT_ID('workflow.usp_Request_GetDelegateCandidates') IS NOT NULL, 1, 0), N'workflow.usp_Request_GetDelegateCandidates'),
 (102, N'102_qa3_roster.sql',                     IIF(OBJECT_ID('attendance.usp_Roster_GetLeaveDays') IS NOT NULL, 1, 0), N'attendance.usp_Roster_GetLeaveDays'),
 (103, N'103_qa3_payroll.sql',                    IIF(OBJECT_ID('core.usp_ExchangeRate_SetRate') IS NOT NULL, 1, 0), N'core.usp_ExchangeRate_SetRate'),
 (104, N'104_qa3_booking.sql',                    IIF(OBJECT_ID('core.usp_Email_GetBookingSenders') IS NOT NULL, 1, 0), N'core.usp_Email_GetBookingSenders'),
 (105, N'105_qa3_security.sql',                   IIF(OBJECT_ID('hr.usp_Scope_CallerEmployees') IS NOT NULL, 1, 0), N'hr.usp_Scope_CallerEmployees'),
 (106, N'106_qa3_webhr.sql',                      IIF(OBJECT_ID('hr.usp_Employee_GetSwapCounterparts') IS NOT NULL, 1, 0), N'hr.usp_Employee_GetSwapCounterparts'),
 (107, N'107_qa3_tier_chains.sql',                IIF(OBJECT_ID('workflow.usp_TierChains_Align') IS NOT NULL, 1, 0), N'workflow.usp_TierChains_Align');

INSERT INTO @S (No, Script, Applied, Admin, CheckedBy) VALUES
 (91, N'91_admin_reseed_identities.sql',          IIF(OBJECT_ID('dbo.usp_Admin_ReseedIdentities') IS NOT NULL, 1, 0), 1, N'admin tool'),
 (92, N'92_admin_prune_workflow_versions.sql',    IIF(OBJECT_ID('dbo.usp_Admin_PruneWorkflowVersions') IS NOT NULL, 1, 0), 1, N'admin tool'),
 (94, N'94_admin_renumber_users.sql',             IIF(OBJECT_ID('dbo.usp_Admin_RenumberUsers') IS NOT NULL, 1, 0), 1, N'admin tool'),
 (95, N'95_admin_renumber_ids.sql',               IIF(OBJECT_ID('dbo.usp_Admin_RenumberIds') IS NOT NULL, 1, 0), 1, N'admin tool');

SELECT CONCAT(LEFT(CONCAT(Script, REPLICATE(N' ', 44)), 44),
              CASE WHEN Applied = 1 THEN N'yes      ' WHEN Admin = 1 THEN N'no (admin tool, optional)' ELSE N'MISSING  ' END,
              CASE WHEN Applied = 0 AND Admin = 0 THEN CONCAT(N'  (checked by ', CheckedBy, N')') ELSE N'' END) AS [Script                                      applied]
FROM @S ORDER BY No;

DECLARE @Missing NVARCHAR(MAX) = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), Script), N' ') WITHIN GROUP (ORDER BY No) FROM @S WHERE Applied = 0 AND Admin = 0);
PRINT CONCAT(N'Database: ', DB_NAME(), N'. Booking tables of the base: ',
             IIF(OBJECT_ID('booking.BOOKING') IS NOT NULL AND COL_LENGTH('booking.BOOKING_BLOCK', 'EndMin') IS NOT NULL, N'present', N'MISSING (the booking scripts cannot apply)'));
PRINT CONCAT(N'Missing, in apply order: ', ISNULL(@Missing, N'none'));
