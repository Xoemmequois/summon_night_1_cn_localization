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

    public static void WriteRawTim(string gifPath, string datFile, int subContentId, int timBase)
    {
        var meta = new ImageMeta
        {
            DatFile = datFile,
            SubContentId = subContentId,
            SubSlotIndex = -2,
            TimBase = timBase
        };
        File.WriteAllText(gifPath + ".meta.json", JsonSerializer.Serialize(meta));
    }

    // Meta for the {flags,clut,image,tilemap} tilemap-atlas format (CM2000 0x2D-0x4D).
    // Stores atlas/tilemap grid dims so in-place write-back can re-pack and validate
    // against the atlas capacity (cols*rows) without crossing the sector boundary.
    public static void WriteTilemap(string gifPath, string datFile, int subContentId,
        int atlasCols, int atlasRows, int mapCols, int mapRows, int tileSize = 16,
        int? baseOffset = null)
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
            TileSize = tileSize,
            BaseOffset = baseOffset
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

    // Direct TIM base offset inside subcontent (for non-slot TIMs like battle_prepare_ui: SubSlotIndex==-2 -> offset 0xB60)
    public int? TimBase { get; init; }

    // Offset of the {flags,clut,image,tilemap} encapsulation inside the subcontent.
    // Null/0 = encapsulation at subcontent start (chapter titles). Non-zero for
    // multi-image containers (e.g. CM2000 0x17 SCP container, block+0xF10...).
    public int? BaseOffset { get; init; }
}
