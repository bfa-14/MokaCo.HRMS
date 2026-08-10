/* ============================================================================
   REVERSAL — corrections to the applied workflow_reversal.sql, plus the reads
   the UI needs.

   The reversal feature (RETRACT / REOPEN, workflow.REQUEST_REVERSAL,
   WORKFLOW_SIGNATURE.RetractedAt/RetractedReason, fn_ReversalBlockReason,
   usp_Reversal_UndoEffects) was already deployed. This script does NOT recreate
   any of that. It fixes four defects found by reading the deployed definitions
   against the live schema, and adds the two reads the request page needs.

   Every refusal message is preserved VERBATIM. They are what the UI shows, and
   they are the whole value of the refusal.

   1. usp_Request_Reopen matched the role literal N'GeneralManager', but the
      role is named 'General Manager' WITH A SPACE (security.ROLE.RoleId 12).
      Proven live: fn_UserHasRole(17,'GeneralManager') = 0,
                   fn_UserHasRole(17,'General Manager') = 1.
      So the GM could never pass the gate, and because only the Owner could,
      the two-signature flow deadlocked on its own "This role already signed"
      guard. Both spellings are now accepted — the same fix, and the same
      reason, as docs/dashboard_managerial_role_fix.sql.

   2. Neither reversal UNSIGNED the step it struck. They set the REQUEST_INSTANCE
      back to Pending but left REQUEST_STEP_INSTANCE holding Status='Approved'
      with its signer, timestamp and comment — so the chain went on rendering the
      struck decision as though it still stood, and the step marker stayed a
      tick. The step is now returned to Pending exactly as
      usp_Request_WithdrawDecision does it (same column list), which is what
      makes the popup's promise true: the signature is struck and the request
      returns to that step.

   3. usp_Request_RetractLastDecision took TOP 1 of WORKFLOW_SIGNATURE without
      excluding the 'Submitted' row, whose StepNo is NULL (all 35 live rows).
      On a request with no decisions yet, the raiser's own submission was the
      "last decision": retracting it set CurrentStepNo = NULL while Status =
      'Pending', a request in flight with no step to act on. Only real decisions
      (StepNo IS NOT NULL) are candidates now.

   4. Both cleared ClosedReason but not ClosedAt, leaving a reopened request
      showing a closing timestamp while open.

   5. usp_Reversal_UndoEffects DELETED the ledger row while the request row still POINTED AT IT,
      so every retract or reopen of a payroll adjustment or a salary advance died on
      FK__PAYROLL_A__Creat__0C26B6F1 / FK__SALARY_AD__Creat__2215F810:

        "The DELETE statement conflicted with the REFERENCE constraint ... table
         workflow.PAYROLL_ADJUSTMENT_REQUEST, column 'CreatedAdjustmentId'."

      It cleared the pointer on the line AFTER the delete. Reversal was therefore broken outright
      for the two money types the consumption guard exists to protect — proven by running a retract
      against request 35 inside a rolled-back transaction. The pointer is now cleared FIRST and the
      row deleted second.

   Then two reads:
   - usp_Request_GetById's history gains RetractedAt/RetractedReason, so a
     struck signature can be rendered struck rather than silently vanishing.
   - a FOURTH result set of reversal events, so a retract/reopen appears as its
     own line in the history, and so the page can show "awaiting the other of
     GM/Owner" from the reopen that is half-signed.

   Deploy:  sqlcmd -S localhost -d MokaCo_HRMS -E -C -I -i workflow_reversal_fixes.sql
   The -I matters: see the QUOTED_IDENTIFIER note in the project README.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------------
   UNDO THE EFFECTS — clear the pointer, THEN delete the row.

   Order is the whole fix. Both request tables hold a FK to the ledger row they
   created, so deleting the row while the pointer still references it is refused
   by the constraint and the entire reversal fails with a raw SQL error.

   Only rows that are still UNTOUCHED are removed — an adjustment no payslip has
   consumed, an advance whose recovery has not started. Anything further along is
   caught earlier by fn_ReversalBlockReason, which refuses the reversal outright
   and names the way out, so this procedure never sees it.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE workflow.usp_Reversal_UndoEffects
    @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- payroll adjustment ---- */
    DECLARE @AdjIds TABLE (Id INT PRIMARY KEY);
    INSERT INTO @AdjIds (Id)
    SELECT a.PayrollAdjustmentId
    FROM workflow.PAYROLL_ADJUSTMENT_REQUEST q
    JOIN payroll.PAYROLL_ADJUSTMENT a ON a.PayrollAdjustmentId = q.CreatedAdjustmentId
    WHERE q.RequestInstanceId = @RequestInstanceId
      AND a.AppliedToPayslipId IS NULL;

    UPDATE workflow.PAYROLL_ADJUSTMENT_REQUEST
        SET CreatedAdjustmentId = NULL, AdjustmentCreatedAt = NULL
        WHERE RequestInstanceId = @RequestInstanceId
          AND CreatedAdjustmentId IN (SELECT Id FROM @AdjIds);

    DELETE a FROM payroll.PAYROLL_ADJUSTMENT a
    WHERE a.PayrollAdjustmentId IN (SELECT Id FROM @AdjIds);

    /* ---- salary advance ---- */
    DECLARE @AdvIds TABLE (Id INT PRIMARY KEY);
    INSERT INTO @AdvIds (Id)
    SELECT a.SalaryAdvanceId
    FROM workflow.SALARY_ADVANCE_REQUEST q
    JOIN payroll.SALARY_ADVANCE a ON a.SalaryAdvanceId = q.CreatedAdvanceId
    WHERE q.RequestInstanceId = @RequestInstanceId
      AND a.RemainingAmount = a.Amount AND a.IsSettled = 0;

    UPDATE workflow.SALARY_ADVANCE_REQUEST
        SET CreatedAdvanceId = NULL, AdvanceCreatedAt = NULL
        WHERE RequestInstanceId = @RequestInstanceId
          AND CreatedAdvanceId IN (SELECT Id FROM @AdvIds);

    DELETE a FROM payroll.SALARY_ADVANCE a
    WHERE a.SalaryAdvanceId IN (SELECT Id FROM @AdvIds);
