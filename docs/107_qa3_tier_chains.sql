/* ============================================================================
   107_qa3_tier_chains.sql - QA3 (deep test, 2026-10-19), lead: which chain a requester's seniority tier picks.

   QA3 LEAD-2  A TIER CHAIN SERVED THE WRONG END OF THE HIERARCHY. Decision D6 made tier 1 the head and 9 the lowest,
               and the chain builder says a chain set to tier X "applies to this tier and more senior (smaller numbers)".
               The chain pickers in the repo (usp_Definition_GetActive, written as "the same resolution
               usp_Request_Submit uses") still take "the highest MinRequesterTier <= the requester's tier": the rule of
               the first model (1 = staff, 3 = executive). Under D6 that makes a chain set to tier 2 serve tiers 2-9,
               everyone but the head, and a new employee - on the lowest tier since script 106 (LEAD-1) - follow the
               most senior chain there is.
               THE RULE FROM HERE ON: a chain set to tier X serves tier X and every more senior tier (1..X); a requester
               follows the NARROWEST chain that serves them (the smallest X at or above their tier); the default chain
               (no tier) serves everybody else.
                 - workflow.usp_TierChains_Probe tells which rule the LIVE usp_Request_Submit follows: against a probe
                   request type with a default chain and a tier chain, it submits for a probe employee on the head tier
                   and on the lowest tier, and reads which chain each got. Everything it writes is inside a savepoint
                   it rolls back: nothing is kept, whatever happens.
                 - workflow.usp_TierChains_Align rewrites the choice in the live usp_Request_Submit (and in the preview,
                   usp_Definition_GetActive) when the probe finds the old rule AND the procedure's text holds it exactly
                   as the repo wrote it - each fragment once. The probe must then find the new rule, or nothing is kept.
                   The rest of each procedure is left exactly as it is live. Anything else changes nothing and prints an
                   OWNER CHECK with the lines to change by hand.
                 - workflow.usp_Definition_SetMinTier took only 2 or 3 (the first model) while the builder offers every
                   tier of the dictionary: it now takes any tier but the lowest (a chain for the lowest tier and every
                   tier above it is everybody: that is the default chain).
               Printed at the end (OWNER CHECK): every active tier chain, the tiers it serves under the rule in force and
               how many active employees that is.

   STALE REPO COPIES (contract review CON-7). usp_Definition_SetMinTier is redefined from an UNNUMBERED script, checked
   against what the API passes and reads (@WorkflowDefinitionId, @MinRequesterTier; WorkflowDefinitionId, Version,
   MinRequesterTier); the first batches stop the whole script if the live copy has a parameter this one does not know.
   usp_Request_Submit and usp_Definition_GetActive are never redefined from a copy: only their own live text is edited.

   Needs: hr.APPROVAL_TIER, workflow.WORKFLOW_DEFINITION.MinRequesterTier. Idempotent: run it again and nothing
   changes (the probe then finds the new rule). Apply with sqlcmd -C -I -b.
   ============================================================================ */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ------------------------- prerequisites and stale-copy guards (nothing changes before these pass) ------------------------- */
IF OBJECT_ID('hr.APPROVAL_TIER') IS NULL OR COL_LENGTH('workflow.WORKFLOW_DEFINITION', 'MinRequesterTier') IS NULL
   OR OBJECT_ID('workflow.usp_Request_Submit') IS NULL
BEGIN RAISERROR('107_qa3_tier_chains.sql needs hr.APPROVAL_TIER, WORKFLOW_DEFINITION.MinRequesterTier and usp_Request_Submit. Nothing was applied.', 16, 1); SET NOEXEC ON; END
GO
IF EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('workflow.usp_Definition_SetMinTier')
           AND name NOT IN (N'@WorkflowDefinitionId', N'@MinRequesterTier'))
BEGIN RAISERROR('107_qa3_tier_chains.sql: the live workflow.usp_Definition_SetMinTier has a parameter this script does not know (it is newer than the repo copy). Merge by hand; nothing was applied.', 16, 1); SET NOEXEC ON; END
GO

