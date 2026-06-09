using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

Color[] ParseCluts(byte[] subData, int offset, int clutW, int clutH)
{
    var colors = new List<Color>();
    for (var i = 0; i < clutW * clutH; i++)
    {
        var c = BitConverter.ToUInt16(subData, offset + i * 2);
        var r = c & 0x1F;
        var g = (c >> 5) & 0x1F;
        var b = (c >> 10) & 0x1F;
        var a = c == 0 ? 0 : 255;
        colors.Add(Color.FromArgb(a, r << 3, g << 3, b << 3));
    }
    return colors.ToArray();
}

Bitmap ParsePix(byte[] subData, int offset, int pixW, int pixH, Color[] cluts, bool bit4)
{
    pixW *= 2;
    var width = bit4 ? pixW * 2 : pixW;
    var height = pixH;
    var bitmap = new Bitmap(width, height, PixelFormat.Format8bppIndexed);

    var palette = bitmap.Palette;
    for (var i = 0; i < 256; i++)
        palette.Entries[i] = i < cluts.Length ? cluts[i] : cluts[0];
    bitmap.Palette = palette;

    var rect = new Rectangle(0, 0, width, height);
    var bmpData = bitmap.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format8bppIndexed);
    var pixels = new byte[bmpData.Stride * height];
    for (var y = 0; y < pixH; y++)
    {
        for (var x = 0; x < pixW; x++)
        {
            var index = subData[offset + y * pixW + x];
            if (bit4)
            {
                pixels[y * bmpData.Stride + x * 2] = (byte)(index & 0xF);
                pixels[y * bmpData.Stride + x * 2 + 1] = (byte)((index >> 4) & 0xF);
            }
            else
            {
                pixels[y * bmpData.Stride + x] = index;
            }
        }
    }
    Marshal.Copy(pixels, 0, bmpData.Scan0, pixels.Length);
    bitmap.UnlockBits(bmpData);

    return bitmap;
}

void Parse(byte[] subData, int offset, string filename)
{
    var bitmap = ParseTim(subData, offset ,false);
    var outDir = Path.Combine($"pic_output", "mapnames");
    Directory.CreateDirectory(outDir);
    bitmap.Save(Path.Combine(outDir, filename + ".gif"), ImageFormat.Gif);
}

Bitmap? ParseTim(byte[] subData, int offset, bool skipWhenOffsetZero = true)
{
    if (offset == 0 && skipWhenOffsetZero)
    {
        return null;
    }
    if (offset < 0 || offset + 16 > subData.Length)
        return null;

    var header = BitConverter.ToInt32(subData, offset);
    var clut = BitConverter.ToInt32(subData, offset + 4);
    var clutW = BitConverter.ToUInt16(subData, clut + offset);
    var clutH = BitConverter.ToUInt16(subData, clut + offset + 2);
    var pix = BitConverter.ToInt32(subData, offset + 8);
    var pixW = BitConverter.ToUInt16(subData, pix + offset);
    var pixH = BitConverter.ToUInt16(subData, pix + offset + 2);
    Console.WriteLine($"  TIM: {pixW}*{pixH} words, CLUT {clutW}*{clutH}");
    var cluts = ParseCluts(subData, offset + clut + 4, clutW, clutH);
    return ParsePix(subData, offset + pix + 4, pixW, pixH, cluts, clutW != 256);
}

ushort ReadU16(byte[] d, int off) => (ushort)(d[off] | (d[off + 1] << 8));

// PartRectBlock: uint32 count; PartRect rects[count];
// PartRect: byte U; byte V; byte W; byte H;
List<PartRect> ParsePartRects(byte[] dd, int blockBase)
{
    var rects = new List<PartRect>();
    if (blockBase + 4 > dd.Length) return rects;

    var count = BitConverter.ToUInt32(dd, blockBase);
    for (var i = 0; i < count && blockBase + 4 + (i + 1) * 4 <= dd.Length; i++)
    {
        var pos = blockBase + 4 + i * 4;
        rects.Add(new PartRect(dd[pos], dd[pos + 1], dd[pos + 2], dd[pos + 3]));
    }
    return rects;
}

