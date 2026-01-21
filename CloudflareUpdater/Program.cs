using System.Net.Http.Json;
using System.Net.NetworkInformation;
using System.Text.Json;
using System.Linq;

namespace CloudflareUpdater;

internal static class Program
{
    private const int PollSeconds = 30;
    private const int TtlSeconds = 60;

    private static async Task<int> Main(string[] args)
    {
        if (args[0] == "--help" || args.Length == 0)
        {
            Console.WriteLine("Cloudflare DNS updater");
            Console.WriteLine("Usage: dotnet run -- <hostname>");
            Console.WriteLine("Environment variables:");
            Console.WriteLine("  CLOUDFLARE_API_TOKEN  - Cloudflare API token with DNS edit permissions (required)");
            Console.WriteLine("  CLOUDFLARE_ZONE_ID    - Cloudflare Zone ID (optional; if not set, CLOUDFLARE_ZONE_NAME or guessed from hostname will be used)");
            Console.WriteLine("  CLOUDFLARE_ZONE_NAME  - Cloudflare Zone Name (optional; used if CLOUDFLARE_ZONE_ID is not set)");
            return 0;
        }

        var ignoredTerms = Environment.GetEnvironmentVariable("CFDDNS_IGNORED")
            ?.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        if (args[0] == "--check" || args.Length == 0)
        {
            try
            {
                var ip = GetLocalIPv4(ignoredTerms);
                Console.WriteLine(ip != null
                    ? $"Local IPv4 address: {ip}"
                    : "Could not determine local IPv4 address.");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"error: {ex.Message}");
                return 1;
            }
        }

        Console.WriteLine("Cloudflare DNS updater starting...");

        if (args.Length != 1)
        {
            Console.Error.WriteLine("usage: dotnet run -- <hostname>");
            return 1;
        }

        var hostname = args[0];
        var token = Environment.GetEnvironmentVariable("CLOUDFLARE_API_TOKEN");
        if (string.IsNullOrWhiteSpace(token))
        {
            Console.Error.WriteLine("error: CLOUDFLARE_API_TOKEN is not set");
            return 1;
        }

        var zoneIdEnv = Environment.GetEnvironmentVariable("CLOUDFLARE_ZONE_ID");
        var zoneNameEnv = Environment.GetEnvironmentVariable("CLOUDFLARE_ZONE_NAME");

        using var http = new HttpClient
        {
            BaseAddress = new Uri("https://api.cloudflare.com/client/v4/")
        };
        http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        try
        {
            var localIp = GetLocalIPv4(ignoredTerms) ?? throw new InvalidOperationException("could not determine local IPv4 address");
            var zoneId = string.IsNullOrWhiteSpace(zoneIdEnv)
                ? await FetchZoneIdAsync(http, zoneNameEnv ?? GuessZoneName(hostname))
                : zoneIdEnv;

            if (string.IsNullOrWhiteSpace(zoneId))
                throw new InvalidOperationException("could not resolve Cloudflare zone id");

            Console.WriteLine($"Using zone id: {zoneId}");

            var record = await FetchDnsRecordAsync(http, zoneId, hostname);
            if (record != null && record.Content == localIp)
            {
                Console.WriteLine($"Cloudflare DNS already set to {localIp}, no update on init.");
            }
            else
            {
                record = await UpsertRecordAsync(http, zoneId, hostname, localIp, record?.Id, record?.Proxied ?? false);
                Console.WriteLine(record != null
                    ? $"Updated {hostname} to {localIp} (init)."
                    : "Warning: record update returned no result.");
            }

            var previousLocal = localIp;
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(PollSeconds));
                var currentLocal = GetLocalIPv4(ignoredTerms);
                if (currentLocal == null)
                {
                    Console.Error.WriteLine("warning: could not determine local IPv4 address; retrying...");
                    continue;
                }

                if (currentLocal == previousLocal)
                {
                    continue;
                }

