using MokaCo.HRMS.Services.Core;

namespace MokaCo.HRMS.Tests.Core;

/// <summary>QA3: a carry-over expiry the expiry job cannot read is refused when it is saved, not discovered at year end.</summary>
public class SettingValueRulesTests
{
    [Theory]
    [InlineData("03-31")]
    [InlineData("12-31")]
    [InlineData("02-29")]
    [InlineData("")]
    [InlineData(" 01-15 ")]
    [InlineData(null)]
    public void A_month_day_or_nothing_is_accepted(string? value)
        => Assert.Null(SettingValueRules.Problem("LeaveCarryOverExpiresOn", value));

    [Theory]
    [InlineData("31/03")]
    [InlineData("3-31")]
    [InlineData("13-01")]
    [InlineData("04-31")]
    [InlineData("02-30")]
    [InlineData("March 31")]
    public void Anything_else_is_refused_with_a_sentence(string value)
        => Assert.Contains("MM-DD", SettingValueRules.Problem("LeaveCarryOverExpiresOn", value));

    [Fact]
    public void Other_keys_are_not_judged_here()
        => Assert.Null(SettingValueRules.Problem("StandardWorkDayHours", "whatever"));
}
