using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using SummonNightLib;

public static class TimPixelHelper
{
    public record TimPixelData(
        byte[] PixelIndices,
        int Stride,
        int PixBytesPerRow,
        int PixH,
        bool Bit4,
        Color[] Cluts,
        int RawPixDataOffset,
        int RawTotalPixBytes);

    public static TimPixelData ParseTim(byte[] datBuffer, ImageMeta meta)
    {
        var sectorOffset = ExtractUtil.ReadUShort(datBuffer, 0x10 + meta.SubContentId * 4);
        var subContentStart = sectorOffset * 0x800;

        int timOffset;
        if (meta.SubSlotIndex == -1)
        {
            timOffset = subContentStart;
        }
        else
        {
            var subData = ExtractUtil.GetSubcontent(datBuffer, meta.SubContentId);
            var slotOff = GetSubContentOffset(subData, meta.SubSlotIndex, out _);
            timOffset = subContentStart + slotOff;
        }

        var clut = BitConverter.ToInt32(datBuffer, timOffset + 4);
        var clutW = BitConverter.ToUInt16(datBuffer, timOffset + clut);
        var clutH = BitConverter.ToUInt16(datBuffer, timOffset + clut + 2);
        var bit4 = clutW != 256;
        var clutCount = clutW * clutH;
        var clutOffset = timOffset + clut + 4;

        var cluts = new Color[clutCount];
        for (var i = 0; i < clutCount; i++)
        {
            var c = BitConverter.ToUInt16(datBuffer, clutOffset + i * 2);
            var r = c & 0x1F;
            var g = (c >> 5) & 0x1F;
            var b = (c >> 10) & 0x1F;
            cluts[i] = Color.FromArgb(i == 0 ? 0 : 255, r << 3, g << 3, b << 3);
        }

        var pix = BitConverter.ToInt32(datBuffer, timOffset + 8);
        var pixW = BitConverter.ToUInt16(datBuffer, timOffset + pix);
        var pixH = BitConverter.ToUInt16(datBuffer, timOffset + pix + 2);
        var rawPixDataOffset = timOffset + pix + 4;
        var pixBytesPerRow = pixW * 2;
        var rawTotalPixBytes = pixBytesPerRow * pixH;

        var width = bit4 ? pixBytesPerRow * 2 : pixBytesPerRow;
        var pixelIndices = new byte[width * pixH];
        var stride = width;

        for (var y = 0; y < pixH; y++)
        {
            for (var x = 0; x < pixBytesPerRow; x++)
            {
                var raw = datBuffer[rawPixDataOffset + y * pixBytesPerRow + x];
                if (bit4)
                {
                    pixelIndices[y * stride + x * 2] = (byte)(raw & 0xF);
                    pixelIndices[y * stride + x * 2 + 1] = (byte)((raw >> 4) & 0xF);
                }
                else
                {
                    pixelIndices[y * stride + x] = raw;
                }
            }
        }

        return new TimPixelData(pixelIndices, stride, pixBytesPerRow, pixH, bit4, cluts,
            rawPixDataOffset, rawTotalPixBytes);
    }

    public static byte[] PackToRaw(TimPixelData tim, byte[] pixelIndices)
    {
        var raw = new byte[tim.RawTotalPixBytes];
        for (var y = 0; y < tim.PixH; y++)
        {
            for (var x = 0; x < tim.PixBytesPerRow; x++)
            {
                if (tim.Bit4)
                {
                    var lo = pixelIndices[y * tim.Stride + x * 2] & 0xF;
                    var hi = pixelIndices[y * tim.Stride + x * 2 + 1] & 0xF;
                    raw[y * tim.PixBytesPerRow + x] = (byte)(lo | (hi << 4));
                }
                else
                {
                    raw[y * tim.PixBytesPerRow + x] = pixelIndices[y * tim.Stride + x];
                }
            }
        }
        return raw;
    }

    private static int GetSubContentOffset(byte[] dd, int index, out int size)
    {
        var cur = BitConverter.ToInt32(dd, 4 + index * 4) & 0xFFFFFF;
        if (cur == 0)
        {
            size = 0;
            return 0;
        }

        var entryCount = (ushort)(dd[0] | (dd[1] << 8));
        var next = index + 1;
        while (next < entryCount)
        {
            var nextOff = BitConverter.ToInt32(dd, 4 + next * 4) & 0xFFFFFF;
            if (nextOff != 0)
            {
                size = nextOff - cur;
                return cur;
            }
            next++;
        }

        size = dd.Length - cur;
        return cur;
    }
}