// FrameDataBlock: uint32 count; uint16 frameDataOffsets[count];
// FrameData: uint8 partCount; uint8 reserved[3]; FramePart parts[partCount];
// FramePart: uint8 flags; uint8 rectIndex; uint8 localX; uint8 localY; uint32 attr; [+ uint16 scaleX; uint16 scaleY if flags&0x04]
List<FrameData> ParseFrameDataBlock(byte[] dd, int blockBase)
{
    var frameDataList = new List<FrameData>();
    if (blockBase + 4 > dd.Length) return frameDataList;

    var count = BitConverter.ToUInt32(dd, blockBase);
    var offsets = new List<int>();
    for (var i = 0; i < count && blockBase + 4 + (i + 1) * 2 <= dd.Length; i++)
        offsets.Add(ReadU16(dd, blockBase + 4 + i * 2));

    foreach (var off in offsets)
    {
        var fdBase = blockBase + off;
        if (fdBase + 4 > dd.Length) continue;

        var partCount = dd[fdBase];
        var parts = new List<FramePart>();
        var cursor = fdBase + 4;
        for (var p = 0; p < partCount && cursor + 8 <= dd.Length; p++)
        {
            var flags = dd[cursor];
            var rectIndex = dd[cursor + 1];
            var localX = dd[cursor + 2];
            var localY = dd[cursor + 3];
            var attr = BitConverter.ToUInt32(dd, cursor + 4);

            ushort? sx = null, sy = null;
            if ((flags & 0x04) != 0 && cursor + 12 <= dd.Length)
            {
                sx = ReadU16(dd, cursor + 8);
                sy = ReadU16(dd, cursor + 10);
                cursor += 12;
            }
            else
            {
                cursor += 8;
            }
            parts.Add(new FramePart(flags, rectIndex, localX, localY, attr, sx, sy));
        }
        frameDataList.Add(new FrameData(partCount, parts));
    }
    return frameDataList;
}

// AnimDataBlock: uint32 count; uint16 animOffsets[count];
// AnimFrameTable: uint16 frameCount; uint16 reserved; uint32 frameEntries[frameCount];
// frameEntry bitfields: fdIdx(7bit) | duration(6bit) | offsetX(signed 10bit) | offsetY(signed 9bit)
List<AnimData> ParseAnimDataBlock(byte[] dd, int blockBase)
{
    var anims = new List<AnimData>();
    if (blockBase + 4 > dd.Length) return anims;

    // AnimDataBlock: uint32 count; uint16 animOffsets[count];
    var count = BitConverter.ToUInt32(dd, blockBase);
    var offsets = new List<int>();
    for (var i = 0; i < count && blockBase + 4 + (i + 1) * 2 <= dd.Length; i++)
        offsets.Add(ReadU16(dd, blockBase + 4 + i * 2));

    foreach (var off in offsets)
    {
        // AnimFrameTable: uint16 frameCount; uint16 reserved; uint32 frameEntries[frameCount];
        var animBase = blockBase + off;
        if (animBase + 2 > dd.Length) continue;

        var frameCount = ReadU16(dd, animBase);
        var frames = new List<AnimFrameEntry>();
        for (var f = 0; f < frameCount && animBase + 4 + (f + 1) * 4 <= dd.Length; f++)
        {
            var entry = BitConverter.ToUInt32(dd, animBase + 4 + f * 4);
            var fdIdx = (int)(entry & 0x7f);
            var duration = (int)((entry >> 7) & 0x3f);
            var offsetX = (int)(entry << 9) >> 22;
            var offsetY = (int)(entry >> 23);
            frames.Add(new AnimFrameEntry(entry, fdIdx, duration, offsetX, offsetY));
        }
        anims.Add(new AnimData(frameCount, frames));
    }
    return anims;
}

/* AnimSpriteResourceBlob (SubContent2/3 格式):
 *   +0x00 uint32 flags
 *   +0x04 int32 animDataOffset  (blob内偏移)
 *   +0x08 int32 frameDataOffset (blob内偏移)
 *   +0x0C int32 partRectOffset  (blob内偏移)
 *   后面依次排列: animDataBlock, frameDataBlock, partRectBlock
 *   纹理引用通过 FramePart.Attr & 3 选择 SubContent0/1 */
(string? label, uint flags, List<AnimData> anims, List<FrameData> frameDatas, List<PartRect> rects)
    ParseAnimSpriteBlob(byte[] dd, int blobOff, string label)
{
    if (blobOff <= 0 || blobOff + 16 > dd.Length)
        return (null, 0, new(), new(), new());

    var flags = BitConverter.ToUInt32(dd, blobOff);
    var animOff = BitConverter.ToInt32(dd, blobOff + 4);
    var frameOff = BitConverter.ToInt32(dd, blobOff + 8);
    var partOff = BitConverter.ToInt32(dd, blobOff + 12);

    var animBase = blobOff + animOff;
    var frameBase = blobOff + frameOff;
    var partBase = blobOff + partOff;

    var rects = ParsePartRects(dd, partBase);
    var frameDatas = ParseFrameDataBlock(dd, frameBase);
    var anims = ParseAnimDataBlock(dd, animBase);

    return (label, flags, anims, frameDatas, rects);
}

