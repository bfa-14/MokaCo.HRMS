/* ============================================================================
   98_qa3_security.sql - QA3 (deep test, 2026-10-19): the branch scope of script 87 for reads of
   ONE record.

   THE HOLE (QA3 SEC-2). Script 87 scoped the LISTS: without EMP_VIEW_ALL a caller sees their own
   rows and the employees of the branches they manage. The reads of one record took only an id, so a
   branch manager could open any employee by number: the profile, the salary components, the leave
   balance and requests, the documents (and download their files), one attendance record.

   THE RULE, unchanged from 87: the caller holds EMP_VIEW_ALL, or the record is their own, or its
   branch is one they manage (hr.BRANCH.ManagerEmployeeId). The branch is the employee's branch
   today for an employee or a document, and the record's own branch for an attendance day (the
   employee's branch of THAT day, as in usp_Attendance_GetByDateRange).

   PROCEDURE
     hr.usp_Scope_CallerSees   @CallerUserId, and ONE of @EmployeeId / @AttendanceId / @DocumentId.
                               One row: Found (the record exists), CanSee, IsSelf (the record is the
                               caller's own). The API runs it before the read ([InCallerScope]).

   Needs script 87 (hr.fn_CallerScope). Re-runnable. Every refusal is RAISERROR(msg,16,1) + RETURN 1.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('hr.fn_CallerScope') IS NULL
    RAISERROR('98_qa3_security.sql needs script 87 (hr.fn_CallerScope). Apply 87 first.', 16, 1);
GO

CREATE OR ALTER PROCEDURE hr.usp_Scope_CallerSees
    @CallerUserId INT,
    @EmployeeId   INT = NULL,
    @AttendanceId BIGINT = NULL,
    @DocumentId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (CASE WHEN @EmployeeId IS NULL THEN 0 ELSE 1 END
      + CASE WHEN @AttendanceId IS NULL THEN 0 ELSE 1 END
      + CASE WHEN @DocumentId IS NULL THEN 0 ELSE 1 END) <> 1
    BEGIN
        RAISERROR('Say which one record: an employee, an attendance day or a document.', 16, 1);
        RETURN 1;
    END;

    DECLARE @Emp INT, @Branch INT, @Found BIT = 0;

    IF @AttendanceId IS NOT NULL
        SELECT @Emp = a.EmployeeId, @Branch = ISNULL(a.BranchId, e.BranchId), @Found = 1
        FROM attendance.ATTENDANCE_RECORD a
        JOIN hr.EMPLOYEE e ON e.EmployeeId = a.EmployeeId
        WHERE a.AttendanceId = @AttendanceId;
    ELSE IF @DocumentId IS NOT NULL
        SELECT @Emp = d.EmployeeId, @Branch = e.BranchId, @Found = 1
        FROM hr.DOCUMENT d
        JOIN hr.EMPLOYEE e ON e.EmployeeId = d.EmployeeId
        WHERE d.DocumentId = @DocumentId;
    ELSE
        SELECT @Emp = e.EmployeeId, @Branch = e.BranchId, @Found = 1
        FROM hr.EMPLOYEE e
        WHERE e.EmployeeId = @EmployeeId;

    DECLARE @SeesAll BIT, @CallerEmp INT;
    SELECT @SeesAll = SeesAll, @CallerEmp = CallerEmployeeId FROM hr.fn_CallerScope(@CallerUserId);

    SELECT Found  = @Found,
           CanSee = CAST(CASE WHEN @Found = 0 THEN 0
                              WHEN @SeesAll = 1 THEN 1
                              WHEN @Emp = @CallerEmp THEN 1
                              WHEN EXISTS (SELECT 1 FROM hr.BRANCH mb
                                           WHERE mb.ManagerEmployeeId = @CallerEmp AND mb.BranchId = @Branch) THEN 1
                              ELSE 0 END AS BIT),
           IsSelf = CAST(CASE WHEN @Found = 1 AND @Emp = @CallerEmp THEN 1 ELSE 0 END AS BIT);
    RETURN 0;
END;
GO

PRINT 'QA3 security: hr.usp_Scope_CallerSees in place';
GO
