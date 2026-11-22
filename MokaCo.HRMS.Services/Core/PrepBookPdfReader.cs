using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Services.Workflow;
using PDFtoImage;
using SkiaSharp;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace MokaCo.HRMS.Services.Core;

/// <summary>
/// THE GUIDE AS A PDF. An admin uploads the Drink Preparation Guide itself and the system turns it into a book the
/// Recipes page can show - nobody prepares files by hand:
///
///   every page   is drawn to a JPEG (<see cref="PageSide"/> px on its longer side) and stored like a scanned page
///                of a recipe book (core.PREP_BOOK_SCAN, kind 'page'), with a small picture of it inside the book
///   its text     when the PDF has a text layer: the page is named after its first line and found by any word on it.
///                A PDF made of pictures (a scan, an export of images) has no text to read: its pages are named
///                "Page N" and found by flipping through the pictures.
///
/// What comes out has the shape of a recipe book, so nothing downstream changes: one entry per page, category
/// "pages", and "source": "pdf" on the book. The recipe CARDS (ingredients, steps, sizes) are not in a PDF; they come
/// with the recipe book (.zip) only.
///
/// The file comes from a browser, so it is not trusted: opened by PDFium (the reader Chrome uses), refused with a
/// sentence when it cannot be opened, is protected by a password, or has more pages than <see cref="MaxPages"/>.
/// </summary>
public static partial class PrepBookPdfReader
{
    public const int MaxPages = 300;
    public const int PageSide = 1800;
    public const int ThumbWidth = 320;
    public const int MaxTextLength = 4000;
    public const int MaxTitleLength = 80;
    public const string PageCategory = "pages";

    [GeneratedRegex(@"\s+")] private static partial Regex Spaces();

    private static WorkflowException Refuse(string message) => new(400, message);

    /// <summary>"%PDF-" within the first kilobyte: what every PDF starts with (some writers put a few bytes before it).</summary>
    public static bool LooksLikePdf(ReadOnlySpan<byte> file)
        => file[..Math.Min(file.Length, 1024)].IndexOf("%PDF-"u8) >= 0;

    public static PrepBookPackage Read(byte[] pdf)
    {
        int count;
        IList<System.Drawing.SizeF> sizes;
        try
        {
            count = Conversion.GetPageCount(pdf);
            sizes = Conversion.GetPageSizes(pdf);
        }
        catch (Exception ex) when (ex is not WorkflowException)
        {
            throw Refuse("That PDF could not be opened. If it is protected by a password, save a copy without one and upload that.");
        }
        if (count < 1) throw Refuse("That PDF has no pages.");
        if (count > MaxPages) throw Refuse($"That PDF has {count} pages; a guide may have up to {MaxPages}.");

        var texts = ReadTexts(pdf, count);
        var entries = new JsonArray();
        var scans = new List<PrepBookScan>(count);
        long total = 0;

        for (var i = 0; i < count; i++)
        {
            var number = i + 1;
            byte[] page, thumb;
            try
            {
                (page, thumb) = Draw(pdf, i, i < sizes.Count ? sizes[i] : default);
            }
            catch (Exception ex) when (ex is not WorkflowException)
            {
                throw Refuse($"Page {number} of that PDF could not be read.");
            }
            total += page.Length;
            if (total > PrepBookPackageReader.MaxTotalBytes)
                throw Refuse($"The guide's pages come to more than {PrepBookPackageReader.MaxTotalBytes / (1024 * 1024)} MB.");

            var text = texts[i];
            var entry = new JsonObject
            {
                ["id"] = $"page-{number:000}",
                ["name"] = TitleOf(text) ?? $"Page {number}",
                ["category"] = PageCategory,
                ["page"] = number,
                ["thumb"] = "data:image/jpeg;base64," + Convert.ToBase64String(thumb),
            };
            if (text.Length > 0) entry["text"] = text;
            entries.Add(entry);
            scans.Add(new PrepBookScan { Kind = "page", Number = number, Bytes = page });
        }

        var book = new JsonObject { ["source"] = "pdf", ["recipes"] = entries };
        var json = book.ToJsonString();
        return new PrepBookPackage
        {
            Json = json,
            ETag = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json)))[..16].ToLowerInvariant(),
            RecipeCount = count,
            Scans = scans,
        };
    }

    /// <summary>One page as a JPEG no larger than a stored scan may be, and its small picture.</summary>
    private static (byte[] Page, byte[] Thumb) Draw(byte[] pdf, int index, System.Drawing.SizeF size)
    {
        // The longer side decides: a landscape page is PageSide wide, a portrait one PageSide tall.
        var portrait = size.Height > size.Width && size.Width > 0;
        var options = portrait
            ? new RenderOptions(Height: PageSide, WithAspectRatio: true, BackgroundColor: SKColors.White)
            : new RenderOptions(Width: PageSide, WithAspectRatio: true, BackgroundColor: SKColors.White);

        using var bitmap = Conversion.ToImage(pdf, page: index, options: options);
        byte[]? page = null;
        foreach (var quality in new[] { 82, 70, 55 })
        {
            page = Jpeg(bitmap, quality);
            if (page.Length <= PrepBookPackageReader.MaxImageBytes) break;
        }
        if (page is null || page.Length > PrepBookPackageReader.MaxImageBytes)
            throw Refuse($"Page {index + 1} is too detailed to store ({PrepBookPackageReader.MaxImageBytes / (1024 * 1024)} MB a page at most).");

        var thumbHeight = Math.Max(1, (int)Math.Round((double)ThumbWidth * bitmap.Height / Math.Max(1, bitmap.Width)));
        using var small = bitmap.Resize(new SKImageInfo(ThumbWidth, thumbHeight), new SKSamplingOptions(SKCubicResampler.Mitchell))
                          ?? throw Refuse($"Page {index + 1} of that PDF could not be read.");
        return (page, Jpeg(small, 72));
    }

    private static byte[] Jpeg(SKBitmap bitmap, int quality)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, quality);
        return data.ToArray();
    }

    /// <summary>
    /// The text of each page, in reading order, tidied - or "" for a page of pictures. Best effort: a PDF whose text
    /// cannot be read is still a guide whose pages can be shown.
    /// </summary>
    private static string[] ReadTexts(byte[] pdf, int count)
    {
        var texts = Enumerable.Repeat(string.Empty, count).ToArray();
        try
        {
            using var document = PdfDocument.Open(pdf);
            for (var i = 0; i < count && i < document.NumberOfPages; i++)
            {
                try { texts[i] = Tidy(ContentOrderTextExtractor.GetText(document.GetPage(i + 1))); }
                catch (Exception) { texts[i] = string.Empty; }
            }
        }
        catch (Exception)
        {
            // No text: the pages are found by their pictures.
        }
        return texts;
    }

    /// <summary>Lines kept, spaces within a line folded, control characters out, cut at <see cref="MaxTextLength"/>.</summary>
    public static string Tidy(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return string.Empty;
        var lines = text.Replace("\r", "\n").Split('\n')
            .Select(line => Spaces().Replace(new string(line.Where(c => !char.IsControl(c)).ToArray()), " ").Trim())
            .Where(line => line.Length > 0);
        var tidy = string.Join("\n", lines);
        return tidy.Length <= MaxTextLength ? tidy : tidy[..MaxTextLength];
    }

    /// <summary>A page is named after its first line that has at least three letters; null when it has none.</summary>
    public static string? TitleOf(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            if (line.Count(char.IsLetter) < 3) continue;
            return line.Length <= MaxTitleLength ? line : line[..MaxTitleLength].TrimEnd() + "…";
        }
        return null;
    }
}
