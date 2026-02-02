using System.Text.Json;

namespace romhack_csharp;

public sealed class Config
{
    public string SdkPath { get; init; } = string.Empty;
    public string GamePath { get; init; } = string.Empty;
    public List<int> ValidStage { get; init; } = new();

    public static Config Load(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Config file not found: {path}");
        }

        var text = File.ReadAllText(path);
        var config = JsonSerializer.Deserialize<Config>(
            text,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        if (config == null)
        {
            throw new InvalidOperationException("Failed to parse config file.");
        }

        if (string.IsNullOrWhiteSpace(config.SdkPath))
        {
            throw new InvalidOperationException("SDKPath is missing in config file.");
        }

        if (string.IsNullOrWhiteSpace(config.GamePath))
        {
            throw new InvalidOperationException("GamePath is missing in config file.");
        }

        return config;
    }
}