END;
GO

/* ---------------------------------------------------------------------------
   RETRACT — the last signer, same UTC day, their own signature.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE workflow.usp_Request_RetractLastDecision
    @RequestInstanceId INT, @ActedByUserId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
    BEGIN RAISERROR('A reason is required to retract a decision.',16,1); RETURN; END

    DECLARE @SigId INT,@SigUser INT,@SigAt DATETIME2,@StepNo INT;
    /* StepNo IS NOT NULL excludes the 'Submitted' row. A submission is not a
       decision, and treating it as one left the request Pending with no step. */
    SELECT TOP 1 @SigId=SignatureId,@SigUser=ActedByUserId,
                 @SigAt=ActedAt,@StepNo=StepNo
    FROM workflow.WORKFLOW_SIGNATURE
    WHERE RequestInstanceId=@RequestInstanceId AND RetractedAt IS NULL
      AND StepNo IS NOT NULL AND [Action] IN ('Approved','Rejected')
    ORDER BY ActedAt DESC, SignatureId DESC;
    IF @SigId IS NULL BEGIN RAISERROR('There is no decision to retract.',16,1); RETURN; END
    IF @SigUser<>@ActedByUserId
    BEGIN RAISERROR('Only the person who signed the LAST decision may retract it, and only same-day. Later than that, reopening needs the GM and the Owner together.',16,1); RETURN; END
    IF CAST(@SigAt AS DATE)<>CAST(SYSUTCDATETIME() AS DATE)
    BEGIN RAISERROR('Same-day only: this decision is from an earlier day. Reopening now needs the GM and the Owner together.',16,1); RETURN; END

    DECLARE @Block NVARCHAR(300)=workflow.fn_ReversalBlockReason(@RequestInstanceId);
    IF @Block IS NOT NULL BEGIN RAISERROR(@Block,16,1); RETURN; END

    BEGIN TRAN;
    EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(), RetractedReason=@Reason
        WHERE SignatureId=@SigId;

    /* Unsign the step, exactly as usp_Request_WithdrawDecision does. Without
       this the chain keeps showing the struck decision as the standing one. */
    UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status]='Pending', Decision=NULL,
            ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
            SignedWithPassword=0,
            HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@StepNo;

    UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Pending', CurrentStepNo=@StepNo,
            ClosedAt=NULL, ClosedReason=NULL
        WHERE RequestInstanceId=@RequestInstanceId;
    INSERT INTO workflow.REQUEST_REVERSAL
        (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole,CompletedAt)
    VALUES (@RequestInstanceId,'Retract',@Reason,@ActedByUserId,N'Self',SYSUTCDATETIME());
    COMMIT TRAN;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@StepNo AS CurrentStepNo;
END;
GO

