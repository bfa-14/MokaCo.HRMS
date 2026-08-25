using MokaCo.HRMS.Model.Workflow;
using MokaCo.HRMS.Repository.Workflow;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace MokaCo.HRMS.Services.Workflow;

/// <summary>
/// Renders one request as a PDF — the paper record that goes out attached to the closing email.
///
/// WHY A DOCUMENT AND NOT A LONGER EMAIL BODY. The mail says what happened; this is the thing the
/// employee keeps, forwards to a bank, or prints for a file. It carries the whole approval chain
/// with every signer and date on it, which is the part an email body cannot hold legibly and the
/// part anybody asking for "proof" actually means.
///
/// IT READS THE SAME ROW THE SCREEN DOES — usp_Request_GetById through the repository, no second
/// source and no formatting done in SQL. A PDF that could disagree with the request page would be
/// worse than no PDF at all.
///
/// NOTHING HERE THROWS ON MISSING DATA. A request with no steps yet, no title, no closing reason is
/// a real request; each of those renders as a dash. The only failure this can produce is a genuine
/// rendering fault, and the worker treats even that as "send without the attachment".
/// </summary>
public interface IRequestPdfBuilder
{
    /// <summary>
    /// The request as PDF bytes, or NULL when there is no such request.
    ///
    /// Null rather than an exception for the not-found case, because it is not an error here: the
    /// outbox row may name a request that was since removed, and the mail should still go.
    /// </summary>
    Task<byte[]?> BuildAsync(int requestInstanceId);
}

public class RequestPdfBuilder : IRequestPdfBuilder
{
    private readonly IRequestRepository _requests;

    public RequestPdfBuilder(IRequestRepository requests) => _requests = requests;

    public async Task<byte[]?> BuildAsync(int requestInstanceId)
    {
        var detail = await _requests.GetByIdAsync(requestInstanceId);
        if (detail is null)
            return null;

        var header = detail.Header;
        var steps = detail.Steps.OrderBy(s => s.StepNo).ToList();

        return Document.Create(doc =>
        {
            doc.Page(page =>
            {
                page.Size(PageSizes.A4);
                page.Margin(32);
                page.DefaultTextStyle(x => x.FontSize(10).FontColor(Colors.Black));

                page.Header().Column(head =>
                {
                    head.Item().Text(header.RequestTypeName).FontSize(18).SemiBold();
                    head.Item().Text($"Request #{header.RequestInstanceId}")
                        .FontSize(11).FontColor(Colors.Grey.Darken1);
                    head.Item().PaddingTop(6).LineHorizontal(1).LineColor(Colors.Grey.Lighten1);
                });

                page.Content().PaddingVertical(12).Column(body =>
                {
                    body.Spacing(14);

                    // WHO AND WHAT, as labelled pairs rather than a sentence — this is a record, and
                    // a record is scanned for one field at a time, not read from the top.
                    body.Item().Column(facts =>
                    {
                        facts.Spacing(3);
                        facts.Item().Row(r => Pair(r, "Employee", header.EmployeeName));
                        facts.Item().Row(r => Pair(r, "Branch", header.BranchName));
                        facts.Item().Row(r => Pair(r, "Status", header.Status));
                        facts.Item().Row(r => Pair(r, "Submitted", Date(header.SubmittedAt)));
                        facts.Item().Row(r => Pair(r, "Closed", Date(header.ClosedAt)));

                        // Only where it is true: "Raised by" on a request somebody raised for
                        // themselves is a line that says nothing.
                        if (header.RaisedOnBehalf)
                            facts.Item().Row(r => Pair(r, "Raised by", header.RaisedByUsername));

                        if (!string.IsNullOrWhiteSpace(header.ClosedReason))
                            facts.Item().Row(r => Pair(r, "Reason", header.ClosedReason!));
                    });

                    if (!string.IsNullOrWhiteSpace(header.Title))
                    {
                        body.Item().Column(t =>
                        {
                            t.Item().Text("Details").SemiBold();
                            t.Item().PaddingTop(2).Text(header.Title!);
                        });
                    }

                    body.Item().Column(chain =>
                    {
                        chain.Item().Text("Approval chain").SemiBold();
                        chain.Item().PaddingTop(4).Table(table =>
                        {
                            table.ColumnsDefinition(c =>
                            {
                                c.ConstantColumn(28);   // step no
                                c.RelativeColumn(3);    // step name
                                c.RelativeColumn(2);    // status
                                c.RelativeColumn(3);    // signer
                                c.RelativeColumn(2);    // date
                                c.RelativeColumn(4);    // comment
                            });

                            table.Header(h =>
                            {
                                h.Cell().Element(HeadCell).Text("#");
                                h.Cell().Element(HeadCell).Text("Step");
                                h.Cell().Element(HeadCell).Text("Status");
                                h.Cell().Element(HeadCell).Text("Signed by");
                                h.Cell().Element(HeadCell).Text("Date");
                                h.Cell().Element(HeadCell).Text("Comment");
                            });

                            if (steps.Count == 0)
                            {
                                table.Cell().ColumnSpan(6).Element(BodyCell)
                                    .Text("No steps were materialised for this request.")
                                    .FontColor(Colors.Grey.Darken1);
                            }

                            foreach (var step in steps)
                            {
                                table.Cell().Element(BodyCell).Text(step.StepNo.ToString());
                                table.Cell().Element(BodyCell).Text(step.Name);
                                table.Cell().Element(BodyCell).Text(StatusText(step));
                                // The person, then the role they answered for — a Role step signed by
                                // one holder is still that role's step, and the chain must say both.
                                table.Cell().Element(BodyCell).Text(SignerText(step));
                                table.Cell().Element(BodyCell).Text(Date(step.ActedAt));
                                table.Cell().Element(BodyCell).Text(step.Comment ?? "—");
                            }
                        });
                    });
                });

                page.Footer().Column(foot =>
                {
                    foot.Item().LineHorizontal(1).LineColor(Colors.Grey.Lighten2);
                    foot.Item().PaddingTop(4).Row(r =>
                    {
                        r.RelativeItem().Text($"Generated {DateTime.UtcNow:yyyy-MM-dd HH:mm} UTC")
                            .FontSize(8).FontColor(Colors.Grey.Darken1);
                        r.ConstantItem(80).AlignRight().Text(x =>
                        {
                            x.DefaultTextStyle(s => s.FontSize(8).FontColor(Colors.Grey.Darken1));
                            x.CurrentPageNumber();
                            x.Span(" / ");
                            x.TotalPages();
                        });
                    });
                });
            });
        }).GeneratePdf();
    }

