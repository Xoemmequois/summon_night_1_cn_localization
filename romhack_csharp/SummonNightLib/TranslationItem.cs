using System.Text.Json.Serialization;

namespace SummonNightLib;

public class TranslationItem
{
    [JsonPropertyName("key")]
    public string Key { get; set; } = "";
    [JsonPropertyName("original")]
    public string Original { get; set; } = "";
    [JsonPropertyName("translation")]
    public string Translation { get; set; } = "";
    [JsonPropertyName("stage")]
    public int Stage { get; set; }
}
