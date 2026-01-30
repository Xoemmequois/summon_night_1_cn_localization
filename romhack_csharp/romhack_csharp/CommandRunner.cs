using System.Diagnostics;

namespace romhack_csharp;

public static class CommandRunner
{
    public static void RunCommand(string fileName, string arguments)
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