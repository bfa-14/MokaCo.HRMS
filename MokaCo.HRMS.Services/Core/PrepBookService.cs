using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using MokaCo.HRMS.Model.Core;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Services.Workflow;

namespace MokaCo.HRMS.Services.Core;

public interface IPrepBookService
{
    /// <summary>The book on file (JSON null when <paramref name="ifNoneMatch"/> is its tag), or null when none was uploaded.</summary>
    Task<PrepBookRow?> GetAsync(string? ifNoneMatch);
    Task<PrepBookInfo?> GetInfoAsync();
    Task<byte[]?> GetScanAsync(string kind, int number);

    /// <summary>
    /// Replaces the book on file with an upload: the guide as a PDF (the system draws its pages,
    /// <see cref="PrepBookPdfReader"/>) or a recipe book (.zip, <see cref="PrepBookPackageReader"/>).
    /// </summary>
    Task<PrepBookInfo> ReplaceAsync(Stream upload, int uploadedByUserId);
}

/// <summary>
/// THE DRINK RECIPES ("Recipes" page) — the bar's Drink Preparation Guide and the MC MIX labels.
///
/// THE GUIDE IS CONFIDENTIAL, so its content is neither in the source code nor in the website's files: an admin
/// uploads it - the guide itself as a PDF (its pages are drawn here and shown as a book of pages), or a recipe book
/// (.zip: recipe cards with their scans) - it is checked here, stored in the database (script 115) and served only
/// to a signed-in user who holds PREP_BOOK_VIEW. Uploading again replaces the whole book: that is how a new version
/// of the guide is published.
/// </summary>
public class PrepBookService : IPrepBookService
{
    private readonly IPrepBookRepository _repo;
    public PrepBookService(IPrepBookRepository repo) => _repo = repo;

    public Task<PrepBookRow?> GetAsync(string? ifNoneMatch) => _repo.GetAsync(ifNoneMatch);

    public async Task<PrepBookInfo?> GetInfoAsync()
    {
        // "*" matches any book: the facts come back without the JSON (a few hundred KB nobody asked for).
        var row = await _repo.GetAsync("*");
        return row is null ? null : InfoOf(row);
    }

    public Task<byte[]?> GetScanAsync(string kind, int number)
        => kind is "page" or "label" && number is >= 1 and <= 999 ? _repo.GetScanAsync(kind, number) : Task.FromResult<byte[]?>(null);

    public async Task<PrepBookInfo> ReplaceAsync(Stream upload, int uploadedByUserId)
    {
        // Read whole first: the size is checked on what actually arrived, and what the file IS is decided by its own
        // first bytes, never by its name.
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = await upload.ReadAsync(chunk)) > 0)
        {
            if (buffer.Length + read > PrepBookPackageReader.MaxZipBytes)
                throw new WorkflowException(400, $"The file is larger than {PrepBookPackageReader.MaxZipBytes / (1024 * 1024)} MB.");
            buffer.Write(chunk, 0, read);
        }
        if (buffer.Length == 0) throw new WorkflowException(400, "The file is empty. Choose the guide (PDF) or the recipe book (.zip).");

        PrepBookPackage package;
        if (PrepBookPdfReader.LooksLikePdf(buffer.GetBuffer().AsSpan(0, (int)buffer.Length)))
        {
            // Drawing the pages is a few seconds of processor work: off the request's thread.
            var pdf = buffer.ToArray();
            package = await Task.Run(() => PrepBookPdfReader.Read(pdf));
        }
        else
        {
            buffer.Position = 0;
            package = PrepBookPackageReader.Read(buffer);
        }

        await _repo.ReplaceAsync(package, uploadedByUserId);
        var row = await _repo.GetAsync(package.ETag);
        return row is null
            ? new PrepBookInfo { ETag = package.ETag, RecipeCount = package.RecipeCount, ScanCount = package.Scans.Count, UploadedAtUtc = DateTime.UtcNow }
            : InfoOf(row);
    }

    private static PrepBookInfo InfoOf(PrepBookRow row) => new()
    {
        ETag = row.ETag, RecipeCount = row.RecipeCount, ScanCount = row.ScanCount, UploadedAtUtc = row.UploadedAtUtc, UploadedBy = row.UploadedBy,
    };
}

