using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

const string ApiKeyHeader = "x-api-key";

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase);
var databasePath = Environment.GetEnvironmentVariable("SQLITE_PATH") ?? "/data/assets.db";
var apiKey = Environment.GetEnvironmentVariable("ASSET_API_KEY");

if (!Guid.TryParse(apiKey, out _))
{
    throw new InvalidOperationException("ASSET_API_KEY must be a GUID.");
}

Directory.CreateDirectory(Path.GetDirectoryName(databasePath) ?? ".");
InitializeDatabase(databasePath);

var app = builder.Build();

app.Use(async (context, next) =>
{
    if (!context.Request.Headers.TryGetValue(ApiKeyHeader, out var suppliedKey)
        || !CryptographicOperations.FixedTimeEquals(
            System.Text.Encoding.UTF8.GetBytes(suppliedKey.ToString()),
            System.Text.Encoding.UTF8.GetBytes(apiKey!)))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsJsonAsync(new { error = "A valid x-api-key is required." });
        return;
    }

    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/assets", (string? q) =>
{
    using var connection = OpenConnection(databasePath);
    var command = connection.CreateCommand();
    command.CommandText = """
        SELECT asset_id, name, region, category
        FROM assets
        WHERE $query = ''
           OR asset_id LIKE $pattern
           OR name LIKE $pattern
           OR region LIKE $pattern
           OR category LIKE $pattern
        ORDER BY asset_id;
        """;
    var query = (q ?? string.Empty).Trim();
    command.Parameters.AddWithValue("$query", query);
    command.Parameters.AddWithValue("$pattern", $"%{query}%");
    return Results.Json(ReadAssets(command));
});

app.MapGet("/assets/search", (string? q) =>
{
    using var connection = OpenConnection(databasePath);
    var command = connection.CreateCommand();
    command.CommandText = """
        SELECT asset_id, name, region, category
        FROM assets
        WHERE $query = ''
           OR asset_id LIKE $pattern
           OR name LIKE $pattern
           OR region LIKE $pattern
           OR category LIKE $pattern
        ORDER BY asset_id;
        """;
    var query = (q ?? string.Empty).Trim();
    command.Parameters.AddWithValue("$query", query);
    command.Parameters.AddWithValue("$pattern", $"%{query}%");
    return Results.Json(ReadAssets(command));
});

app.MapGet("/assets/{assetId}", (string assetId) =>
{
    using var connection = OpenConnection(databasePath);
    var command = connection.CreateCommand();
    command.CommandText = """
        SELECT asset_id, name, region, category
        FROM assets
        WHERE asset_id = $assetId;
        """;
    command.Parameters.AddWithValue("$assetId", assetId);
    using var reader = command.ExecuteReader();
    return reader.Read()
        ? Results.Ok(new Asset(
            reader.GetString(0),
            reader.GetString(1),
            reader.GetString(2),
            reader.GetString(3),
            "sqlite"))
        : Results.NotFound(new { error = "Asset not found." });
});

app.Run();

static SqliteConnection OpenConnection(string databasePath)
{
    var connection = new SqliteConnection($"Data Source={databasePath}");
    connection.Open();
    return connection;
}

static List<Asset> ReadAssets(SqliteCommand command)
{
    using var reader = command.ExecuteReader();
    var assets = new List<Asset>();
    while (reader.Read())
    {
        assets.Add(new Asset(
            reader.GetString(0),
            reader.GetString(1),
            reader.GetString(2),
            reader.GetString(3),
            "sqlite"));
    }

    return assets;
}

static void InitializeDatabase(string databasePath)
{
    using var connection = OpenConnection(databasePath);
    using var command = connection.CreateCommand();
    command.CommandText = """
        CREATE TABLE IF NOT EXISTS assets (
            asset_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            region TEXT NOT NULL,
            category TEXT NOT NULL
        );
        """;
    command.ExecuteNonQuery();

    command.CommandText = "SELECT COUNT(*) FROM assets;";
    if (Convert.ToInt32(command.ExecuteScalar()) > 0)
    {
        return;
    }

    command.CommandText = """
        INSERT INTO assets (asset_id, name, region, category) VALUES
        ('AST-1001', 'Forklift A1', 'Seattle', 'Warehouse'),
        ('AST-1002', 'Conveyor C7', 'Seattle', 'Warehouse'),
        ('AST-2001', 'HVAC Roof Unit', 'Phoenix', 'Facility'),
        ('AST-3005', 'Inspection Drone', 'Austin', 'Field'),
        ('AST-4103', 'Packaging Robot', 'Dublin', 'Manufacturing');
        """;
    command.ExecuteNonQuery();
}

public sealed record Asset(string AssetId, string Name, string Region, string Category, string Source);