/* ==================================== 1. the tier of a chain: any but the lowest ==================================== */
CREATE OR ALTER PROCEDURE workflow.usp_Definition_SetMinTier
    @WorkflowDefinitionId INT, @MinRequesterTier INT = NULL
AS BEGIN SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM workflow.WORKFLOW_DEFINITION
                   WHERE WorkflowDefinitionId = @WorkflowDefinitionId AND [Status] = 'Draft')
    BEGIN RAISERROR('The tier can only be set on a Draft definition.', 16, 1); RETURN 1; END
    /* script 107 (QA3 LEAD-2): a chain set to tier X serves X and every more senior tier (1 = the head, D6). Any tier of
       the dictionary but the lowest: that one and every tier above it is everybody - the default chain. */
    IF @MinRequesterTier IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM hr.APPROVAL_TIER WHERE TierNo = @MinRequesterTier)
        BEGIN RAISERROR('Tier %d is not on the tier list. Choose one of the tiers on the Tiers page, or Everyone.', 16, 1, @MinRequesterTier); RETURN 1; END
        IF @MinRequesterTier = (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER)
        BEGIN RAISERROR('Tier %d is the lowest tier: a chain for it and every tier above it is everybody. Choose Everyone (the default chain) instead.', 16, 1, @MinRequesterTier); RETURN 1; END
    END
    UPDATE workflow.WORKFLOW_DEFINITION SET MinRequesterTier = @MinRequesterTier
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
    SELECT WorkflowDefinitionId, [Version], MinRequesterTier FROM workflow.WORKFLOW_DEFINITION
    WHERE WorkflowDefinitionId = @WorkflowDefinitionId;
END;
GO

/* ==================================== 2. the probe: which rule does the live submit follow? ==================================== */
CREATE OR ALTER PROCEDURE workflow.usp_TierChains_Probe
    @Rule   VARCHAR(10)   = NULL OUTPUT,    -- 'Senior' (D6: tier X serves 1..X), 'Junior' (the old rule: X..lowest),
                                            -- 'None' (the submit does not pick by tier), 'Unknown' (the probe could not run)
    @Detail NVARCHAR(400) = NULL OUTPUT,
    @Quiet  BIT = 0                         -- 1: no result row (for callers in this script)
