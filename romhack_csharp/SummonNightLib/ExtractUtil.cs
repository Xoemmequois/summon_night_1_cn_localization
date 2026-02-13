namespace SummonNightLib;

public static class ExtractUtil
{
    public static byte[] GetSubcontent(byte[] data, int id)
    {
        var baseOffset = 0x10 + id * 4;
        var offset = ReadUShort(data, baseOffset);
        var len = ReadUShort(data, baseOffset + 2);
        var contentStart = offset * 0x800;
        var contentLen = len * 0x800;
        var contents = new byte[contentLen];
        Buffer.BlockCopy(data, contentStart, contents, 0, contentLen);
        return contents;
    }

    public static ushort ReadUShort(byte[] data, int offset)
    {
        return (ushort)(data[offset] | (data[offset + 1] << 8));
    }
}
