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

        RunCommand(gccPath, $"-c {extraFlags} -EL {name}.s -o \"{fontObj}\"");
        RunCommand(objcopyPath, $"-R .MIPS.abiflags -O binary \"{fontObj}\" \"{fontBin}\"");

        return File.ReadAllBytes(fontBin);
    }
    
    public static byte[] GetFontCodeBinary(string sdkPath)
    {
        return CompileCode("font", sdkPath);
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