/// <summary>
/// Reads and CHECKS an uploaded recipe book. The file comes from a browser, so nothing in it is trusted:
///
///   recipes.json             { "recipes": [ { id, name, category, temp?, aliases?, ingredients?, sizes?, steps?, method?,
///                              notes?, page?, label?, thumb? } ] } - each recipe names its guide page and/or its label
///   pages/guide-NN.jpg       the scanned guide pages
///   labels/label-NN.jpg      the scanned MIX labels
///   thumbs/guide-NN.jpg      the small drink photo of a guide page (optional; "thumb": false on a recipe = none)
///
/// Refused with a sentence that says what is wrong: anything else in the zip, a file that is not a JPEG by its own
/// bytes, an over-sized file or book, a recipe without an id/name/known category, two recipes with one id, text
/// that is not text, and a recipe pointing at a page or label whose scan is not in the zip. Folder entries and the
/// clutter a Mac or an iPad adds (__MACOSX, .DS_Store) are skipped. A zip whose files sit inside one top folder is
/// accepted (that is what "compress this folder" produces).
///
/// What comes out is the book as the page reads it: the recipes re-written from the parsed values (never the
/// uploaded text itself), each drink's thumbnail inside as a data URI, and a tag that changes when the book does.
/// </summary>
public static partial class PrepBookPackageReader
{
    public const long MaxZipBytes = 40L * 1024 * 1024;
    public const int MaxEntries = 500;
    public const int MaxRecipes = 500;
    public const int MaxImageBytes = 2 * 1024 * 1024;
    public const int MaxThumbBytes = 100 * 1024;
    public const int MaxJsonBytes = 2 * 1024 * 1024;
    public const long MaxTotalBytes = 80L * 1024 * 1024;
    public const int MaxTextLength = 400;
    public const int MaxListItems = 40;

    public static readonly IReadOnlyList<string> Categories = ["coffee", "matcha", "refreshers", "frozen", "shakes", "traditional", "basics"];

    [GeneratedRegex(@"^pages/guide-(\d{2,3})\.jpe?g$", RegexOptions.IgnoreCase)] private static partial Regex PageFile();
    [GeneratedRegex(@"^labels/label-(\d{2,3})\.jpe?g$", RegexOptions.IgnoreCase)] private static partial Regex LabelFile();
    [GeneratedRegex(@"^thumbs/guide-(\d{2,3})\.jpe?g$", RegexOptions.IgnoreCase)] private static partial Regex ThumbFile();
    [GeneratedRegex(@"^[a-z0-9]+(-[a-z0-9]+)*$")] private static partial Regex IdShape();

    private static WorkflowException Refuse(string message) => new(400, message);

