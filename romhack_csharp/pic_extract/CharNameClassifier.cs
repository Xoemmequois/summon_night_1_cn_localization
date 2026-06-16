using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

public static class CharNameClassifier
{
    private const string ApiUrl = "https://openrouter.ai/api/v1/chat/completions";
    private const string Model = "google/gemini-2.5-flash-lite";
    private const string Prompt = "この画像に日本語の文字（ひらがな・カタカナ・漢字）が含まれていますか？YES か NO だけで答えてください。";
    private const string CharsDir = "pic_output/chars";
    private const string OutputDir = "pic_output/char_names";
    private const string ProgressFile = "pic_output/char_names/.progress.json";
    private const int MaxWorkers = 8;

    public static void Run(string apiKey, string? proxyUrl)
    {
        if (string.IsNullOrEmpty(apiKey))
            return;

        Console.WriteLine("\n=== Classifying character text images ===");
        Directory.CreateDirectory(OutputDir);

        var progress = LoadProgress();
        Console.WriteLine($"Loaded progress: {progress.Count} images already checked");

        var restored = 0;
        foreach (var (name, isText) in progress)
        {
            if (!isText) continue;
            var dest = Path.Combine(OutputDir, name);
            if (File.Exists(dest)) continue;
            var src = Path.Combine(CharsDir, name);
            if (File.Exists(src))
            {
                File.Copy(src, dest);
                CopyAct(src, dest);
                CopyMeta(src, dest);
                restored++;
                Console.WriteLine($"  Restored: {name}");
            }
        }
        if (restored > 0)
            Console.WriteLine($"Restored {restored} missing text images from progress.\n");

        var imageFiles = Directory.GetFiles(CharsDir, "*.gif")
            .OrderBy(f => f).ToArray();
        var remaining = imageFiles
            .Where(f => !progress.ContainsKey(Path.GetFileName(f)))
            .ToArray();
        Console.WriteLine($"Total: {imageFiles.Length}, Remaining: {remaining.Length}");

        if (remaining.Length == 0)
        {
            Console.WriteLine("All done!");
            return;
        }

        var textCount = progress.Values.Count(v => v);
        var completed = 0;
        var lockObj = new object();
        var progressDict = new ConcurrentDictionary<string, bool>(progress);

        var handler = new HttpClientHandler();
        if (!string.IsNullOrEmpty(proxyUrl))
            handler.Proxy = new WebProxy(proxyUrl);

        using var client = new HttpClient(handler);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        client.Timeout = TimeSpan.FromSeconds(60);

        Parallel.ForEach(remaining, new ParallelOptions { MaxDegreeOfParallelism = MaxWorkers }, file =>
        {
            var name = Path.GetFileName(file);
            var isText = false;
            try
            {
                isText = IsTextImage(client, file);
            }
            catch (Exception e)
            {
                Console.WriteLine($"  ERR: {name} ({e.Message})");
            }

            progressDict[name] = isText;
            var current = Interlocked.Increment(ref completed);
            if (isText)
            {
                var dest = Path.Combine(OutputDir, name);
                File.Copy(file, dest, true);
                CopyAct(file, dest);
                CopyMeta(file, dest);
                Interlocked.Increment(ref textCount);
            }
            Console.WriteLine($"[{current}/{remaining.Length}] {(isText ? "TEXT" : "  -")}: {name}");
            if (current % 10 == 0)
            {
                var snapshot = new Dictionary<string, bool>(progressDict);
                SaveProgress(snapshot);
            }
        });

        var finalProgress = new Dictionary<string, bool>(progressDict);
        SaveProgress(finalProgress);
        var finalText = finalProgress.Values.Count(v => v);
        Console.WriteLine($"\nDone. Text images found: {finalText}/{imageFiles.Length}");
    }

    private static bool IsTextImage(HttpClient client, string imagePath)
    {
        var imageBytes = File.ReadAllBytes(imagePath);
        var base64 = Convert.ToBase64String(imageBytes);

        var payload = new
        {
            model = Model,
            messages = new[]
            {
                new
                {
                    role = "user",
                    content = new object[]
                    {
                        new { type = "text", text = Prompt },
                        new { type = "image_url", image_url = new { url = $"data:image/gif;base64,{base64}" } }
                    }
                }
            },
            max_tokens = 5,
            temperature = 0
        };

        var json = JsonSerializer.Serialize(payload);

        Console.WriteLine($"  >> API: {Path.GetFileName(imagePath)}");

        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                var response = client.PostAsync(ApiUrl, content).GetAwaiter().GetResult();
                response.EnsureSuccessStatusCode();
                var responseText = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                using var doc = JsonDocument.Parse(responseText);
                var answer = doc.RootElement
                    .GetProperty("choices")[0]
                    .GetProperty("message")
                    .GetProperty("content")
                    .GetString() ?? "";
                return answer.Contains("YES", StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception)
            {
                if (attempt >= 2)
                    throw;
                Thread.Sleep((int)Math.Pow(2, attempt) * 1000);
            }
        }
        return false;
    }

    private static void CopyAct(string srcGif, string destGif)
    {
        var srcAct = Path.ChangeExtension(srcGif, ".act");
        var destAct = Path.ChangeExtension(destGif, ".act");
        if (File.Exists(srcAct))
            File.Copy(srcAct, destAct, true);
    }

    private static void CopyMeta(string srcGif, string destGif)
    {
        var srcMeta = srcGif + ".meta.json";
        var destMeta = destGif + ".meta.json";
        if (File.Exists(srcMeta))
            File.Copy(srcMeta, destMeta, true);
    }

    private static Dictionary<string, bool> LoadProgress()
    {
        try
        {
            if (File.Exists(ProgressFile))
            {
                var json = File.ReadAllText(ProgressFile);
                return JsonSerializer.Deserialize<Dictionary<string, bool>>(json) ?? new();
            }
        }
        catch
        {
        }
        return new();
    }

    private static void SaveProgress(Dictionary<string, bool> progress)
    {
        try
        {
            var dir = Path.GetDirectoryName(ProgressFile);
            if (dir != null)
                Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(progress, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(ProgressFile, json);
        }
        catch
        {
        }
    }
}
