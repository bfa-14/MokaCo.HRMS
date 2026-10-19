using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MokaCo.HRMS.Api.PublicBooking;
using MokaCo.HRMS.Model.Booking;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Booking;

namespace MokaCo.HRMS.Tests.Booking;

/// <summary>
/// The two booking switches — BookingWebsiteEnabled and BookingDepositRequired — read in BOTH dialects
/// core.SETTING stores (QA3). The Settings page keeps the dialect a row already has and writes
/// 'true'/'false' to a row with none; '1'-only readers saw a 'true' deposit switch as OFF, and a
/// '0'-only reader saw a 'false' website switch as ON — online booking that would not pause.
/// </summary>
public class BookingSwitchTests
{
    [Theory]
    [InlineData("1", true)]
    [InlineData("true", true)]
    [InlineData("True", true)]
    [InlineData(" on ", true)]
    [InlineData("yes", true)]
    [InlineData("0", false)]
    [InlineData("false", false)]
    [InlineData("off", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    [InlineData("maybe", false)]
    public void On_only_for_an_on_word(string? value, bool on)
        => Assert.Equal(on, SettingSwitch.IsOn(value));

    [Theory]
    [InlineData("0", true)]
    [InlineData("false", true)]
    [InlineData("FALSE", true)]
    [InlineData(" off ", true)]
    [InlineData("no", true)]
    [InlineData("1", false)]
    [InlineData("true", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Off_only_for_an_off_word(string? value, bool off)
        => Assert.Equal(off, SettingSwitch.IsOff(value));

    private static Mock<ISettingRepository> Settings(params (string Key, string Value)[] rows)
    {
        var settings = new Mock<ISettingRepository>();
        settings.Setup(s => s.GetAllAsync()).ReturnsAsync(rows.Select(r => new Setting { SettingKey = r.Key, SettingValue = r.Value }).ToList());
        settings.Setup(s => s.GetAsync(It.IsAny<string>()))
            .ReturnsAsync((string key) => rows.Where(r => r.Key == key).Select(r => new Setting { SettingKey = r.Key, SettingValue = r.Value }).FirstOrDefault());
        return settings;
    }

    private static PublicBookingGate Gate(Mock<ISettingRepository> settings)
    {
        var services = new ServiceCollection().AddScoped(_ => settings.Object).BuildServiceProvider();
        return new PublicBookingGate(services.GetRequiredService<IServiceScopeFactory>(), NullLogger<PublicBookingGate>.Instance);
    }

    [Theory]
    [InlineData("0", false)]
    [InlineData("false", false)]      // what the Settings page writes to a row it found empty: it used to read as ON
    [InlineData("1", true)]
    [InlineData("true", true)]
    [InlineData("", true)]            // an empty or missing row keeps online booking open, as it always did
    public async Task The_website_pause_switch_works_in_both_dialects(string value, bool enabled)
    {
        var snapshot = await Gate(Settings(("BookingWebsiteEnabled", value))).CurrentAsync();
        Assert.Equal(enabled, snapshot.WebsiteEnabled);
    }

    [Fact]
    public async Task A_missing_website_switch_leaves_booking_open()
        => Assert.True((await Gate(Settings()).CurrentAsync()).WebsiteEnabled);

    [Theory]
    [InlineData("1", true)]
    [InlineData("true", true)]
    [InlineData("0", false)]
    [InlineData("false", false)]
    public async Task The_deposit_switch_works_in_both_dialects(string value, bool required)
    {
        var service = new BookingService(Mock.Of<IBookingRepository>(), Mock.Of<IRoomRepository>(), Settings(("BookingDepositRequired", value)).Object);
        Assert.Equal(required, await service.IsDepositRequiredAsync());
    }

    [Fact]
    public async Task The_quote_tells_the_site_the_deposit_switch_as_the_api_reads_it()
    {
        var bookings = new Mock<IBookingRepository>();
        bookings.Setup(b => b.QuoteAsync(It.IsAny<PublicQuoteRequest>())).ReturnsAsync(new BookingQuote { TotalAmount = 40, DepositRequired = false });
        var service = new BookingService(bookings.Object, Mock.Of<IRoomRepository>(), Settings(("BookingDepositRequired", "true")).Object);

        var quote = await service.QuoteAsync(new PublicQuoteRequest { RoomCode = "r1" });

        Assert.True(quote!.DepositRequired);
    }

    [Theory]
    [InlineData("true", "false", true, false)]
    [InlineData("0", "1", false, true)]
    [InlineData("false", "", false, true)]
    public async Task The_catalogue_tells_the_site_both_switches_as_the_api_reads_them(string deposit, string website, bool depositRequired, bool websiteEnabled)
    {
        var rooms = new Mock<IRoomRepository>();
        rooms.Setup(r => r.GetPublicCatalogSetsAsync()).ReturnsAsync(new PublicCatalogSets
        {
            // what a '1'-only procedure would have answered for 'true' / 'false'
            Rules = new BookingRules { DepositRequired = !depositRequired, WebsiteEnabled = !websiteEnabled },
        });
        var service = new RoomService(rooms.Object, Settings(("BookingDepositRequired", deposit), ("BookingWebsiteEnabled", website)).Object);

        var catalog = await service.GetPublicCatalogAsync();

        Assert.Equal((depositRequired, websiteEnabled), (catalog.Rules.DepositRequired, catalog.Rules.WebsiteEnabled));
    }
}
