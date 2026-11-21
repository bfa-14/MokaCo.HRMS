using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Routing;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Tests.Core;

/// <summary>
/// The recipe book upload (Recipes page, script 115). The file comes from a browser, so it is checked: only the
/// files a book may hold, images that are JPEGs by their own bytes, recipes with an id, a name and a known category,
/// and every recipe's scan present. The recipes below are invented: the real guide is confidential and is never in
/// the source code, the tests included.
/// </summary>
public class PrepBookTests
{
    private static readonly byte[] Jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0xFF, 0xD9];

    private const string TwoRecipes = """
        { "recipes": [
          { "id": "test-latte", "name": "Test Latte", "category": "coffee", "temp": "hot", "page": 3,
            "aliases": ["sample"], "ingredients": ["2 shots of water", " "],
            "steps": [ { "title": "Pour", "items": ["Pour it"] }, { "title": "Serve", "items": [] } ] },
          { "id": "test-label", "name": "Test Tea", "category": "traditional", "label": 1, "thumb": false,
            "sizes": [ { "size": "12 oz", "items": ["1 scoop"] } ], "method": ["Boil once"] }
        ] }
        """;

    private static MemoryStream Zip(params (string Name, byte[] Bytes)[] files)
    {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, bytes) in files)
            {
                using var entry = zip.CreateEntry(name).Open();
                entry.Write(bytes);
            }
        stream.Position = 0;
        return stream;
    }

    private static (string, byte[]) Json(string text) => ("recipes.json", Encoding.UTF8.GetBytes(text));

    private static (string, byte[])[] GoodBook(string prefix = "") =>
    [
        (prefix + "recipes.json", Encoding.UTF8.GetBytes(TwoRecipes)),
        (prefix + "pages/guide-03.jpg", Jpeg),
        (prefix + "thumbs/guide-03.jpg", Jpeg),
        (prefix + "labels/label-01.jpg", Jpeg),
    ];

    private static string Refusal(MemoryStream zip)
    {
        var ex = Assert.Throws<WorkflowException>(() => PrepBookPackageReader.Read(zip));
        Assert.Equal(400, ex.StatusCode);
        return ex.Message;
    }

    [Fact]
    public void A_good_book_is_read_with_its_scans_and_thumbnails()
    {
        var package = PrepBookPackageReader.Read(Zip(GoodBook()));

        Assert.Equal(2, package.RecipeCount);
        Assert.Equal([("page", 3), ("label", 1)], package.Scans.Select(s => (s.Kind, s.Number)));
        Assert.Equal(16, package.ETag.Length);

        var recipes = JsonDocument.Parse(package.Json).RootElement.GetProperty("recipes");
        var latte = recipes[0];
        Assert.Equal("Test Latte", latte.GetProperty("name").GetString());
        Assert.StartsWith("data:image/jpeg;base64,", latte.GetProperty("thumb").GetString());
        Assert.Equal(1, latte.GetProperty("ingredients").GetArrayLength());   // the blank line is dropped
        Assert.Equal(2, latte.GetProperty("steps").GetArrayLength());
        var tea = recipes[1];
        Assert.False(tea.TryGetProperty("thumb", out _));                       // "thumb": false never leaves as a flag
        Assert.Equal("12 oz", tea.GetProperty("sizes")[0].GetProperty("size").GetString());
    }

    [Fact]
    public void The_same_book_gives_the_same_tag_and_a_changed_one_another()
    {
        var a = PrepBookPackageReader.Read(Zip(GoodBook())).ETag;
        Assert.Equal(a, PrepBookPackageReader.Read(Zip(GoodBook())).ETag);
        var changed = GoodBook();
        changed[0] = Json(TwoRecipes.Replace("Test Latte", "Test Latte 2"));
        Assert.NotEqual(a, PrepBookPackageReader.Read(Zip(changed)).ETag);
    }

    [Fact]
    public void A_zipped_folder_and_the_clutter_of_a_Mac_are_accepted()
    {
        var files = GoodBook("My book/").ToList();
        files.Add(("__MACOSX/My book/._recipes.json", [1, 2, 3]));
        files.Add(("My book/.DS_Store", [1, 2, 3]));
        Assert.Equal(2, PrepBookPackageReader.Read(Zip([.. files])).RecipeCount);
    }

    [Fact]
    public void Unknown_keys_of_a_recipe_are_dropped_not_stored()
    {
        var book = GoodBook();
        book[0] = Json(TwoRecipes.Replace("\"temp\": \"hot\",", "\"temp\": \"hot\", \"html\": \"<script>x</script>\","));
        Assert.DoesNotContain("script", PrepBookPackageReader.Read(Zip(book)).Json);
    }

    [Fact]
    public void What_is_not_a_zip_is_refused()
    {
        Assert.Contains("neither a PDF nor a .zip", Refusal(new MemoryStream(Encoding.UTF8.GetBytes("hello, not a zip at all"))));
        Assert.Contains("empty", Refusal(new MemoryStream()));
    }

    [Fact]
    public void A_book_without_recipes_json_is_refused()
        => Assert.Contains("no recipes.json", Refusal(Zip(("pages/guide-03.jpg", Jpeg))));

    [Theory]
    [InlineData("readme.txt")]
    [InlineData("pages/guide-03.png")]
    [InlineData("pages/../../etc/passwd")]
    [InlineData("scripts/run.js")]
    public void A_file_that_does_not_belong_is_refused(string name)
    {
        var files = GoodBook().Append((name, Jpeg)).ToArray();
        Assert.Contains("does not belong", Refusal(Zip(files)));
    }

    [Fact]
    public void An_image_that_is_not_a_JPEG_by_its_bytes_is_refused()
    {
        var book = GoodBook();
        book[1] = ("pages/guide-03.jpg", Encoding.UTF8.GetBytes("<svg onload=alert(1)>"));
        Assert.Contains("not a JPEG", Refusal(Zip(book)));
    }

    [Fact]
    public void A_recipe_whose_scan_is_missing_is_refused()
    {
        var book = GoodBook().Where(f => f.Item1 != "labels/label-01.jpg").ToArray();
        Assert.Contains("labels/label-01.jpg is not in the book", Refusal(Zip(book)));
    }

    [Theory]
    [InlineData("\"id\": \"test-latte\"", "\"id\": \"Test Latte!\"", "lowercase letters")]
    [InlineData("\"id\": \"test-label\"", "\"id\": \"test-latte\"", "two recipes have this id")]
    [InlineData("\"name\": \"Test Latte\"", "\"name\": \"  \"", "\"name\" is empty")]
    [InlineData("\"category\": \"coffee\"", "\"category\": \"desserts\"", "category must be one of")]
    [InlineData("\"temp\": \"hot\"", "\"temp\": \"warm\"", "hot or iced")]
    [InlineData("\"page\": 3", "\"page\": \"three\"", "whole number")]
    [InlineData("\"ingredients\": [\"2 shots of water\", \" \"]", "\"ingredients\": \"water\"", "list of text")]
    [InlineData("\"label\": 1,", "", "needs a guide page")]
    public void A_bad_recipe_is_refused_with_what_is_wrong(string find, string replace, string expected)
    {
        Assert.Contains(find, TwoRecipes);
        var book = GoodBook();
        book[0] = Json(TwoRecipes.Replace(find, replace));
        Assert.Contains(expected, Refusal(Zip(book)));
    }

    [Fact]
    public void An_oversized_image_is_refused()
    {
        var big = new byte[PrepBookPackageReader.MaxImageBytes + 10];
        Jpeg.CopyTo(big, 0);
        var book = GoodBook();
        book[1] = ("pages/guide-03.jpg", big);
        Assert.Contains("larger than", Refusal(Zip(book)));
    }

    [Fact]
    public void Reading_needs_VIEW_and_uploading_and_the_facts_need_MANAGE()
    {
        var actions = typeof(PrepBookController).GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Where(m => m.GetCustomAttributes<HttpMethodAttribute>().Any())
            .ToDictionary(m => m.Name, m => m.GetCustomAttribute<HasPermissionAttribute>()?.Policy);
        Assert.Equal(5, actions.Count);   // the guide is confidential: no route may be open
        const string view = HasPermissionAttribute.Prefix + "PREP_BOOK_VIEW", manage = HasPermissionAttribute.Prefix + "PREP_BOOK_MANAGE";
        Assert.Equal(view, actions[nameof(PrepBookController.Get)]);
        Assert.Equal(view, actions[nameof(PrepBookController.GuidePage)]);
        Assert.Equal(view, actions[nameof(PrepBookController.Label)]);
        Assert.Equal(manage, actions[nameof(PrepBookController.Upload)]);
        Assert.Equal(manage, actions[nameof(PrepBookController.Info)]);
    }

    /* ---- the guide as a PDF: the system draws its pages (the PDFs below are made here, with invented text) ---- */

    private static byte[] Pdf(params string?[] pageTitles)
    {
        var builder = new UglyToad.PdfPig.Writer.PdfDocumentBuilder();
        var font = builder.AddStandard14Font(UglyToad.PdfPig.Fonts.Standard14Fonts.Standard14Font.Helvetica);
        foreach (var title in pageTitles)
        {
            var page = builder.AddPage(UglyToad.PdfPig.Content.PageSize.A5, isPortrait: false);
            if (title is null) continue;
            page.AddText(title, 28, new UglyToad.PdfPig.Core.PdfPoint(40, 340), font);
            page.AddText("2 shots of water - stir gently", 14, new UglyToad.PdfPig.Core.PdfPoint(40, 300), font);
        }
        return builder.Build();
    }

    [Fact]
    public void A_pdf_becomes_a_book_of_pages_each_drawn_named_and_found_by_its_text()
    {
        var package = PrepBookPdfReader.Read(Pdf("Test Latte", null, "Sample Frappe"));

        Assert.Equal(3, package.RecipeCount);
        Assert.Equal([("page", 1), ("page", 2), ("page", 3)], package.Scans.Select(s => (s.Kind, s.Number)));
        Assert.All(package.Scans, s =>
        {
            Assert.True(s.Bytes.Length > 1000);
            Assert.Equal(new byte[] { 0xFF, 0xD8, 0xFF }, s.Bytes[..3]);                    // a JPEG by its own bytes
            Assert.True(s.Bytes.Length <= PrepBookPackageReader.MaxImageBytes);
        });

        using var book = JsonDocument.Parse(package.Json);
        Assert.Equal("pdf", book.RootElement.GetProperty("source").GetString());
        var pages = book.RootElement.GetProperty("recipes").EnumerateArray().ToList();
        Assert.Equal(["page-001", "page-002", "page-003"], pages.Select(p => p.GetProperty("id").GetString()));
        Assert.All(pages, p =>
        {
            Assert.Equal("pages", p.GetProperty("category").GetString());
            Assert.StartsWith("data:image/jpeg;base64,/9j/", p.GetProperty("thumb").GetString());
        });
        // A page with text is named after its first line and carries its text; a page of pictures is "Page N".
        Assert.Equal(["Test Latte", "Page 2", "Sample Frappe"], pages.Select(p => p.GetProperty("name").GetString()));
        Assert.Contains("stir gently", pages[0].GetProperty("text").GetString());
        Assert.False(pages[1].TryGetProperty("text", out _));
        Assert.Equal([1, 2, 3], pages.Select(p => p.GetProperty("page").GetInt32()));
    }

    [Fact]
    public void The_same_pdf_gives_the_same_book_and_another_one_another_tag()
    {
        var first = PrepBookPdfReader.Read(Pdf("Test Latte"));
        var again = PrepBookPdfReader.Read(Pdf("Test Latte"));
        var other = PrepBookPdfReader.Read(Pdf("Test Mocha"));

        Assert.Equal(first.ETag, again.ETag);
        Assert.NotEqual(first.ETag, other.ETag);
    }

    [Fact]
    public void What_is_not_a_readable_pdf_is_refused_with_a_sentence()
    {
        var broken = Encoding.ASCII.GetBytes("%PDF-1.7\nthis is not really a PDF");
        var refused = Assert.Throws<WorkflowException>(() => PrepBookPdfReader.Read(broken));
        Assert.Equal(400, refused.StatusCode);
        Assert.Contains("could not be opened", refused.Message);

        Assert.True(PrepBookPdfReader.LooksLikePdf(broken));
        Assert.True(PrepBookPdfReader.LooksLikePdf(Pdf("Test")));
        Assert.False(PrepBookPdfReader.LooksLikePdf("PK\u0003\u0004 a zip"u8));
        Assert.False(PrepBookPdfReader.LooksLikePdf([]));
    }

    [Fact]
    public void A_pages_first_line_names_it_and_its_text_is_tidied()
    {
        Assert.Equal("Test Latte", PrepBookPdfReader.TitleOf("12\nTest Latte\n2 shots"));
        Assert.Null(PrepBookPdfReader.TitleOf("12\n--"));
        Assert.EndsWith("…", PrepBookPdfReader.TitleOf(new string('a', 200)));
        Assert.Equal("Test  Latte".Replace("  ", " ") + "\n2 shots", PrepBookPdfReader.Tidy("  Test \t Latte \r\n\r\n 2   shots \u0007"));
        Assert.Equal(string.Empty, PrepBookPdfReader.Tidy(" \n "));
        Assert.Equal(PrepBookPdfReader.MaxTextLength, PrepBookPdfReader.Tidy(new string('x', 9000)).Length);
    }

    private sealed class KeepingRepository : MokaCo.HRMS.Repository.Core.IPrepBookRepository
    {
        public MokaCo.HRMS.Model.Core.PrepBookPackage? Saved;
        public Task<MokaCo.HRMS.Model.Core.PrepBookRow?> GetAsync(string? ifNoneMatch) => Task.FromResult<MokaCo.HRMS.Model.Core.PrepBookRow?>(null);
        public Task<byte[]?> GetScanAsync(string kind, int number) => Task.FromResult<byte[]?>(null);
        public Task ReplaceAsync(MokaCo.HRMS.Model.Core.PrepBookPackage package, int uploadedByUserId) { Saved = package; return Task.CompletedTask; }
    }

    [Fact]
    public async Task The_upload_is_a_pdf_or_a_recipe_book_by_its_own_bytes()
    {
        var repo = new KeepingRepository();
        var service = new PrepBookService(repo);

        var fromPdf = await service.ReplaceAsync(new MemoryStream(Pdf("Test Latte", "Test Mocha")), 7);
        Assert.Equal((2, 2), (fromPdf.RecipeCount, fromPdf.ScanCount));
        Assert.Contains("\"source\":\"pdf\"", repo.Saved!.Json);

        var fromZip = await service.ReplaceAsync(Zip(("recipes.json", Encoding.UTF8.GetBytes(TwoRecipes)), ("pages/guide-03.jpg", Jpeg), ("labels/label-01.jpg", Jpeg)), 7);
        Assert.Equal((2, 2), (fromZip.RecipeCount, fromZip.ScanCount));
        Assert.DoesNotContain("\"source\"", repo.Saved!.Json);

        var neither = await Assert.ThrowsAsync<WorkflowException>(() => service.ReplaceAsync(new MemoryStream(Encoding.ASCII.GetBytes("hello")), 7));
        Assert.Contains("neither a PDF nor a .zip", neither.Message);
        var empty = await Assert.ThrowsAsync<WorkflowException>(() => service.ReplaceAsync(new MemoryStream(), 7));
        Assert.Contains("empty", empty.Message);
    }
}
