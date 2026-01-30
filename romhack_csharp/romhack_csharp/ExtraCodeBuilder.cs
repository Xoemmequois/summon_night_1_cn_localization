using System.Diagnostics;

namespace romhack_csharp;

public class ExtraCodeBuilder
{
    public static byte[] GetLoadCodeBinary(int loadCount, string sdkPath)
    {
        return CompileCode("load", sdkPath, $"-Wa,--defsym,LOAD_COUNT={loadCount}");
    }

    private static byte[] CompileCode(string name, string sdkPath, string extraFlags = "")
    {
        if (string.IsNullOrWhiteSpace(sdkPath))
        {
            throw new ArgumentException("SDK path is empty.", nameof(sdkPath));
        }

        var outputDir = Path.Combine(Directory.GetCurrentDirectory(), "output");

        if (!Directory.Exists(outputDir))
        {
            Directory.CreateDirectory(outputDir);
        }

        var gccPath = Path.Combine(sdkPath, "bin", "mipsel-none-elf-gcc.exe");
        var objcopyPath = Path.Combine(sdkPath, "bin", "mipsel-none-elf-objcopy.exe");
        var fontObj = Path.Combine(outputDir, $"{name}.o");
        var fontBin = Path.Combine(outputDir, $"{name}.bin");

        CommandRunner.RunCommand(gccPath, $"-c {extraFlags} -EL {name}.s -o \"{fontObj}\"");
        CommandRunner.RunCommand(objcopyPath, $"-R .MIPS.abiflags -O binary \"{fontObj}\" \"{fontBin}\"");

        return File.ReadAllBytes(fontBin);
    }
    
    public static byte[] GetFontCodeBinary(string sdkPath)
    {
        return CompileCode("font", sdkPath);
    }
}
