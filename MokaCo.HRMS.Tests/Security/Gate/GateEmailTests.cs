using MokaCo.HRMS.Services.Security.Gate;

namespace MokaCo.HRMS.Tests.Security.Gate;

/// <summary>
/// GateEmail.Normalize against the cases security.fn_GateNormalizeEmail is tested with (N1–N19 of the
/// SQL tests): the two must give the same text, because the guard on the caller's own extra address
/// compares this with what the procedure stored.
/// </summary>
public class GateEmailTests
{
    [Theory]
    [InlineData(null, null)]                                                   // N1
    [InlineData("", null)]                                                     // N2
    [InlineData("    ", null)]                                                 // N3
    [InlineData("  NoAtSign  ", "noatsign")]                                   // N4
    [InlineData("gmail.com", "gmail.com")]                                     // N5
    [InlineData("  John.Doe+HR@Gmail.COM  ", "johndoe@gmail.com")]             // N6
    [InlineData("j.o.h.n@googlemail.com", "john@gmail.com")]                   // N7
    [InlineData("John.Doe+x.y@GoogleMail.Com", "johndoe@gmail.com")]           // N8
    [InlineData("a+b+c@gmail.com", "a@gmail.com")]                             // N9
    [InlineData("a.b@c@gmail.com", "ab@c@gmail.com")]                          // N10
    [InlineData("x.y@gmail.com@MokaNco.com.lb", "x.y@gmail.com@mokanco.com.lb")] // N11
    [InlineData("Maya.K+test@MokaNco.com.lb", "maya.k+test@mokanco.com.lb")]   // N12
    [InlineData("some.one@gmail.co", "some.one@gmail.co")]                     // N13
    [InlineData("a.b@mail.gmail.com", "a.b@mail.gmail.com")]                   // N14
    [InlineData("user@", "user@")]                                             // N15
    [InlineData("+only@gmail.com", "@gmail.com")]                              // N16
    [InlineData("@GMAIL.com", "@gmail.com")]                                   // N17
    [InlineData("sharedfamily@googlemail.com", "sharedfamily@gmail.com")]      // N18
    [InlineData("Shared.Family+tony@gmail.com", "sharedfamily@gmail.com")]     // N18
    public void Normalize_gives_the_procedures_text(string? email, string? expected)
        => Assert.Equal(expected, GateEmail.Normalize(email));

    [Fact]
    public void A_long_address_comes_back_whole()   // N19
        => Assert.Equal(312, GateEmail.Normalize(new string('x', 300) + "@example.com")!.Length);
}
