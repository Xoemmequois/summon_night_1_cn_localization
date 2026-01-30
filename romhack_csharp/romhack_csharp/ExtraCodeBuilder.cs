using System;
using System.Diagnostics;
using System.IO;

namespace romhack_csharp;

public class ExtraCodeBuilder
{
    const string SdkPath = @"G:\hob\PSn00bSDK-0.24-win32\";

    public static byte[] GetLoadCodeBinary(int loadCount)
    {
        return CompileCode("load", $"-Wa,--defsym,LOAD_COUNT={loadCount}");
    }

    private static byte[] CompileCode(string name, string extraFlags = "")
    {
        var outputDir = Path.Combine(Directory.GetCurrentDirectory(), "output");

        if (!Directory.Exists(outputDir))
        {
            Directory.CreateDirectory(outputDir);
        }

        var gccPath = Path.Combine(SdkPath, "bin", "mipsel-none-elf-gcc.exe");
        var objcopyPath = Path.Combine(SdkPath, "bin", "mipsel-none-elf-objcopy.exe");
        var fontObj = Path.Combine(outputDir, $"{name}.o");
        var fontBin = Path.Combine(outputDir, $"{name}.bin");

        RunCommand(gccPath, $"-c {extraFlags} -EL {name}.s -o \"{fontObj}\"");
        RunCommand(objcopyPath, $"-R .MIPS.abiflags -O binary \"{fontObj}\" \"{fontBin}\"");

        return File.ReadAllBytes(fontBin);
    }
    
    public static byte[] GetFontCodeBinary()
    {
        return CompileCode("font");
    }

    private static void RunCommand(string fileName, string arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };

        using var process = Process.Start(startInfo);
        if (process == null)
        {
            throw new InvalidOperationException($"Failed to start process: {fileName}");
        }

        var stdOut = process.StandardOutput.ReadToEnd();
        var stdErr = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            var message = $"Command failed with exit code {process.ExitCode}: {fileName} {arguments}";
            if (!string.IsNullOrWhiteSpace(stdOut))
            {
                message += Environment.NewLine + stdOut.TrimEnd();
            }

            if (!string.IsNullOrWhiteSpace(stdErr))
            {
                message += Environment.NewLine + stdErr.TrimEnd();
            }

            throw new InvalidOperationException(message);
        }
    }
}
