using System.Text.Json;

namespace romhack_csharp;

public static class FontMapVerifier
{
    public static void Verify(string bigMapPath, string smallMapPath, IReadOnlyList<char> sharedChars)
    {
        var big = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(bigMapPath))
                  ?? throw new InvalidOperationException($"{bigMapPath} invalid");
        var small = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(smallMapPath))
                    ?? throw new InvalidOperationException($"{smallMapPath} invalid");

        var errors = new List<string>();

        foreach (var ch in sharedChars)
        {
            var cs = ch.ToString();
            var b = big.FirstOrDefault(p => p.Value == cs);
            var s = small.FirstOrDefault(p => p.Value == cs);
            if (b.Key == null || s.Key == null)
                errors.Add($"'{cs}' missing: big={(b.Key ?? "none")} small={(s.Key ?? "none")}");
            else if (b.Key != s.Key)
                errors.Add($"'{cs}' encoding mismatch: big={b.Key} small={s.Key}");
        }

        var overlap = big.Count(kv =>
            small.TryGetValue(kv.Key, out var sc) && sc != kv.Value);
        if (overlap > 0)
        {
            Console.WriteLine(
                $"FontMapVerifier: notice - {overlap} non-shared codes exist in both maps " +
                $"with different chars (expected: each font renders only its own streams)");
        }

        if (errors.Count > 0)
            throw new InvalidOperationException(
                $"Font map verification FAILED ({errors.Count}):\n" + string.Join("\n", errors));

        Console.WriteLine($"FontMapVerifier OK: {sharedChars.Count} shared chars consistent");
    }
}