AS
BEGIN
    /* script 107 (QA3 LEAD-2). Submits twice for a probe employee - on the head tier, then on the lowest - against a
       probe request type with a default chain and a chain for the tier just below the head, then rolls everything back
       to its own savepoint. Safe inside a caller's transaction: only a failure inside the live submit that dooms the
       transaction rolls the caller's back too, and that is reported as 'Unknown'. Returns its answer in @Rule. */
    SET NOCOUNT ON;
    DECLARE @Head INT = (SELECT MIN(TierNo) FROM hr.APPROVAL_TIER), @Low INT = (SELECT MAX(TierNo) FROM hr.APPROVAL_TIER);
    DECLARE @HeadDef INT, @LowDef INT, @DefaultDef INT, @TierDef INT;
    SET @Rule = 'Unknown'; SET @Detail = NULL;

    IF @Head IS NULL OR @Low IS NULL OR @Low - @Head < 2
    BEGIN
        SET @Rule = 'None';
        SET @Detail = N'The tier list has fewer than three tiers: there is nothing to probe.';
    END
    ELSE
    BEGIN
        DECLARE @Outer INT = @@TRANCOUNT;
        DECLARE @S TABLE (RequestInstanceId INT, [Status] VARCHAR(20), CurrentStepNo INT,
                          WorkflowDefinitionId INT, WorkflowVersion INT, MinRequesterTier INT);
        IF @Outer = 0 BEGIN TRAN;
        SAVE TRANSACTION TierChainsProbe;
        BEGIN TRY
            DECLARE @Type INT, @Emp INT, @User INT,
                    @Branch INT = (SELECT TOP (1) BranchId FROM hr.BRANCH ORDER BY BranchId),
                    @Dept INT = (SELECT TOP (1) DepartmentId FROM hr.DEPARTMENT ORDER BY DepartmentId),
                    @Pos INT = (SELECT TOP (1) PositionId FROM hr.[POSITION] ORDER BY PositionId);
            SET @User = (SELECT TOP (1) UserId FROM security.[USER] WHERE IsActive = 1 ORDER BY UserId);

            INSERT INTO workflow.REQUEST_TYPE (Code, Name, IsActive) VALUES ('QA3_TIER_PROBE', N'QA3 tier probe (rolled back)', 1);
            SET @Type = CAST(SCOPE_IDENTITY() AS INT);
            INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], MinRequesterTier) VALUES (@Type, 1, 'Active', NULL);
            SET @DefaultDef = CAST(SCOPE_IDENTITY() AS INT);
            INSERT INTO workflow.WORKFLOW_DEFINITION (RequestTypeId, [Version], [Status], MinRequesterTier) VALUES (@Type, 2, 'Active', @Head + 1);
            SET @TierDef = CAST(SCOPE_IDENTITY() AS INT);

            /* nobody reports to the probe employee and it reports to nobody: the hierarchy trigger has nothing to refuse */
            INSERT INTO hr.EMPLOYEE (BranchId, DepartmentId, PositionId, FullName, HireDate, Email, PhoneNumber, PreferredLanguage, ApprovalTier)
            VALUES (@Branch, @Dept, @Pos, N'QA3 tier probe (rolled back)', CAST(SYSDATETIME() AS DATE),
                    CONCAT(N'qa3.tier.probe.', REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), N'@invalid.example'),
                    '96100000000', 'en', @Head);
            SET @Emp = CAST(SCOPE_IDENTITY() AS INT);

            INSERT INTO @S EXEC workflow.usp_Request_Submit @RequestTypeCode = 'QA3_TIER_PROBE', @EmployeeId = @Emp,
                                                            @RaisedByUserId = @User, @Title = N'QA3 tier probe';
            SET @HeadDef = (SELECT TOP (1) WorkflowDefinitionId FROM @S);
            DELETE FROM @S;

            UPDATE hr.EMPLOYEE SET ApprovalTier = @Low WHERE EmployeeId = @Emp;
            INSERT INTO @S EXEC workflow.usp_Request_Submit @RequestTypeCode = 'QA3_TIER_PROBE', @EmployeeId = @Emp,
                                                            @RaisedByUserId = @User, @Title = N'QA3 tier probe';
            SET @LowDef = (SELECT TOP (1) WorkflowDefinitionId FROM @S);

            ROLLBACK TRANSACTION TierChainsProbe;
            IF @Outer = 0 COMMIT;      -- nothing is left in it: this only closes the transaction the probe opened

            SET @Rule = CASE WHEN @HeadDef = @TierDef AND @LowDef = @DefaultDef THEN 'Senior'
                             WHEN @HeadDef = @DefaultDef AND @LowDef = @TierDef THEN 'Junior'
                             ELSE 'None' END;
            SET @Detail = CONCAT(N'With a default chain and a chain for tier ', @Head + 1, N', the submit gave tier ', @Head,
                                 N' the ', CASE @HeadDef WHEN @TierDef THEN N'tier' WHEN @DefaultDef THEN N'default' ELSE N'unexpected' END,
                                 N' chain and tier ', @Low, N' the ',
                                 CASE @LowDef WHEN @TierDef THEN N'tier' WHEN @DefaultDef THEN N'default' ELSE N'unexpected' END, N' chain.');
        END TRY
        BEGIN CATCH
            SET @Detail = LEFT(CONCAT(N'The probe could not run: ', ERROR_MESSAGE()), 400);
            IF XACT_STATE() = -1 ROLLBACK;                        -- doomed: the whole transaction goes, the caller's too
            ELSE IF XACT_STATE() = 1
            BEGIN
                ROLLBACK TRANSACTION TierChainsProbe;
                IF @Outer = 0 COMMIT;
            END
            SET @Rule = 'Unknown';
        END CATCH
    END

    IF @Quiet = 0
        SELECT @Rule AS [Rule], @Detail AS Detail;