                var updated = await UpsertRecordAsync(http, zoneId, hostname, currentLocal, record?.Id, record?.Proxied ?? false);
                if (updated != null)
                {
                    record = updated;
                    Console.WriteLine($"IP changed: {previousLocal} -> {currentLocal}. Cloudflare updated.");
                }
                else
                {
                    Console.Error.WriteLine("warning: failed to update Cloudflare record");
                }

                previousLocal = currentLocal;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    private static string? GuessZoneName(string host)
    {
        var parts = host.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return parts.Length >= 2 ? $"{parts[^2]}.{parts[^1]}" : null;
    }

    private static string? GetLocalIPv4(string[]? ignoredTerms)
    {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()
                     .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback))
        {
            if (ignoredTerms != null && ignoredTerms.Any(term => ni.Description.Contains(term)))
                continue;

            var props = ni.GetIPProperties();
            if (props.GatewayAddresses.Count == 0)
                continue;

            var addr = props.UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork);

            if (addr != null)
                return addr.Address.ToString();
        }

        return null;
    }

    private static async Task<string?> FetchZoneIdAsync(HttpClient http, string? zoneName)
    {
        if (string.IsNullOrWhiteSpace(zoneName))
            return null;

        var response = await http.GetFromJsonAsync<JsonElement>($"zones?name={Uri.EscapeDataString(zoneName)}&status=active");
        if (!response.IsSuccess()) return null;

        if (!response.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Array || result.GetArrayLength() == 0)
            return null;

        return result[0].GetProperty("id").GetString();
    }

    private static async Task<DnsRecord?> FetchDnsRecordAsync(HttpClient http, string zoneId, string hostname)
    {
        var response = await http.GetFromJsonAsync<JsonElement>($"zones/{zoneId}/dns_records?type=A&name={Uri.EscapeDataString(hostname)}");
        if (!response.IsSuccess()) return null;

        if (!response.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Array || result.GetArrayLength() == 0)
            return null;

        var record = result[0];
        return new DnsRecord(
            record.GetProperty("id").GetString() ?? string.Empty,
            record.GetProperty("content").GetString() ?? string.Empty,
            record.TryGetProperty("proxied", out var proxied) && proxied.ValueKind == JsonValueKind.True
        );
    }

    private static async Task<DnsRecord?> UpsertRecordAsync(HttpClient http, string zoneId, string hostname, string content, string? recordId, bool proxied)
    {
        var payload = new
        {
            type = "A",
            name = hostname,
            content,
            ttl = TtlSeconds,
            proxied
        };

        HttpResponseMessage resp = recordId is { Length: > 0 }
            ? await http.PutAsJsonAsync($"zones/{zoneId}/dns_records/{recordId}", payload)
            : await http.PostAsJsonAsync($"zones/{zoneId}/dns_records", payload);

        var json = await resp.Content.ReadFromJsonAsync<JsonElement>();
        if (json.ValueKind == JsonValueKind.Undefined || !json.IsSuccess())
        {
            var err = json.GetErrors();
            Console.Error.WriteLine($"Cloudflare API error: {err ?? "unknown"}");
            return null;
        }

        if (!json.TryGetProperty("result", out var result))
            return null;

        var newId = result.GetProperty("id").GetString() ?? recordId ?? string.Empty;
        var proxiedValue = result.TryGetProperty("proxied", out var proxiedProp) && proxiedProp.ValueKind == JsonValueKind.True;
        return new DnsRecord(newId, content, proxiedValue);
    }
}

internal record DnsRecord(string Id, string Content, bool Proxied);

internal static class JsonExtensions
{
    public static bool IsSuccess(this JsonElement element) =>
        element.ValueKind != JsonValueKind.Undefined &&
        element.TryGetProperty("success", out var successProp) &&
        successProp.ValueKind == JsonValueKind.True;

    public static string? GetErrors(this JsonElement element)
    {
        if (element.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array && errors.GetArrayLength() > 0)
        {
            var messages = errors.EnumerateArray()
                .Select(e => e.TryGetProperty("message", out var msg) ? msg.GetString() : null)
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .ToArray();
            return messages.Length > 0 ? string.Join("; ", messages) : null;
        }
        return null;
    }
}
