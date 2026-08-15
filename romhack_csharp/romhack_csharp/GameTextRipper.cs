using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SummonNightLib;

namespace romhack_csharp;

public class GameTextRipper(Config config)
{
    private byte[] _cm1100 = Array.Empty<byte>();

    public void Rip()
    {
        var romDir = Path.Combine(Directory.GetCurrentDirectory(), "rom");

        if (!Directory.Exists(romDir))
        {
            Directory.CreateDirectory(romDir);
        }

        if (!File.Exists(Path.Combine(romDir, "CM1100.DAT")))
        {
            CommandRunner.RunCommand(Path.Combine(config.SdkPath, "bin", "dumpsxiso"), $"\"{config.GamePath}\" -x \"{romDir}\"");
        }

        _cm1100 = File.ReadAllBytes(Path.Combine(romDir, "CM1100.DAT"));

        var result = new List<ParatranzItem>();

        for (var id = 1; id <= 145; id++)
        {
            var strs = ParseDialogContents(id);
            for (var i = 0; i < strs.Count; i++)
            {
                var str = strs[i];
                if (string.IsNullOrEmpty(str)) continue;

                result.Add(new ParatranzItem
                {
                    Key = $"{id:D4}-{i:D4}",
                    Original = str,
                    Translation = ""
                });
            }
        }

        var jsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        File.WriteAllText("zh_CN.json", JsonSerializer.Serialize(result, jsonOptions));
    }

    private List<string> ParseDialogContents(int id)
    {
        var contents = ExtractUtil.GetSubcontent(_cm1100, id + 0x29);
        var len = ExtractUtil.ReadUShort(contents, 0);
        var indices = new ushort[len];
        for (int i = 0; i < len; i++)
        {
            indices[i] = ExtractUtil.ReadUShort(contents, i * 2);
        }

        var strs = new List<string>();
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var sjis = Encoding.GetEncoding("shift_jis");

        foreach (var start in indices)
        {
            var strBytes = new List<byte>();
            int index = 0;
            while (true)
            {
                if (start * 2 + index + 1 >= contents.Length) break;
                byte b0 = contents[start * 2 + index];
                byte b1 = contents[start * 2 + index + 1];
                if (b0 == 0 && b1 == 0) break;

                // @ control char spans 3 units (6 bytes): 0x4000, param1, param2.
                // "@n" is stored as 40 00 6E 00 00 00 — the trailing 00 00 is a
                // control param, NOT the string terminator. Compress to \x40\x6E
                // and keep reading so the following text is not dropped.
                if (b0 == 0x40 && b1 == 0x00)
                {
                    strBytes.Add(0x40);
                    if (start * 2 + index + 3 < contents.Length &&
                        contents[start * 2 + index + 2] == 0x6E &&
                        contents[start * 2 + index + 3] == 0x00)
                    {
                        strBytes.Add(0x6E);
                    }
                    index += 6;
                    continue;
                }

                strBytes.Add(b0);
                strBytes.Add(b1);
                index += 2;
            }

            var decoded = sjis.GetString(strBytes.ToArray());
            strs.Add(decoded);
        }

        return strs;
    }

    public class ParatranzItem
    {
        public string key { get; set; } = "";
        public string original { get; set; } = "";
        public string translation { get; set; } = "";

        [JsonIgnore]
        public string Key { get => key; set => key = value; }
        [JsonIgnore]
        public string Original { get => original; set => original = value; }
        [JsonIgnore]
        public string Translation { get => translation; set => translation = value; }
    }
}