END;
GO

/* ==================================== 3. align the live chain choice with the rule ==================================== */
CREATE OR ALTER PROCEDURE workflow.usp_TierChains_Align
AS
BEGIN
    /* script 107 (QA3 LEAD-2). Edits only the chain choice in the LIVE text of usp_Request_Submit, and of the preview
       usp_Definition_GetActive so it shows what the submit will do, and only where each holds the old rule exactly as
       the repo wrote it. The submit is edited only when the probe finds the old rule; the preview only when the submit
       follows the new rule (already, or with this edit). One transaction, kept only when the probe then finds the new
       rule. Prints what it did, or what to change by hand. */
    SET NOCOUNT ON;
    DECLARE @Rule VARCHAR(10), @Detail NVARCHAR(400);
    EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
    PRINT CONCAT('QA3 LEAD-2: the live usp_Request_Submit follows the ', @Rule, ' rule. ', @Detail);

    /* the old rule, as the repo wrote it, and its replacement */
    DECLARE @Old1 NVARCHAR(100) = N'ISNULL(d.MinRequesterTier, 1) <= @Tier',
            @New1 NVARCHAR(100) = N'(d.MinRequesterTier IS NULL OR d.MinRequesterTier >= @Tier)',
            @Old2 NVARCHAR(100) = N'ORDER BY ISNULL(d.MinRequesterTier, 1) DESC',
            @New2 NVARCHAR(100) = N'ORDER BY CASE WHEN d.MinRequesterTier IS NULL THEN 1 ELSE 0 END, d.MinRequesterTier',
            /* the preview without a requester showed the default chain because tier 1 qualified for nothing else; under the
               new rule tier 1 qualifies for every chain, so "no requester" becomes a tier below all of them */
            @Old3 NVARCHAR(100) = N'DECLARE @Tier INT = 1;',
            @New3 NVARCHAR(100) = N'DECLARE @Tier INT = 2147483647;  -- script 107: no requester = the default chain';

    DECLARE @Edits TABLE (Name SYSNAME PRIMARY KEY, NewText NVARCHAR(MAX) NOT NULL);
    DECLARE @Name SYSNAME, @Text NVARCHAR(MAX), @n1 INT, @n2 INT, @n3 INT, @Pos INT, @K INT, @Head INT,
            @Line NVARCHAR(MAX), @Rest NVARCHAR(MAX), @Nl INT, @Step INT = 1;

    WHILE @Step <= 2
    BEGIN
        SET @Name = CASE @Step WHEN 1 THEN N'workflow.usp_Request_Submit' ELSE N'workflow.usp_Definition_GetActive' END;
        SET @Text = OBJECT_DEFINITION(OBJECT_ID(@Name));
        SET @Step += 1;

        IF @Text IS NULL OR CHARINDEX(@New1, @Text) > 0
            CONTINUE;                                                -- missing, or on the new rule already
        IF @Name = N'workflow.usp_Request_Submit' AND @Rule <> 'Junior'
            CONTINUE;                                                -- the probe found no old rule to change
        IF @Name = N'workflow.usp_Definition_GetActive'
           AND NOT (@Rule = 'Senior' OR EXISTS (SELECT 1 FROM @Edits WHERE Name = N'workflow.usp_Request_Submit'))
        BEGIN
            IF @Rule = 'Junior'
                PRINT 'QA3 LEAD-2: usp_Definition_GetActive (the preview) is left on the old rule too, so it keeps showing what the submit does.';
            CONTINUE;
        END

        SET @n1 = (DATALENGTH(@Text) - DATALENGTH(REPLACE(@Text, @Old1, N''))) / DATALENGTH(@Old1);
        SET @n2 = (DATALENGTH(@Text) - DATALENGTH(REPLACE(@Text, @Old2, N''))) / DATALENGTH(@Old2);
        SET @n3 = CASE WHEN @Name = N'workflow.usp_Definition_GetActive'
                       THEN (DATALENGTH(@Text) - DATALENGTH(REPLACE(@Text, @Old3, N''))) / DATALENGTH(@Old3) ELSE 1 END;

        /* the header: "CREATE <spaces> PROC..." (CREATE OR ALTER is stored as "CREATE   PROCEDURE") */
        SET @Head = 0; SET @Pos = 1;
        WHILE @Head = 0
        BEGIN
            SET @Pos = CHARINDEX(N'CREATE', @Text, @Pos);
            IF @Pos = 0 BREAK;
            SET @K = @Pos + 6;
            WHILE SUBSTRING(@Text, @K, 1) IN (N' ', NCHAR(9), NCHAR(13), NCHAR(10)) SET @K += 1;
            IF @K > @Pos + 6 AND SUBSTRING(@Text, @K, 4) = N'PROC' SET @Head = @Pos;
            ELSE SET @Pos = @Pos + 6;
        END

        IF @n1 = 1 AND @n2 = 1 AND @n3 = 1 AND @Head > 0
        BEGIN
            SET @Text = REPLACE(REPLACE(@Text, @Old1, @New1), @Old2, @New2);
            IF @Name = N'workflow.usp_Definition_GetActive' SET @Text = REPLACE(@Text, @Old3, @New3);
            /* the positions before the edits: the header comes before both fragments, so @Head and @K still hold */
            SET @Text = STUFF(@Text, @Head, @K - @Head, N'CREATE OR ALTER ');
            INSERT INTO @Edits (Name, NewText) VALUES (@Name, @Text);
        END
        ELSE
        BEGIN
            PRINT CONCAT('QA3 LEAD-2 OWNER CHECK: ', @Name, ' was NOT changed - its text does not hold the old rule exactly once as ',
                         'the repo wrote it (', @n1, '/', @n2, '/', @n3, ', header ', IIF(@Head > 0, 'found', 'not found'), '). Change its ',
                         'choice of chain by hand: a chain set to tier X serves tiers 1..X, the narrowest first, the default chain last. ',
                         'Its lines that mention MinRequesterTier:');
            SET @Rest = @Text;
            WHILE LEN(@Rest) > 0
            BEGIN
                SET @Nl = CHARINDEX(NCHAR(10), @Rest);
                SET @Line = CASE WHEN @Nl = 0 THEN @Rest ELSE LEFT(@Rest, @Nl - 1) END;
                SET @Rest = CASE WHEN @Nl = 0 THEN N'' ELSE SUBSTRING(@Rest, @Nl + 1, LEN(@Rest)) END;
                IF CHARINDEX(N'MinRequesterTier', @Line) > 0 OR CHARINDEX(N'@Tier', @Line) > 0
                    PRINT CONCAT(N'    ', LTRIM(RTRIM(REPLACE(@Line, NCHAR(13), N''))));
            END
        END
    END

    IF NOT EXISTS (SELECT 1 FROM @Edits)
    BEGIN
        IF @Rule = 'Senior' PRINT 'QA3 LEAD-2: tier chains already serve their tier and every more senior one; nothing to change.';
        RETURN 0;
    END

    BEGIN TRAN;
    BEGIN TRY
        DECLARE e CURSOR LOCAL FAST_FORWARD FOR SELECT Name, NewText FROM @Edits ORDER BY Name DESC;   -- the submit first
        OPEN e; FETCH NEXT FROM e INTO @Name, @Text;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC (@Text);
            FETCH NEXT FROM e INTO @Name, @Text;
        END
        CLOSE e; DEALLOCATE e;

        IF EXISTS (SELECT 1 FROM @Edits WHERE Name = N'workflow.usp_Request_Submit')
        BEGIN
            DECLARE @After VARCHAR(10), @AfterDetail NVARCHAR(400);
            EXEC workflow.usp_TierChains_Probe @Rule = @After OUTPUT, @Detail = @AfterDetail OUTPUT, @Quiet = 1;
            IF @@TRANCOUNT = 0
            BEGIN
                PRINT CONCAT('QA3 LEAD-2 OWNER CHECK: the probe failed after the change, which was undone. ', @AfterDetail);
                RETURN 1;
            END
            IF @After <> 'Senior'
            BEGIN
                ROLLBACK;
                PRINT CONCAT('QA3 LEAD-2 OWNER CHECK: after the change the probe found the ', @After, ' rule, so the change was undone. ', @AfterDetail);
                RETURN 1;
            END
        END
        COMMIT;
        DECLARE @Done NVARCHAR(400) = (SELECT STRING_AGG(Name, N' and ') FROM @Edits);
        PRINT CONCAT('QA3 LEAD-2: changed ', @Done,
                     ': a requester now gets the narrowest chain serving their tier (a chain set to tier X serves 1..X; the default chain last).');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        PRINT CONCAT('QA3 LEAD-2 OWNER CHECK: the change could not be made and was undone: ', ERROR_MESSAGE());
        RETURN 1;
    END CATCH
    RETURN 0;