/* ---------------------------------------------------------------------------
   REOPEN — GM + Owner, two signatures, order-free.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE workflow.usp_Request_Reopen
    @RequestInstanceId INT, @ActedByUserId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* BOTH spellings. The seeded role is 'General Manager' with a space; the
       original literal had none, so the GM silently failed this gate. */
    DECLARE @IsGm BIT=CASE WHEN payroll.fn_UserHasRole(@ActedByUserId,N'GeneralManager')=1
                             OR payroll.fn_UserHasRole(@ActedByUserId,N'General Manager')=1
                           THEN 1 ELSE 0 END;
    DECLARE @IsOwner BIT=payroll.fn_UserHasRole(@ActedByUserId,N'Owner');
    IF @IsGm=0 AND @IsOwner=0
    BEGIN RAISERROR('Reopening a closed request needs the General Manager and the Owner.',16,1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM workflow.REQUEST_INSTANCE
                   WHERE RequestInstanceId=@RequestInstanceId AND [Status] IN ('Approved','Rejected'))
    BEGIN RAISERROR('Only a closed (approved or rejected) request can be reopened.',16,1); RETURN; END
    DECLARE @Block NVARCHAR(300)=workflow.fn_ReversalBlockReason(@RequestInstanceId);
    IF @Block IS NOT NULL BEGIN RAISERROR(@Block,16,1); RETURN; END

    DECLARE @Role NVARCHAR(30)=IIF(@IsOwner=1,N'Owner',N'GeneralManager');
    DECLARE @Open INT=(SELECT TOP 1 ReversalId FROM workflow.REQUEST_REVERSAL
        WHERE RequestInstanceId=@RequestInstanceId AND Kind='Reopen' AND CompletedAt IS NULL
        ORDER BY ReversalId DESC);

    IF @Open IS NULL
    BEGIN
        IF @Reason IS NULL OR LTRIM(RTRIM(@Reason))=''
        BEGIN RAISERROR('A reason is required to reopen.',16,1); RETURN; END
        INSERT INTO workflow.REQUEST_REVERSAL
            (RequestInstanceId,Kind,Reason,FirstSignUserId,FirstSignRole)
        VALUES (@RequestInstanceId,'Reopen',@Reason,@ActedByUserId,@Role);
        SELECT 'AwaitingSecond' AS [State], @Role AS FirstSignRole;
        RETURN;
    END
    IF EXISTS (SELECT 1 FROM workflow.REQUEST_REVERSAL
               WHERE ReversalId=@Open AND FirstSignRole=@Role)
    BEGIN RAISERROR('This role already signed the reopen - the OTHER of GM/Owner must sign.',16,1); RETURN; END

    DECLARE @LastStep INT=(SELECT MAX(s.StepNo) FROM workflow.WORKFLOW_SIGNATURE s
        WHERE s.RequestInstanceId=@RequestInstanceId AND s.RetractedAt IS NULL
          AND s.StepNo IS NOT NULL AND s.[Action] IN ('Approved','Rejected'));
    IF @LastStep IS NULL
    BEGIN RAISERROR('There is no decision to reverse on this request.',16,1); RETURN; END

    BEGIN TRAN;
    EXEC workflow.usp_Reversal_UndoEffects @RequestInstanceId;
    UPDATE workflow.WORKFLOW_SIGNATURE
        SET RetractedAt=SYSUTCDATETIME(),
            RetractedReason=N'Reopened by GM + Owner'
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep AND RetractedAt IS NULL;

    /* Unsign the step the struck signature belonged to — see the retract note. */
    UPDATE workflow.REQUEST_STEP_INSTANCE
        SET [Status]='Pending', Decision=NULL,
            ActedByUserId=NULL, ActedAt=NULL, Comment=NULL, ValueBefore=NULL,
            SignedWithPassword=0,
            HoldReason=NULL, HoldSetAt=NULL, HoldSetByUserId=NULL, WaitingOnRequester=0
        WHERE RequestInstanceId=@RequestInstanceId AND StepNo=@LastStep;

    UPDATE workflow.REQUEST_REVERSAL
        SET SecondSignUserId=@ActedByUserId, SecondSignRole=@Role, CompletedAt=SYSUTCDATETIME()
        WHERE ReversalId=@Open;
    UPDATE workflow.REQUEST_INSTANCE
        SET [Status]='Pending', CurrentStepNo=@LastStep,
            ClosedAt=NULL, ClosedReason=NULL
        WHERE RequestInstanceId=@RequestInstanceId;
    COMMIT TRAN;
    SELECT @RequestInstanceId AS RequestInstanceId,'Pending' AS [Status],@LastStep AS CurrentStepNo;
