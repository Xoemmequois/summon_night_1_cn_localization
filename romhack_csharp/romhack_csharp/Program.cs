using System.Text.RegularExpressions;
using romhack_csharp;

internal static partial class Program
{
    private static readonly Dictionary<(int, int), string> Hash = new();
    private static readonly Dictionary<char, byte[]> Chars = new();
    private static byte[] _cm1100 = Array.Empty<byte>();
    private static int _charIndex;

    private static void Main()
    {
        LoadTranslations("out_translated.srt");
        Console.WriteLine($"Hash entries: {Hash.Count}");

        _cm1100 = File.ReadAllBytes(Path.Combine("rom", "CM1100.DAT"));
        ProcessDialogRange(1, 145);
        File.WriteAllBytes(Path.Combine("rom", "CM1100.DAT.mod2"), _cm1100);

        PrintChars();
        var count = CharCodeToIndex(Chars.MaxBy(pair => (ushort)((pair.Value[0] << 8) | pair.Value[1])).Value) + 1;
        var fontBitmaps = new byte[count * 28];
        Console.WriteLine($"Length {fontBitmaps.Length}");
        var fontBitmap = new byte[28];
        foreach (var pair in Chars)
        {
            var index = CharCodeToIndex(pair.Value);
            GenFontBitmap.GenerateFontBitmap(pair.Key, fontBitmap);
            Buffer.BlockCopy(fontBitmap, 0, fontBitmaps, index * 28, 28);
        }
        File.WriteAllBytes(Path.Combine("rom", "chinese.fnt"), fontBitmaps);
    }

    private static int CharCodeToIndex(byte[] arr)
    {
        if(arr[0] < 0x88)
        {
            return (arr[0] - 0x85) * 256 + arr[1];
        }
        return (arr[0] - 0x99) * 256 + arr[1] + 256 * 3;
    }

    private static void LoadTranslations(string srtPath)
    {
        var srtText = File.ReadAllText(srtPath);
        var items = SplitSrt().Split(srtText);
        foreach (var item in items)
        {
            if (string.IsNullOrWhiteSpace(item))
            {
                continue;
            }

            if (!TryParseSrtBlock(item, out var key, out var text))
            {
                continue;
            }

            Hash[key] = text;
        }
    }

    private static bool TryParseSrtBlock(string block, out (int StartMsec, int EndMsec) key, out string text)
    {
        key = default;
        text = string.Empty;

        var lines = block.Split(["\r\n", "\r", "\n"], StringSplitOptions.None);
        if (lines.Length < 2)
        {
            return false;
        }

        var timeLine = lines[1];
        var match = TimeExtract().Match(timeLine);
        if (!match.Success)
        {
            return false;
        }

        var startHour = int.Parse(match.Groups[1].Value);
        if (startHour == 0)
        {
            return false;
        }

        var startMsec = int.Parse(match.Groups[4].Value);
        var endMsec = int.Parse(match.Groups[8].Value);
        key = (startMsec, endMsec);
        text = string.Join("\n", lines, 2, lines.Length - 2).Trim();
        return true;
    }

    private static void ProcessDialogRange(int startId, int endId)
    {
        for (var i = startId; i <= endId; i++)
        {
            ConvertDialogContents(i);
        }
    }

    private static void PrintChars()
    {
        Console.WriteLine("Chars:");
        foreach (var kvp in Chars)
        {
            var bytes = kvp.Value;
            Console.WriteLine($"{kvp.Key} => {bytes[0]:X2} {bytes[1]:X2}");
        }
    }

    private static byte[] GetNextCharId()
    {
        if (_charIndex >= 2560)
        {
            throw new InvalidOperationException("too much characters");
        }

        var c = _charIndex;
        _charIndex += 1;
        if (c < 256 * 3)
        {
            return new[] { (byte)(c / 256 + 0x85), (byte)(c % 256) };
        }

        c -= 256 * 3;
        return new[] { (byte)(c / 256 + 0x99), (byte)(c % 256) };
    }

    private static byte[] GetSubcontent(int id, out int contentStart, out int contentLen)
    {
        var baseOffset = 0x10 + id * 4;
        var offset = ReadUShort(_cm1100, baseOffset);
        var len = ReadUShort(_cm1100, baseOffset + 2);
        contentStart = offset * 0x800;
        contentLen = len * 0x800;
        var contents = new byte[contentLen];
        Buffer.BlockCopy(_cm1100, contentStart, contents, 0, contentLen);
        return contents;
    }

    private static void ConvertDialogContents(int id)
    {
        var contents = GetSubcontent(id + 0x29, out var contentStart, out var contentLen);
        var len = ReadUShort(contents, 0);
        var indices = new ushort[len];
        for (var i = 0; i < len; i++)
        {
            indices[i] = ReadUShort(contents, i * 2);
        }

        var strs = new List<byte[]>();

        for (var i = 0; i < indices.Length; i++)
        {
            var start = indices[i];
            var str = new List<byte>();
            var index = 0;
            while (true)
            {
                var b0 = contents[start * 2 + index];
                var b1 = contents[start * 2 + index + 1];
                if (b0 == 0x00 && b1 == 0x00)
                {
                    break;
                }

                str.Add(b0);
                str.Add(b1);
                index += 2;
            }

            if (Hash.TryGetValue((id, i), out var replacement))
            {
                str.Clear();
                foreach (var ch in replacement)
                {
                    if (ch == '@')
                    {
                        str.Add(0x40);
                        str.Add(0x00);
                        continue;
                    }

                    if (ch == 'n')
                    {
                        str.Add(0x6E);
                        str.Add(0x00);
                        continue;
                    }

                    if (!Chars.TryGetValue(ch, out var mapped))
                    {
                        mapped = GetNextCharId();
                        Chars[ch] = mapped;
                    }

                    str.Add(mapped[0]);
                    str.Add(mapped[1]);
                }
            }

            strs.Add(str.ToArray());
        }

        var strStart = indices[0];
        var newContents = new List<byte>();
        foreach (var str in strs)
        {
            newContents.AddRange(PackUShort(strStart));
            strStart += (ushort)(str.Length / 2 + 1);
        }

        foreach (var str in strs)
        {
            newContents.AddRange(str);
            newContents.Add(0x00);
            newContents.Add(0x00);
        }

        if (newContents.Count > contentLen)
        {
            throw new InvalidOperationException($"new content has larger size {id}");
        }

        while (newContents.Count < contentLen)
        {
            newContents.Add(0x00);
        }
        
        Buffer.BlockCopy(newContents.ToArray(), 0, _cm1100, contentStart, newContents.Count);
    }

    private static ushort ReadUShort(byte[] data, int offset)
    {
        return (ushort)(data[offset] | (data[offset + 1] << 8));
    }

    private static byte[] PackUShort(ushort value)
    {
        return new[] { (byte)(value & 0xFF), (byte)((value >> 8) & 0xFF) };
    }

    [GeneratedRegex(@"\r?\n\r?\n")]
    private static partial Regex SplitSrt();
    [GeneratedRegex(@"(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2}):(\d{2}):(\d{2}),(\d{3})")]
    private static partial Regex TimeExtract();
}
