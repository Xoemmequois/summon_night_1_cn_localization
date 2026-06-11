using System.Drawing;
using System.Text.RegularExpressions;

public static class CharNameDedup
{
    private const string CharNamesDir = "pic_output/char_names";
    private static readonly Regex Pattern = new(@"^char_(\d+)_(sub[23])_part_\d+\.gif$");

    public static void Run()
    {
        if (!Directory.Exists(CharNamesDir))
        {
            Console.WriteLine("char_names directory not found, skipping dedup.");
            return;
        }

        Console.WriteLine("\n=== Deduplicating character name images ===");

        var files = Directory.GetFiles(CharNamesDir, "*.gif")
            .OrderBy(f => f).ToArray();
        if (files.Length == 0)
        {
            Console.WriteLine("No files found.");
            return;
        }

        var groups = new Dictionary<string, List<(string Path, int W, int H)>>();
        foreach (var f in files)
        {
            var name = Path.GetFileName(f);
            var m = Pattern.Match(name);
            if (!m.Success)
            {
                Console.WriteLine($"  SKIP: {name}");
                continue;
            }

            var charId = m.Groups[1].Value;
            using var img = new Bitmap(f);
            var w = img.Width;
            var h = img.Height;

            if (!groups.TryGetValue(charId, out var list))
            {
                list = new();
                groups[charId] = list;
            }
            list.Add((f, w, h));
        }

        var kept = 0;
        var deleted = 0;
        var singles = 0;
        var errors = new List<string>();

        foreach (var (charId, items) in groups.OrderBy(kv => int.Parse(kv.Key)))
        {
            items.Sort((a, b) =>
            {
                var areaCmp = (b.W * b.H).CompareTo(a.W * a.H);
                if (areaCmp != 0) return areaCmp;
                return string.Compare(Path.GetFileName(a.Path), Path.GetFileName(b.Path), StringComparison.Ordinal);
            });

            if (items.Count == 1)
            {
                singles++;
                continue;
            }

            var best = items[0];
            for (var i = 1; i < items.Count; i++)
            {
                var other = items[i];
                var result = Compare(best.Path, best.W, best.H, other.Path, other.W, other.H);
                if (result == 0)
                {
                    Console.WriteLine($"  {Path.GetFileName(other.Path)} -> DEL (keep {Path.GetFileName(best.Path)})");
                    File.Delete(other.Path);
                    DeleteAct(other.Path);
                    deleted++;
                }
                else if (result == 1)
                {
                    Console.WriteLine($"  {Path.GetFileName(best.Path)} -> DEL (keep {Path.GetFileName(other.Path)})");
                    File.Delete(best.Path);
                    DeleteAct(best.Path);
                    deleted++;
                    kept--;
                    best = other;
                }
                else
                {
                    var msg = $"  AMBIGUOUS char_{charId}: {Path.GetFileNameWithoutExtension(best.Path)}={best.W}x{best.H} vs {Path.GetFileNameWithoutExtension(other.Path)}={other.W}x{other.H}";
                    Console.WriteLine(msg);
                    errors.Add(msg);
                }
            }
            kept++;
        }

        Console.WriteLine($"\nKept: {kept}, Deleted: {deleted}, Singles: {singles}");
        if (errors.Count > 0)
        {
            Console.WriteLine($"Errors ({errors.Count}):");
            foreach (var e in errors)
                Console.WriteLine(e);
        }
    }

    private static int Compare(string fa, int wa, int ha, string fb, int wb, int hb)
    {
        if (wa > wb && ha > hb) return 0;
        if (wb > wa && hb > ha) return 1;
        if (wa == wb && ha == hb) return 0;
        if (wa == wb) return ha > hb ? 0 : 1;
        if (ha == hb) return wa > wb ? 0 : 1;
        return -1;
    }

    private static void DeleteAct(string gifPath)
    {
        var actPath = Path.ChangeExtension(gifPath, ".act");
        if (File.Exists(actPath))
            File.Delete(actPath);
    }
}