END;
GO

EXEC workflow.usp_TierChains_Align;
GO

/* ==================================== 4. OWNER CHECK: the active tier chains ==================================== */
DECLARE @Rule VARCHAR(10), @Detail NVARCHAR(400);
EXEC workflow.usp_TierChains_Probe @Rule = @Rule OUTPUT, @Detail = @Detail OUTPUT, @Quiet = 1;
DECLARE @Today DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Middle East Standard Time' AS DATE);
DECLARE @Chains TABLE (Code VARCHAR(30), [Version] INT, MinTier INT, People INT);
INSERT INTO @Chains (Code, [Version], MinTier, People)
SELECT rt.Code, d.[Version], d.MinRequesterTier,
       (SELECT COUNT(*) FROM hr.EMPLOYEE e
        WHERE e.IsDeleted = 0 AND (e.TerminationDate IS NULL OR e.TerminationDate >= @Today)
          AND ((@Rule = 'Junior' AND e.ApprovalTier >= d.MinRequesterTier) OR (@Rule <> 'Junior' AND e.ApprovalTier <= d.MinRequesterTier)))
FROM workflow.WORKFLOW_DEFINITION d
JOIN workflow.REQUEST_TYPE rt ON rt.RequestTypeId = d.RequestTypeId
WHERE d.[Status] = 'Active' AND d.MinRequesterTier IS NOT NULL;

DECLARE @Lines NVARCHAR(MAX) = (
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(N'    ', Code, N' v', [Version], N': tier ', MinTier,
                      CASE @Rule WHEN 'Junior' THEN CONCAT(N' serves tier ', MinTier, N' and every LESS senior one - ', People, N' active employee(s)')
                                 WHEN 'Senior' THEN CONCAT(N' serves tiers 1-', MinTier, N' - ', People, N' active employee(s)')
                                 ELSE N' (the live submit does not pick chains by tier)' END)), NCHAR(10))
           WITHIN GROUP (ORDER BY Code, MinTier)
    FROM @Chains);
IF @Lines IS NULL
    PRINT CONCAT('QA3 LEAD-2: no active chain is set to a tier; every request follows its default chain (rule in force: ', @Rule, ').');
ELSE
BEGIN
    PRINT CONCAT('QA3 LEAD-2 OWNER CHECK: the active tier chains (rule in force: ', @Rule, '). A requester follows the narrowest one serving them:');
    PRINT @Lines;
END
GO

PRINT '107_qa3_tier_chains.sql in place';
GO