void ExportSprite(Bitmap bmp, PartRect rect, int texIdx, string path)
{
    if (rect.U + rect.W > bmp.Width || rect.V + rect.H > bmp.Height)
        return;
    var area = new Rectangle(rect.U, rect.V, rect.W, rect.H);
    using var sprite = bmp.Clone(area, bmp.PixelFormat);
    sprite.Save(path);
}

var data = File.ReadAllBytes("rom/CM3000.DAT");
Console.WriteLine("=== Extracting character sprites (AnimSpriteResourceBlob) ===");

for (var i = 0; i < 0x44; ++i)
{
    var dd = ExtractUtil.GetSubcontent(data, 0x89 + i);

    // SubContent0/1 = TIM textures; SubContent2/3 = AnimSpriteResourceBlob
    var off0 = BitConverter.ToInt32(dd, 4);
    var off1 = BitConverter.ToInt32(dd, 8);
    var off2 = BitConverter.ToInt32(dd, 12);
    var off3 = BitConverter.ToInt32(dd, 16);

    Console.WriteLine($"\nchar{i}: off2=0x{off2:X} off3=0x{off3:X}");

    // Load texture bitmaps from SubContent0/1 (registered to texture slots 0x0B/0x0C)
    using var bmp0 = ParseTim(dd, off0);
    using var bmp1 = ParseTim(dd, off1);

    // Parse SubContent2 and SubContent3 as AnimSpriteResourceBlob
    foreach (var (label, subOff) in new[] { ("sub2", off2), ("sub3", off3) })
    {
        var (parsedLabel, flags, anims, frameDatas, rects) = ParseAnimSpriteBlob(dd, subOff, label);
        if (parsedLabel == null) continue;

        Console.WriteLine($"  {label}: flags=0x{flags:X} anims={anims.Count} frameDatas={frameDatas.Count} partRects={rects.Count}");

        // Traverse: anim -> frame -> part, extracting each part sprite
        for (var a = 0; a < anims.Count; a++)
        {
            var anim = anims[a];
            for (var f = 0; f < anim.Frames.Count; f++)
            {
                var frameEntry = anim.Frames[f];
                if (frameEntry.FrameDataIndex >= frameDatas.Count)
                {
                    Console.WriteLine($"    [WARN] anim{a} frame{f}: FrameDataIndex {frameEntry.FrameDataIndex} out of range (max {frameDatas.Count - 1})");
                    continue;
                }
                var fd = frameDatas[frameEntry.FrameDataIndex];

                for (var p = 0; p < fd.Parts.Count; p++)
                {
                    var part = fd.Parts[p];
                    if (part.RectIndex >= rects.Count)
                    {
                        Console.WriteLine($"    [WARN] anim{a} frame{f} part{p}: RectIndex {part.RectIndex} out of range (max {rects.Count - 1})");
                        continue;
                    }

                    var rect = rects[part.RectIndex];
                    var texIdx = (int)(part.Attr & 3);
                    var bmp = texIdx == 0 ? bmp0 : bmp1;
                    if (bmp == null) continue;

                    var outDir = Path.Combine($"pic_output/char{i}", label, $"anim{a}", $"frame{f}");
                    Directory.CreateDirectory(outDir);

                    var fname = $"part{p}_t{texIdx}_u{rect.U}_v{rect.V}_{rect.W}x{rect.H}.png";
                    var path = Path.Combine(outDir, fname);
                    if (!File.Exists(path))
                        ExportSprite(bmp, rect, texIdx, path);
                }
            }
        }
    }
}

for(var i = 3; i < 64; ++i) {
    var subContent = ExtractUtil.GetSubcontent(data, i);
    Console.WriteLine($"\nmapname{i}: offset=0x{BitConverter.ToInt32(subContent, 4):X} {subContent.Length} bytes");
    Parse(subContent, 0, $"mapname{i}");
}

Console.WriteLine("\nDone.");

record PartRect(byte U, byte V, byte W, byte H);
record FramePart(byte Flags, byte RectIndex, byte LocalX, byte LocalY, uint Attr, ushort? ScaleX, ushort? ScaleY);
record FrameData(byte PartCount, List<FramePart> Parts);
record AnimFrameEntry(uint RawEntry, int FrameDataIndex, int Duration, int OffsetX, int OffsetY);
record AnimData(ushort FrameCount, List<AnimFrameEntry> Frames);


