/* ============================================================================
   PAYROLL ADJUSTMENT AS A REQUEST  -  the two follow-ups
   MokaCo_HRMS  |  RUN AFTER payroll_adjustment_type.sql
   ----------------------------------------------------------------------------
   payroll_adjustment_type.sql closed the direct-create door and gave the ledger
   row a RequestInstanceId. It did NOT do these two, and both are needed before
   the UI can tell the truth:

   1. usp_Adjustment_GetForPeriod does not return RequestInstanceId, so the
      history grid cannot show WHO AUTHORISED a row. One column.

   2. usp_Adjustment_Delete still allows deleting an UNCONSUMED row. That was
      right when a row was one person's typing; it is wrong now that a row is
      the residue of a signed chain. An adjustment that HR raised and the Owner
      signed must not evaporate because somebody pressed a bin icon before the
      period was generated — the way to undo a signed decision is to reject it,
      or to counter it, never to delete the evidence.

   Neither procedure is otherwise touched: the consumed-row refusal, the
   @@ROWCOUNT contract and the SELECT shape all stay as they were.
   ============================================================================ */
USE MokaCo_HRMS;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* -- 1. the history grid needs to name its authority ----------------------- */
CREATE OR ALTER PROCEDURE payroll.usp_Adjustment_GetForPeriod
    @TargetPeriod CHAR(7)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT adj.PayrollAdjustmentId, adj.EmployeeId, e.FullName AS EmployeeName,
           ct.Name AS ComponentName, ct.[Sign], adj.Amount, adj.CurrencyCode,
           adj.TargetPeriod, adj.CorrectsRunId, r.PeriodYearMonth AS CorrectsPeriod,
           adj.Reason, adj.AppliedToPayslipId, u.Username AS CreatedBy, adj.CreatedAt,
           /* the request that authorised this row - NULL only for rows that predate
              payroll_adjustment_type.sql, when a reason and a creator were the whole story */
           adj.RequestInstanceId
    FROM payroll.PAYROLL_ADJUSTMENT adj
    JOIN hr.EMPLOYEE e ON e.EmployeeId=adj.EmployeeId
    JOIN hr.COMPONENT_TYPE ct ON ct.ComponentTypeId=adj.ComponentTypeId
    LEFT JOIN payroll.PAYROLL_RUN r ON r.PayrollRunId=adj.CorrectsRunId
    LEFT JOIN security.[USER] u ON u.UserId=adj.CreatedByUserId
    WHERE adj.TargetPeriod=@TargetPeriod
    ORDER BY e.FullName;
END;
GO

/* -- 2. a signed row is not deletable ------------------------------------- */
CREATE OR ALTER PROCEDURE payroll.usp_Adjustment_Delete
    @PayrollAdjustmentId INT, @ActedByUserId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Applied INT, @Request INT;
    SELECT @Applied = AppliedToPayslipId, @Request = RequestInstanceId
    FROM payroll.PAYROLL_ADJUSTMENT
    WHERE PayrollAdjustmentId = @PayrollAdjustmentId;

    /* consumed: history, and the counter-adjustment is the only way back */
    IF @Applied IS NOT NULL
    BEGIN RAISERROR('This adjustment was consumed by a locked payslip and is now history. Correct it with a counter-adjustment.',16,1); RETURN; END

    /* authorised: not yet consumed, but signed for - rejecting or countering the
       request is the way back, never deleting what the signatures point at */
    IF @Request IS NOT NULL
    BEGIN RAISERROR('This adjustment was authorised by a signed request - reject-and-re-raise territory, not deletion.',16,1); RETURN; END

    DELETE FROM payroll.PAYROLL_ADJUSTMENT
    WHERE PayrollAdjustmentId=@PayrollAdjustmentId AND AppliedToPayslipId IS NULL;
    SELECT @@ROWCOUNT AS Deleted;
END;
GO

SELECT 'Follow-ups applied: GetForPeriod returns RequestInstanceId; Delete refuses signed rows.' AS Status;
GO
