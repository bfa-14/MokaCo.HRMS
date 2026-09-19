/* ============================================================================
   80_booking_expire_holds_refs.sql — live booking updates (SignalR BookingHub).

   booking.usp_Booking_ExpireHolds cancelled the unpaid holds whose clock had run out and answered
   with a COUNT. The hub has to tell each of those bookings' confirmation pages (group
   "booking:{ref}") and the staff calendar that the status changed, and a count does not say WHICH.

   @ReturnRows BIT = 0  (new, optional)
       0  the answer is what it always was: one row, one column, Expired = the count. Every existing
          caller — and any INSERT-EXEC around it — keeps working unchanged.
       1  the answer is one row PER cancelled booking: BookingId, BookingRef. The API's five-minute
          job asks for this shape and publishes one BookingChanged / BookingStatus per row.

   The UPDATE itself is unchanged; the rows come from its OUTPUT clause, so the list is exactly what
   this call cancelled and not a second query that could see somebody else's cancellation.

   Idempotent: CREATE OR ALTER. Apply with sqlcmd -C -I.
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* worker call: holds whose clock ran out without a payment */
CREATE OR ALTER PROCEDURE booking.usp_Booking_ExpireHolds
    @ReturnRows BIT = 0
AS BEGIN SET NOCOUNT ON;
    DECLARE @Expired TABLE (BookingId INT NOT NULL, BookingRef VARCHAR(20) NULL);

    UPDATE b SET [Status] = 'Cancelled', CancelReason = N'Payment not completed in time.',
                 DecidedUtc = SYSUTCDATETIME(), HoldExpiresUtc = NULL
    OUTPUT inserted.BookingId, inserted.BookingRef INTO @Expired (BookingId, BookingRef)
    FROM booking.BOOKING b
    WHERE b.[Status] = 'Pending' AND b.HoldExpiresUtc IS NOT NULL AND b.HoldExpiresUtc < SYSUTCDATETIME()
      AND NOT EXISTS (SELECT 1 FROM booking.BOOKING_PAYMENT p WHERE p.BookingId = b.BookingId);

    IF @ReturnRows = 1
        SELECT BookingId, BookingRef FROM @Expired ORDER BY BookingId;
    ELSE
        SELECT COUNT(*) AS Expired FROM @Expired;
END;
GO

PRINT 'Script 80 applied.';
GO