    public static PrepBookPackage Read(Stream upload)
    {
        // Copied first: the size is checked on what actually arrived, and ZipArchive needs to seek.
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = upload.Read(chunk, 0, chunk.Length)) > 0)
        {
            if (buffer.Length + read > MaxZipBytes) throw Refuse($"The recipe book is larger than {MaxZipBytes / (1024 * 1024)} MB.");
            buffer.Write(chunk, 0, read);
        }
        if (buffer.Length == 0) throw Refuse("The file is empty. Choose the guide (PDF) or the recipe book (.zip).");
        buffer.Position = 0;

        ZipArchive zip;
        try { zip = new ZipArchive(buffer, ZipArchiveMode.Read, leaveOpen: true); }
        catch (InvalidDataException) { throw Refuse("That file is neither a PDF nor a .zip. Choose the guide (PDF) or the recipe book (.zip)."); }

        using (zip)
        {
            if (zip.Entries.Count > MaxEntries) throw Refuse($"The recipe book holds more than {MaxEntries} files.");

            var files = zip.Entries
                .Where(e => !e.FullName.EndsWith('/') && !IsClutter(e.FullName))
                .Select(e => (Entry: e, Name: e.FullName.Replace('\\', '/')))
                .ToList();
            var prefix = CommonTopFolder(files.Select(f => f.Name).ToList());

            byte[]? json = null;
            var pages = new Dictionary<int, byte[]>();
            var labels = new Dictionary<int, byte[]>();
            var thumbs = new Dictionary<int, byte[]>();
            long total = 0;

            foreach (var (entry, fullName) in files)
            {
                var name = fullName[prefix.Length..];
                if (name.Equals("recipes.json", StringComparison.OrdinalIgnoreCase))
                {
                    json = ReadEntry(entry, MaxJsonBytes, name, ref total);
                    continue;
                }

                Match m;
                if ((m = PageFile().Match(name)).Success) Put(pages, m, ReadJpeg(entry, MaxImageBytes, name, ref total), name);
                else if ((m = LabelFile().Match(name)).Success) Put(labels, m, ReadJpeg(entry, MaxImageBytes, name, ref total), name);
                else if ((m = ThumbFile().Match(name)).Success) Put(thumbs, m, ReadJpeg(entry, MaxThumbBytes, name, ref total), name);
                else throw Refuse($"\"{Shorten(name)}\" does not belong in a recipe book. It may hold recipes.json, pages/guide-NN.jpg, labels/label-NN.jpg and thumbs/guide-NN.jpg.");
            }

            if (json is null) throw Refuse("The recipe book has no recipes.json.");
            var recipes = ReadRecipes(json);

            foreach (var r in recipes)
            {
                var id = r["id"]!.GetValue<string>();
                if (r["page"] is { } page && !pages.ContainsKey(page.GetValue<int>()))
                    throw Refuse($"Recipe \"{id}\" points at guide page {page.GetValue<int>()}, and pages/guide-{page.GetValue<int>():00}.jpg is not in the book.");
                if (r["label"] is { } label && !labels.ContainsKey(label.GetValue<int>()))
                    throw Refuse($"Recipe \"{id}\" points at label {label.GetValue<int>()}, and labels/label-{label.GetValue<int>():00}.jpg is not in the book.");

                var wantsThumb = r["thumb"]?.GetValue<bool>() != false;
                r.Remove("thumb");
                if (wantsThumb && r["page"] is { } p && thumbs.TryGetValue(p.GetValue<int>(), out var thumb))
                    r["thumb"] = "data:image/jpeg;base64," + Convert.ToBase64String(thumb);
            }

            var book = new JsonObject { ["recipes"] = new JsonArray(recipes.Select(r => (JsonNode)r).ToArray()) };
            var text = book.ToJsonString();
            var etag = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)))[..16].ToLowerInvariant();

            return new PrepBookPackage
            {
                Json = text,
                ETag = etag,
                RecipeCount = recipes.Count,
                Scans = pages.OrderBy(p => p.Key).Select(p => new PrepBookScan { Kind = "page", Number = p.Key, Bytes = p.Value })
                    .Concat(labels.OrderBy(l => l.Key).Select(l => new PrepBookScan { Kind = "label", Number = l.Key, Bytes = l.Value }))
                    .ToList(),
            };
        }
    }

    private static bool IsClutter(string fullName)
    {
        var name = fullName.Replace('\\', '/');
        return name.StartsWith("__MACOSX/", StringComparison.Ordinal) || name.Contains("/__MACOSX/", StringComparison.Ordinal)
               || name.EndsWith(".DS_Store", StringComparison.Ordinal) || name.EndsWith("Thumbs.db", StringComparison.OrdinalIgnoreCase)
               || name.Split('/')[^1].StartsWith("._", StringComparison.Ordinal);
    }

    /// <summary>"book/" when every file sits inside one top folder (what compressing a folder produces), else "".</summary>
    private static string CommonTopFolder(List<string> names)
    {
        if (names.Count == 0 || names.Any(n => !n.Contains('/'))) return string.Empty;
        var first = names[0][..(names[0].IndexOf('/') + 1)];
        if (first is "pages/" or "labels/" or "thumbs/") return string.Empty;
        return names.All(n => n.StartsWith(first, StringComparison.Ordinal)) ? first : string.Empty;
    }

    private static void Put(Dictionary<int, byte[]> into, Match match, byte[] bytes, string name)
    {
        var number = int.Parse(match.Groups[1].Value);
        if (number is < 1 or > 999) throw Refuse($"\"{Shorten(name)}\": the number must be between 1 and 999.");
        if (!into.TryAdd(number, bytes)) throw Refuse($"\"{Shorten(name)}\" is in the book twice.");
    }

    private static byte[] ReadEntry(ZipArchiveEntry entry, int max, string name, ref long total)
    {
        // The declared size is the first gate; the copy below is the real one (a zip can lie about its sizes).
        if (entry.Length > max) throw Refuse($"\"{Shorten(name)}\" is larger than {max / 1024} KB.");
        using var source = entry.Open();
        using var target = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = source.Read(chunk, 0, chunk.Length)) > 0)
        {
            if (target.Length + read > max) throw Refuse($"\"{Shorten(name)}\" is larger than {max / 1024} KB.");
            total += read;
            if (total > MaxTotalBytes) throw Refuse($"The recipe book unpacks to more than {MaxTotalBytes / (1024 * 1024)} MB.");
            target.Write(chunk, 0, read);
        }
        return target.ToArray();
    }

    private static byte[] ReadJpeg(ZipArchiveEntry entry, int max, string name, ref long total)
    {
        var bytes = ReadEntry(entry, max, name, ref total);
        // By its own bytes, not by its name: FF D8 FF opens every JPEG.
        if (bytes.Length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 || bytes[2] != 0xFF)
            throw Refuse($"\"{Shorten(name)}\" is not a JPEG image.");
        return bytes;
    }

    private static List<JsonObject> ReadRecipes(byte[] json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json, documentOptions: new JsonDocumentOptions { MaxDepth = 16 }); }
        catch (JsonException) { throw Refuse("recipes.json is not valid JSON."); }

        if (root is not JsonObject book || book["recipes"] is not JsonArray list)
            throw Refuse("recipes.json must be an object with a \"recipes\" list.");
        if (list.Count == 0) throw Refuse("recipes.json has no recipes.");
        if (list.Count > MaxRecipes) throw Refuse($"recipes.json has more than {MaxRecipes} recipes.");

        var ids = new HashSet<string>();
        var recipes = new List<JsonObject>();
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i] is not JsonObject source) throw Refuse($"Recipe {i + 1} is not an object.");
            var where = $"Recipe {i + 1}";

            var id = Text(source, "id", where, required: true)!;
            where = $"Recipe \"{Shorten(id)}\"";
            if (!IdShape().IsMatch(id) || id.Length > 80) throw Refuse($"{where}: the id may hold lowercase letters, digits and hyphens only (like iced-spanish-latte).");
            if (!ids.Add(id)) throw Refuse($"{where}: two recipes have this id.");

            var recipe = new JsonObject { ["id"] = id, ["name"] = Text(source, "name", where, required: true) };

            var category = Text(source, "category", where, required: true)!;
            if (!Categories.Contains(category)) throw Refuse($"{where}: the category must be one of {string.Join(", ", Categories)}.");
            recipe["category"] = category;

            if (Text(source, "temp", where) is { } temp)
            {
                if (temp is not ("hot" or "iced")) throw Refuse($"{where}: temp must be hot or iced.");
                recipe["temp"] = temp;
            }

            foreach (var key in new[] { "aliases", "ingredients", "method", "notes" })
                if (Texts(source, key, where) is { } texts) recipe[key] = texts;

            if (source["sizes"] is { } sizes)
                recipe["sizes"] = Groups(sizes, "sizes", "size", where);
            if (source["steps"] is { } steps)
                recipe["steps"] = Groups(steps, "steps", "title", where);

            var page = Number(source, "page", where);
            var label = Number(source, "label", where);
            if (page is null && label is null) throw Refuse($"{where}: it needs a guide page (\"page\") or a label (\"label\").");
            if (page is not null) recipe["page"] = page.Value;
            if (label is not null) recipe["label"] = label.Value;

            if (source["thumb"] is JsonValue thumb && thumb.TryGetValue<bool>(out var show) && !show) recipe["thumb"] = false;

            recipes.Add(recipe);
        }
        return recipes;
    }

    private static string? Text(JsonObject source, string key, string where, bool required = false)
    {
        if (source[key] is null)
        {
            if (required) throw Refuse($"{where}: \"{key}\" is missing.");
            return null;
        }
        if (source[key] is not JsonValue value || !value.TryGetValue<string>(out var text)) throw Refuse($"{where}: \"{key}\" must be text.");
        text = text.Trim();
        if (text.Length == 0)
        {
            if (required) throw Refuse($"{where}: \"{key}\" is empty.");
            return null;
        }
        if (text.Length > MaxTextLength) throw Refuse($"{where}: \"{key}\" is longer than {MaxTextLength} characters.");
        return text;
    }

    private static JsonArray? Texts(JsonObject source, string key, string where)
    {
        if (source[key] is null) return null;
        if (source[key] is not JsonArray list) throw Refuse($"{where}: \"{key}\" must be a list of text.");
        if (list.Count > MaxListItems) throw Refuse($"{where}: \"{key}\" has more than {MaxListItems} lines.");
        var result = new JsonArray();
        foreach (var item in list)
        {
            if (item is not JsonValue value || !value.TryGetValue<string>(out var text)) throw Refuse($"{where}: \"{key}\" must be a list of text.");
            text = text.Trim();
            if (text.Length == 0) continue;
            if (text.Length > MaxTextLength) throw Refuse($"{where}: a line of \"{key}\" is longer than {MaxTextLength} characters.");
            result.Add(text);
        }
        return result.Count == 0 ? null : result;
    }

    /// <summary>"steps" ([{ title, items }]) and "sizes" ([{ size, items }]).</summary>
    private static JsonArray Groups(JsonNode node, string key, string titleKey, string where)
    {
        if (node is not JsonArray list) throw Refuse($"{where}: \"{key}\" must be a list.");
        if (list.Count > MaxListItems) throw Refuse($"{where}: \"{key}\" has more than {MaxListItems} entries.");
        var result = new JsonArray();
        foreach (var item in list)
        {
            if (item is not JsonObject group) throw Refuse($"{where}: every entry of \"{key}\" must be an object with \"{titleKey}\" and \"items\".");
            result.Add(new JsonObject
            {
                [titleKey] = Text(group, titleKey, $"{where}, {key}", required: true),
                ["items"] = Texts(group, "items", $"{where}, {key}") ?? [],
            });
        }
        return result;
    }

    private static int? Number(JsonObject source, string key, string where)
    {
        if (source[key] is null) return null;
        if (source[key] is not JsonValue value || !value.TryGetValue<int>(out var number) || number is < 1 or > 999)
            throw Refuse($"{where}: \"{key}\" must be a whole number between 1 and 999.");
        return number;
    }

    private static string Shorten(string text) => text.Length <= 60 ? text : text[..60] + "…";
}
