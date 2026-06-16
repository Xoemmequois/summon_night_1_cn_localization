using System.Text.Json;

public static class ImageMetaWriter
{
    public static void Write(string gifPath, string datFile, int subContentId, int subSlotIndex,
        int? rectU = null, int? rectV = null, int? rectW = null, int? rectH = null)
    {
        var meta = new ImageMeta
        {
            DatFile = datFile,
            SubContentId = subContentId,
            SubSlotIndex = subSlotIndex,
            RectU = rectU,
            RectV = rectV,
            RectW = rectW,
            RectH = rectH
        };
        var metaPath = gifPath + ".meta.json";
        File.WriteAllText(metaPath, JsonSerializer.Serialize(meta));
    }
}

public record ImageMeta
{
    public string DatFile { get; init; } = "";
    public int SubContentId { get; init; }
    public int SubSlotIndex { get; init; }
    public int? RectU { get; init; }
    public int? RectV { get; init; }
    public int? RectW { get; init; }
    public int? RectH { get; init; }
}
