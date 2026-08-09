using MokaCo.HRMS.Model.HR;

namespace MokaCo.HRMS.Services.HR;

public interface ILeaveAccrualService
{
    /// <summary>
    /// Posts one Accrual movement per active employee per accruing leave type for the given
    /// month. Idempotent: an existing accrual for the period is skipped. Mid-month joiners are
    /// pro-rated. Returns how many movements were posted vs skipped.
    /// </summary>
    Task<AccrualRunResult> RunMonthlyAccrual(int year, int month, int? createdBy = null);
}
