namespace romhack_csharp;

public class CodeModifier
{
    public static void ModifyCode(uint newFontFuncAddr, int fontBinaryLen)
    {
        var codes = File.ReadAllBytes("rom/SLPS_025.42");
        var loadBin = ExtraCodeBuilder.GetLoadCodeBinary((fontBinaryLen + 4095) / 4096);
        if (loadBin.Length >= 0x54)
        {
            throw new ApplicationException("load.bin size is too large, should be less than 0x54");
        }
        Buffer.BlockCopy(loadBin, 0, codes, 0x85EFC, loadBin.Length);
        JalCodeModifier.ModifyCode(codes, 0x80030C48u, 0x800956FCu);
        JalCodeModifier.ModifyCode(codes, 0x80036738u, newFontFuncAddr);
        File.WriteAllBytes("rom/SLPS_025.42.mod2", codes);
    }
}