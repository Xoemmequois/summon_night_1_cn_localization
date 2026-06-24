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

    // Meta for the {flags,clut,image,tilemap} tilemap-atlas format (CM2000 0x2D-0x4D).
    // Stores atlas/tilemap grid dims so in-place write-back can re-pack and validate
    // against the atlas capacity (cols*rows) without crossing the sector boundary.
    public static void WriteTilemap(string gifPath, string datFile, int subContentId,
        int atlasCols, int atlasRows, int mapCols, int mapRows, int tileSize = 16)
    {
        var meta = new ImageMeta
        {
            DatFile = datFile,
            SubContentId = subContentId,
            SubSlotIndex = -1,
            Format = "tilemap",
            AtlasCols = atlasCols,
            AtlasRows = atlasRows,
            MapCols = mapCols,
            MapRows = mapRows,
            TileSize = tileSize
        };
        File.WriteAllText(gifPath + ".meta.json", JsonSerializer.Serialize(meta));
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

    // Tilemap-atlas format (CM2000 0x2D-0x4D). Format == "tilemap" routes write-back
    // to TilemapWriteBack instead of the TIM path.
    public string? Format { get; init; }
    public int? AtlasCols { get; init; }
    public int? AtlasRows { get; init; }
    public int? MapCols { get; init; }
    public int? MapRows { get; init; }
    public int? TileSize { get; init; }
}