    /// <summary>A label/value line. The label column is fixed so every value starts on one edge.</summary>
    private static void Pair(RowDescriptor row, string label, string value)
    {
        row.ConstantItem(90).Text(label).FontColor(Colors.Grey.Darken1);
        row.RelativeItem().Text(string.IsNullOrWhiteSpace(value) ? "—" : value);
    }

    /// <summary>
    /// A skipped step says WHY where its status goes. A skip that reads as a bare "Skipped" is
    /// indistinguishable from an unsigned gap, which is exactly the doubt this document exists to
    /// remove.
    /// </summary>
    private static string StatusText(RequestStep step)
        => step.Status == "Skipped" && !string.IsNullOrWhiteSpace(step.SkipReason)
            ? $"Skipped — {step.SkipReason}"
            : step.Status;

    private static string SignerText(RequestStep step)
    {
        var who = step.ActedByUsername ?? step.ResolvedUsername;
        if (string.IsNullOrWhiteSpace(who))
            return string.IsNullOrWhiteSpace(step.ApproverRoleName) ? "—" : step.ApproverRoleName!;

        return string.IsNullOrWhiteSpace(step.ApproverRoleName)
            ? who!
            : $"{who} ({step.ApproverRoleName})";
    }

    /// <summary>Dates only — the hour a signature was recorded is on the screen, not on the record.</summary>
    private static string Date(DateTime? value) => value?.ToString("yyyy-MM-dd") ?? "—";

    private static IContainer HeadCell(IContainer c) => c
        .Background(Colors.Grey.Lighten3)
        .BorderBottom(1).BorderColor(Colors.Grey.Lighten1)
        .PaddingVertical(4).PaddingHorizontal(3)
        .DefaultTextStyle(x => x.SemiBold().FontSize(9));

    private static IContainer BodyCell(IContainer c) => c
        .BorderBottom(1).BorderColor(Colors.Grey.Lighten2)
        .PaddingVertical(4).PaddingHorizontal(3)
        .DefaultTextStyle(x => x.FontSize(9));
}
