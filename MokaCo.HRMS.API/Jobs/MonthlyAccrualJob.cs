using MokaCo.HRMS.Services.HR;
using Quartz;

namespace MokaCo.HRMS.Api.Jobs;

/// <summary>
/// Fires once a month (see the cron trigger in Program.cs) and posts leave accruals for the
/// current month. Quartz's Microsoft DI job factory creates a new DI scope per execution and
/// resolves this job from it, so the injected <see cref="ILeaveAccrualService"/> (and the
/// scoped repositories behind it) are correctly scoped — never a captive singleton dependency.
/// </summary>
[DisallowConcurrentExecution]
public class MonthlyAccrualJob : IJob
{
    private readonly ILeaveAccrualService _accrual;
    private readonly ILogger<MonthlyAccrualJob> _logger;

    public MonthlyAccrualJob(ILeaveAccrualService accrual, ILogger<MonthlyAccrualJob> logger)
    {
        _accrual = accrual;
        _logger = logger;
    }

    public async Task Execute(IJobExecutionContext context)
    {
        var now = DateTime.UtcNow;
        var result = await _accrual.RunMonthlyAccrual(now.Year, now.Month);
        _logger.LogInformation(
            "Monthly leave accrual for {Year:D4}-{Month:D2}: posted {Posted}, skipped {Skipped}.",
            now.Year, now.Month, result.Posted, result.Skipped);
    }
}
