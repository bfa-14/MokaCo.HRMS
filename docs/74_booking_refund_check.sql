/* ============================================================================
   74_booking_refund_check.sql — QA fix pack, SQL 74 (BUG-24).

   BUG-24 (blocker)  booking.usp_Refund_Add records a refund as a NEGATIVE line in
                     booking.BOOKING_PAYMENT (Amount = -@Amount, IsRefund = 1), and the table's
                     original check constraint CK_PAY_Amount ([Amount] > 0) refused it — so no refund
                     could ever be recorded and RefundStatus never left 'Due'.

   This script REPLACES CK_PAY_Amount with the refund-aware rule
        (IsRefund = 0 AND Amount > 0) OR (IsRefund = 1 AND Amount < 0)
   — a payment is still strictly positive, a refund line is strictly negative, and a zero line is
   refused either way. IsRefund is NOT NULL on the table (default 0); ISNULL() is kept in the
   predicate so the rule also holds on a database where the column was added nullable.

   Idempotent: when the constraint already carries the refund-aware definition it is left alone
   (no drop/re-add, no lock on the table); otherwise it is dropped and re-created WITH CHECK, which
   validates every existing row. It ends by PRINTing the definition that is now in force.
   Run on MokaCo_HRMS (VS Code mssql extension, or `sqlcmd -C -I -i docs/74_booking_refund_check.sql`).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('booking.BOOKING_PAYMENT', 'IsRefund') IS NULL
BEGIN
    RAISERROR('booking.BOOKING_PAYMENT.IsRefund is missing — apply the booking refund script that adds it (usp_Refund_Add) before this one.', 16, 1);
    RETURN;
END
GO

DECLARE @current NVARCHAR(MAX) = (SELECT cc.[definition]
                                  FROM sys.check_constraints cc
                                  WHERE cc.parent_object_id = OBJECT_ID('booking.BOOKING_PAYMENT')
                                    AND cc.[name] = 'CK_PAY_Amount');

/* Already refund-aware: mentions IsRefund and allows a negative amount. Nothing to do. */
IF @current IS NOT NULL AND @current LIKE '%IsRefund%' AND @current LIKE '%<(0)%'
    PRINT 'CK_PAY_Amount already allows refund lines — unchanged.';
ELSE
BEGIN
    IF @current IS NOT NULL
    BEGIN
        ALTER TABLE booking.BOOKING_PAYMENT DROP CONSTRAINT CK_PAY_Amount;
        PRINT CONCAT('Dropped CK_PAY_Amount: ', @current);
    END

    ALTER TABLE booking.BOOKING_PAYMENT WITH CHECK
        ADD CONSTRAINT CK_PAY_Amount
        CHECK ((ISNULL(IsRefund, 0) = 0 AND Amount > 0) OR (ISNULL(IsRefund, 0) = 1 AND Amount < 0));
    PRINT 'Created CK_PAY_Amount (refund lines may be negative).';
END
GO

/* The definition now in force, so the person running this can see it without opening SSMS. */
SELECT cc.[name] AS ConstraintName, cc.[definition] AS Definition, cc.is_not_trusted AS IsNotTrusted
FROM sys.check_constraints cc
WHERE cc.parent_object_id = OBJECT_ID('booking.BOOKING_PAYMENT') AND cc.[name] = 'CK_PAY_Amount';

DECLARE @def NVARCHAR(MAX) = (SELECT cc.[definition] FROM sys.check_constraints cc
                              WHERE cc.parent_object_id = OBJECT_ID('booking.BOOKING_PAYMENT') AND cc.[name] = 'CK_PAY_Amount');
PRINT CONCAT('CK_PAY_Amount = ', @def);
GO