END;
GO

/* ---------------------------------------------------------------------------
   READ — the request in full, now carrying the reversal record.

   Result sets, in order:  header · chain · history · REVERSALS (new).
   The history gains RetractedAt/RetractedReason so a struck signature renders
   struck instead of disappearing from the account of what happened.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE workflow.usp_Request_GetById @RequestInstanceId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.RequestInstanceId, r.RequestTypeId, rt.Code AS RequestTypeCode,
           rt.Name AS RequestTypeName, r.EmployeeId, e.FullName AS EmployeeName,
           b.Name AS BranchName, r.RaisedByUserId, ru.Username AS RaisedByUsername,
           CASE WHEN r.RaisedByUserId <> ISNULL(e.UserId, -1)
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS RaisedOnBehalf,
           r.[Status], r.CurrentStepNo, r.Title, r.SubmittedAt, r.ClosedAt, r.ClosedReason,
           d.[Version] AS WorkflowVersion,
           r.VersionMovedAt, r.VersionMovedBy
    FROM workflow.REQUEST_INSTANCE r
    JOIN workflow.REQUEST_TYPE rt        ON rt.RequestTypeId = r.RequestTypeId
    JOIN workflow.WORKFLOW_DEFINITION d  ON d.WorkflowDefinitionId = r.WorkflowDefinitionId
    JOIN hr.EMPLOYEE e                   ON e.EmployeeId = r.EmployeeId
    JOIN hr.BRANCH b                     ON b.BranchId = e.BranchId
    JOIN security.[USER] ru              ON ru.UserId = r.RaisedByUserId
    WHERE r.RequestInstanceId = @RequestInstanceId;

    SELECT si.StepNo, si.Name, si.ApproverType,
           si.ResolvedUserId, ru.Username AS ResolvedUsername,
           si.ApproverRoleId, ro.Name AS ApproverRoleName,
           si.[Status], si.ActedByUserId, au.Username AS ActedByUsername,
           si.ActedAt, si.Comment, si.SkipReason,
           CAST(CASE WHEN EXISTS (
                SELECT 1 FROM workflow.WORKFLOW_SIGNATURE sg
                WHERE sg.RequestInstanceId = si.RequestInstanceId
                  AND sg.StepNo = si.StepNo
                  AND sg.SignatureImage IS NOT NULL)
               THEN 1 ELSE 0 END AS BIT) AS HasSignatureImage
    FROM workflow.REQUEST_STEP_INSTANCE si
    LEFT JOIN security.[USER] ru ON ru.UserId = si.ResolvedUserId
    LEFT JOIN security.[USER] au ON au.UserId = si.ActedByUserId
    LEFT JOIN security.[ROLE] ro ON ro.RoleId = si.ApproverRoleId
    WHERE si.RequestInstanceId = @RequestInstanceId
    ORDER BY si.StepNo;

    SELECT sg.SignatureId, sg.StepNo, sg.[Action], sg.ActedByUserId,
           u.Username AS ActedByUsername, sg.ActedAt, sg.Comment,
           CAST(CASE WHEN sg.SignatureImage IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS HasSignatureImage,
           sg.RetractedAt, sg.RetractedReason
    FROM workflow.WORKFLOW_SIGNATURE sg
    LEFT JOIN security.[USER] u ON u.UserId = sg.ActedByUserId
    WHERE sg.RequestInstanceId = @RequestInstanceId
    ORDER BY sg.ActedAt, sg.SignatureId;

    /* The reversals themselves — their own event line, not folded into the
       signatures. A half-signed reopen (CompletedAt NULL) is how the page knows
       to say it is waiting on the other of GM/Owner. */
    SELECT rv.ReversalId, rv.Kind, rv.Reason,
           rv.FirstSignUserId,  fu.Username AS FirstSignUsername,  rv.FirstSignRole,
           rv.SecondSignUserId, su.Username AS SecondSignUsername, rv.SecondSignRole,
           rv.CompletedAt, rv.CreatedAt
    FROM workflow.REQUEST_REVERSAL rv
    LEFT JOIN security.[USER] fu ON fu.UserId = rv.FirstSignUserId
    LEFT JOIN security.[USER] su ON su.UserId = rv.SecondSignUserId
    WHERE rv.RequestInstanceId = @RequestInstanceId
    ORDER BY rv.CreatedAt, rv.ReversalId;
END;
GO
