using System.Net;
using System.Text.Json;
using System.Collections.Concurrent;
using Azure;
using Azure.Data.Tables;
using Azure.Identity;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient();

var app = builder.Build();
var logger = app.Logger;

var commentsTableName = Environment.GetEnvironmentVariable("ASSET_COMMENTS_TABLE") ?? "assetcomments";
var ticketsTableName = Environment.GetEnvironmentVariable("ASSET_TICKETS_TABLE") ?? "assettickets";

var tableServiceClient = BuildTableServiceClient();
var commentsTable = tableServiceClient.GetTableClient(commentsTableName);
var ticketsTable = tableServiceClient.GetTableClient(ticketsTableName);
var inMemoryComments = new ConcurrentDictionary<string, List<ActivityRow>>();
var inMemoryTickets = new ConcurrentDictionary<string, List<ActivityRow>>();
var mission = new MissionRuntimeState();

void AddMissionEvent(string severity, string category, string message)
{
    mission.Events.Enqueue(new MissionEvent(DateTimeOffset.UtcNow.ToString("O"), severity, category, message));
    while (mission.Events.Count > 40 && mission.Events.TryDequeue(out _))
    {
    }
}

try
{
    await commentsTable.CreateIfNotExistsAsync();
    await ticketsTable.CreateIfNotExistsAsync();
    mission.TableInitialization = "ready";
    AddMissionEvent("success", "storage", "Table initialization succeeded.");
}
catch (Exception ex)
{
    logger.LogWarning(ex, "Table initialization failed. API calls may fail until table access is available.");
    mission.TableInitialization = "failed";
    mission.LastError = "Table initialization failed.";
    AddMissionEvent("warning", "storage", "Table initialization failed, in-memory fallback may be used.");
}

app.MapGet("/health", () => Results.Text("ok", "text/plain"));

app.MapGet("/", () => Results.Content(GetHtmlPage(), "text/html"));
app.MapGet("/mission-control", () => Results.Content(GetMissionControlPage(), "text/html"));

app.MapGet("/api/assets/search", async (string? q, IHttpClientFactory httpClientFactory, CancellationToken cancellationToken) =>
{
    var assets = await SearchAssetsAsync(q, httpClientFactory, cancellationToken);
    return Results.Json(new
    {
        stage = Environment.GetEnvironmentVariable("APP_SECURITY_STAGE") ?? "start",
        query = q ?? string.Empty,
        count = assets.Count,
        assets
    });
});

app.MapGet("/api/mission-control", () =>
{
    var stage = Environment.GetEnvironmentVariable("APP_SECURITY_STAGE") ?? "start";
    var storageConnectionString = Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING");
    var storageTablesUri = Environment.GetEnvironmentVariable("STORAGE_TABLES_URI");
    var apiKeyValue = Environment.GetEnvironmentVariable("ASSET_SERVICE_API_KEY");
    var apiKeySource = string.IsNullOrWhiteSpace(apiKeyValue)
        ? "missing"
        : apiKeyValue.StartsWith("@Microsoft.KeyVault(", StringComparison.OrdinalIgnoreCase)
            ? "key-vault-reference"
            : "app-setting-plain-text";

    var networkProfile = stage switch
    {
        "final" => "private-networking",
        "step1" => "public-endpoints-with-managed-identity",
        _ => "public-endpoints"
    };

    return Results.Json(new
    {
        stage,
        networkProfile,
        storageAuthMode = !string.IsNullOrWhiteSpace(storageConnectionString)
            ? "connection-string"
            : (!string.IsNullOrWhiteSpace(storageTablesUri) ? "managed-identity" : "unconfigured"),
        apiKeySource,
        tableInitialization = mission.TableInitialization,
        lastStorageMode = mission.LastStorageMode,
        reads = mission.Reads,
        writes = mission.Writes,
        fallbackReads = mission.FallbackReads,
        fallbackWrites = mission.FallbackWrites,
        inMemoryCommentCount = inMemoryComments.Sum(pair => pair.Value.Count),
        inMemoryTicketCount = inMemoryTickets.Sum(pair => pair.Value.Count),
        lastError = mission.LastError,
        events = mission.Events.ToArray()
    });
});

app.MapGet("/api/assets/{assetId}/activity", async (string assetId, CancellationToken cancellationToken) =>
{
    try
    {
        var comments = await ReadEntitiesAsync(commentsTable, assetId, cancellationToken);
        var tickets = await ReadEntitiesAsync(ticketsTable, assetId, cancellationToken);
        Interlocked.Increment(ref mission.Reads);
        mission.LastStorageMode = "table-storage";

        return Results.Json(new
        {
            assetId,
            storageMode = "table-storage",
            comments,
            tickets
        });
    }
    catch (Exception ex)
    {
        logger.LogWarning(ex, "Falling back to in-memory activity for asset {AssetId}.", assetId);
        Interlocked.Increment(ref mission.FallbackReads);
        mission.LastStorageMode = "in-memory-fallback";
        mission.LastError = "Storage read fallback active.";
        AddMissionEvent("warning", "storage-read", $"Fallback read used for asset {assetId}.");
        return Results.Json(new
        {
            assetId,
            storageMode = "in-memory-fallback",
            comments = inMemoryComments.GetValueOrDefault(assetId) ?? [],
            tickets = inMemoryTickets.GetValueOrDefault(assetId) ?? []
        });
    }
});

app.MapPost("/api/assets/{assetId}/comments", async (string assetId, CommentRequest request, CancellationToken cancellationToken) =>
{
    if (string.IsNullOrWhiteSpace(request.Author) || string.IsNullOrWhiteSpace(request.Message))
    {
        return Results.BadRequest(new { error = "author and message are required" });
    }

    try
    {
        var createdUtc = DateTimeOffset.UtcNow.ToString("O");
        var entity = new TableEntity(assetId, Guid.NewGuid().ToString("N"))
        {
            ["author"] = request.Author.Trim(),
            ["message"] = request.Message.Trim(),
            ["createdUtc"] = createdUtc
        };

        await commentsTable.AddEntityAsync(entity, cancellationToken);
        Interlocked.Increment(ref mission.Writes);
        mission.LastStorageMode = "table-storage";
        return Results.Ok(new { saved = true, storageMode = "table-storage" });
    }
    catch (Exception ex)
    {
        logger.LogWarning(ex, "Falling back to in-memory comment write for asset {AssetId}.", assetId);
        var row = new ActivityRow(
            Guid.NewGuid().ToString("N"),
            DateTimeOffset.UtcNow.ToString("O"),
            request.Author.Trim(),
            request.Message.Trim(),
            null,
            null,
            null,
            null);
        inMemoryComments.AddOrUpdate(assetId, [row], (_, current) =>
        {
            current.Add(row);
            return current;
        });
        Interlocked.Increment(ref mission.FallbackWrites);
        mission.LastStorageMode = "in-memory-fallback";
        mission.LastError = "Storage write fallback active.";
        AddMissionEvent("warning", "storage-write", $"Fallback comment write used for asset {assetId}.");
        return Results.Ok(new { saved = true, storageMode = "in-memory-fallback" });
    }
});

app.MapPost("/api/assets/{assetId}/tickets", async (string assetId, TicketRequest request, CancellationToken cancellationToken) =>
{
    if (string.IsNullOrWhiteSpace(request.CreatedBy) || string.IsNullOrWhiteSpace(request.Title))
    {
        return Results.BadRequest(new { error = "createdBy and title are required" });
    }

    try
    {
        var createdUtc = DateTimeOffset.UtcNow.ToString("O");
        var entity = new TableEntity(assetId, Guid.NewGuid().ToString("N"))
        {
            ["createdBy"] = request.CreatedBy.Trim(),
            ["title"] = request.Title.Trim(),
            ["details"] = (request.Details ?? string.Empty).Trim(),
            ["priority"] = (request.Priority ?? "normal").Trim(),
            ["status"] = "open",
            ["createdUtc"] = createdUtc
        };

        await ticketsTable.AddEntityAsync(entity, cancellationToken);
        Interlocked.Increment(ref mission.Writes);
        mission.LastStorageMode = "table-storage";
        return Results.Ok(new { created = true, status = "open", storageMode = "table-storage" });
    }
    catch (Exception ex)
    {
        logger.LogWarning(ex, "Falling back to in-memory ticket write for asset {AssetId}.", assetId);
        var row = new ActivityRow(
            Guid.NewGuid().ToString("N"),
            DateTimeOffset.UtcNow.ToString("O"),
            request.CreatedBy.Trim(),
            null,
            request.Title.Trim(),
            (request.Details ?? string.Empty).Trim(),
            (request.Priority ?? "normal").Trim(),
            "open");
        inMemoryTickets.AddOrUpdate(assetId, [row], (_, current) =>
        {
            current.Add(row);
            return current;
        });
        Interlocked.Increment(ref mission.FallbackWrites);
        mission.LastStorageMode = "in-memory-fallback";
        mission.LastError = "Storage write fallback active.";
        AddMissionEvent("warning", "storage-write", $"Fallback ticket write used for asset {assetId}.");
        return Results.Ok(new { created = true, status = "open", storageMode = "in-memory-fallback" });
    }
});

app.Run();

TableServiceClient BuildTableServiceClient()
{
    var connectionString = Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING");
    if (!string.IsNullOrWhiteSpace(connectionString))
    {
        return new TableServiceClient(connectionString);
    }

    var tablesUri = Environment.GetEnvironmentVariable("STORAGE_TABLES_URI");
    if (string.IsNullOrWhiteSpace(tablesUri))
    {
        throw new InvalidOperationException("Set STORAGE_CONNECTION_STRING (start) or STORAGE_TABLES_URI (step1/final).");
    }

    return new TableServiceClient(new Uri(tablesUri), new DefaultAzureCredential());
}

static async Task<IReadOnlyList<AssetDto>> SearchAssetsAsync(string? query, IHttpClientFactory httpClientFactory, CancellationToken cancellationToken)
{
    var normalized = (query ?? string.Empty).Trim();
    var local = GetLocalAssets();
    var filtered = local
        .Where(a => normalized.Length == 0 ||
                    a.AssetId.Contains(normalized, StringComparison.OrdinalIgnoreCase) ||
                    a.Name.Contains(normalized, StringComparison.OrdinalIgnoreCase) ||
                    a.Region.Contains(normalized, StringComparison.OrdinalIgnoreCase))
        .ToList();

    var apiUrl = Environment.GetEnvironmentVariable("ASSET_SERVICE_API_URL");
    var apiKey = Environment.GetEnvironmentVariable("ASSET_SERVICE_API_KEY");

    if (string.IsNullOrWhiteSpace(apiUrl) || string.IsNullOrWhiteSpace(apiKey))
    {
        return filtered.Select(a => a with { Source = "local-fallback" }).ToList();
    }

    try
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{apiUrl}?q={WebUtility.UrlEncode(normalized)}");
        request.Headers.Add("x-api-key", apiKey);
        using var response = await httpClientFactory.CreateClient().SendAsync(request, cancellationToken);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return filtered.Select(a => a with { Source = "local-fallback (asset service 404)" }).ToList();
        }

        if (!response.IsSuccessStatusCode)
        {
            return filtered.Select(a => a with { Source = $"local-fallback (asset service {(int)response.StatusCode})" }).ToList();
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        var external = await JsonSerializer.DeserializeAsync<List<AssetDto>>(stream, cancellationToken: cancellationToken) ?? [];
        return external.Count == 0
            ? filtered.Select(a => a with { Source = "local-fallback (asset service empty)" }).ToList()
            : external;
    }
    catch
    {
        return filtered.Select(a => a with { Source = "local-fallback (asset service unavailable)" }).ToList();
    }
}

static async Task<List<ActivityRow>> ReadEntitiesAsync(TableClient table, string assetId, CancellationToken cancellationToken)
{
    var rows = new List<ActivityRow>();
    await foreach (var entity in table.QueryAsync<TableEntity>(e => e.PartitionKey == assetId, cancellationToken: cancellationToken))
    {
        rows.Add(new ActivityRow(
            entity.RowKey,
            entity.GetString("createdUtc") ?? entity.Timestamp?.ToString("O") ?? string.Empty,
            entity.GetString("author") ?? entity.GetString("createdBy"),
            entity.GetString("message"),
            entity.GetString("title"),
            entity.GetString("details"),
            entity.GetString("priority"),
            entity.GetString("status")));
    }

    return rows;
}

static List<AssetDto> GetLocalAssets() =>
[
    new("AST-1001", "Forklift A1", "Seattle", "Warehouse", "local-fallback"),
    new("AST-1002", "Conveyor C7", "Seattle", "Warehouse", "local-fallback"),
    new("AST-2001", "HVAC Roof Unit", "Phoenix", "Facility", "local-fallback"),
    new("AST-3005", "Inspection Drone", "Austin", "Field", "local-fallback"),
    new("AST-4103", "Packaging Robot", "Dublin", "Manufacturing", "local-fallback")
];

static string GetHtmlPage() => """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Asset Operations Console</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    .hero {
      background: linear-gradient(135deg, #0d6efd, #6610f2);
      color: #fff;
      border-radius: 1rem;
      padding: 1.5rem;
    }
    .asset-btn {
      width: 100%;
      text-align: left;
    }
  </style>
</head>
<body class="bg-body-tertiary">
  <main class="container py-4">
    <ul class="nav nav-tabs mb-3">
      <li class="nav-item">
        <a class="nav-link active" aria-current="page" href="/">Main Application</a>
      </li>
      <li class="nav-item">
        <a class="nav-link" href="/mission-control">Mission Control</a>
      </li>
    </ul>

    <section class="hero mb-4 shadow-sm">
      <div>
        <h1 class="h3 mb-1">Asset Operations Console</h1>
        <div class="opacity-75">Search assets, add comments, and create tickets. Mission telemetry is on a separate page.</div>
      </div>
    </section>

    <section class="card shadow-sm mb-4">
      <div class="card-body">
        <label for="query" class="form-label fw-semibold">Search assets</label>
        <div class="input-group mb-2">
          <input id="query" class="form-control" placeholder="asset id, name, or region" />
          <button id="searchBtn" class="btn btn-primary">Search</button>
        </div>
        <ul id="assets" class="list-group"></ul>
      </div>
    </section>

    <div class="row g-3">
      <div class="col-lg-6">
        <section class="card shadow-sm h-100">
          <div class="card-header bg-white d-flex justify-content-between align-items-center">
            <strong>Comments</strong>
            <span id="selectedAssetComments" class="badge text-bg-secondary">None</span>
          </div>
          <div class="card-body">
            <input id="commentAuthor" class="form-control mb-2" placeholder="your name" />
            <textarea id="commentMessage" class="form-control mb-2" rows="3" placeholder="comment"></textarea>
            <button id="commentBtn" class="btn btn-success">Add Comment</button>
            <ul id="comments" class="list-group mt-3"></ul>
          </div>
        </section>
      </div>

      <div class="col-lg-6">
        <section class="card shadow-sm h-100">
          <div class="card-header bg-white d-flex justify-content-between align-items-center">
            <strong>Tickets</strong>
            <span id="selectedAssetTickets" class="badge text-bg-secondary">None</span>
          </div>
          <div class="card-body">
            <input id="ticketCreatedBy" class="form-control mb-2" placeholder="created by" />
            <input id="ticketTitle" class="form-control mb-2" placeholder="ticket title" />
            <textarea id="ticketDetails" class="form-control mb-2" rows="3" placeholder="details"></textarea>
            <select id="ticketPriority" class="form-select mb-2">
              <option value="low">low</option>
              <option value="normal" selected>normal</option>
              <option value="high">high</option>
            </select>
            <button id="ticketBtn" class="btn btn-warning">Create Ticket</button>
            <ul id="tickets" class="list-group mt-3"></ul>
          </div>
        </section>
      </div>
    </div>
  </main>

  <script>
    let selectedAsset = null;
    async function searchAssets() {
      const q = document.getElementById('query').value || '';
      const res = await fetch(`/api/assets/search?q=${encodeURIComponent(q)}`);
      const data = await res.json();
      const assetsEl = document.getElementById('assets');
      assetsEl.innerHTML = '';
      data.assets.forEach(asset => {
        const li = document.createElement('li');
        li.className = 'list-group-item';
        const button = document.createElement('button');
        button.className = 'btn btn-outline-primary asset-btn';
        button.dataset.id = asset.assetId;
        button.textContent = `${asset.assetId} - ${asset.name} (${asset.region}) [${asset.source}]`;
        button.onclick = () => selectAsset(asset.assetId);
        li.appendChild(button);
        assetsEl.appendChild(li);
      });
    }

    async function selectAsset(assetId) {
      selectedAsset = assetId;
      document.getElementById('selectedAssetComments').textContent = assetId;
      document.getElementById('selectedAssetTickets').textContent = assetId;
      await refreshActivity();
    }

    async function refreshActivity() {
      if (!selectedAsset) return;
      const res = await fetch(`/api/assets/${encodeURIComponent(selectedAsset)}/activity`);
      const data = await res.json();
      const commentsEl = document.getElementById('comments');
      const ticketsEl = document.getElementById('tickets');
      commentsEl.innerHTML = '';
      ticketsEl.innerHTML = '';

      (data.comments || []).forEach(c => {
        const li = document.createElement('li');
        li.className = 'list-group-item';
        li.textContent = `${c.createdUtc || ''} - ${c.author || 'unknown'}: ${c.message || ''}`;
        commentsEl.appendChild(li);
      });
      (data.tickets || []).forEach(t => {
        const li = document.createElement('li');
        li.className = 'list-group-item';
        li.textContent = `${t.createdUtc || ''} - [${t.priority || 'normal'}] ${t.title || ''} (${t.status || 'open'})`;
        ticketsEl.appendChild(li);
      });
    }

    async function addComment() {
      if (!selectedAsset) return alert('Select an asset first');
      await fetch(`/api/assets/${encodeURIComponent(selectedAsset)}/comments`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          author: document.getElementById('commentAuthor').value,
          message: document.getElementById('commentMessage').value
        })
      });
      document.getElementById('commentMessage').value = '';
      await refreshActivity();
    }

    async function addTicket() {
      if (!selectedAsset) return alert('Select an asset first');
      await fetch(`/api/assets/${encodeURIComponent(selectedAsset)}/tickets`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          createdBy: document.getElementById('ticketCreatedBy').value,
          title: document.getElementById('ticketTitle').value,
          details: document.getElementById('ticketDetails').value,
          priority: document.getElementById('ticketPriority').value
        })
      });
      document.getElementById('ticketTitle').value = '';
      document.getElementById('ticketDetails').value = '';
      await refreshActivity();
    }

    document.getElementById('searchBtn').onclick = searchAssets;
    document.getElementById('commentBtn').onclick = addComment;
    document.getElementById('ticketBtn').onclick = addTicket;
    searchAssets();
  </script>
</body>
</html>
""";

static string GetMissionControlPage() => """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Mission Control</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <style>
    .hero {
      background: linear-gradient(135deg, #198754, #0d6efd);
      color: #fff;
      border-radius: 1rem;
      padding: 1.5rem;
    }
    .mission-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: .75rem;
    }
    .mission-item {
      border: 1px solid #e9ecef;
      border-radius: .75rem;
      padding: .75rem;
      background: #fff;
    }
    #events li { font-size: .9rem; }
  </style>
</head>
<body class="bg-body-tertiary">
  <main class="container py-4">
    <ul class="nav nav-tabs mb-3">
      <li class="nav-item">
        <a class="nav-link" href="/">Main Application</a>
      </li>
      <li class="nav-item">
        <a class="nav-link active" aria-current="page" href="/mission-control">Mission Control</a>
      </li>
    </ul>

    <section class="hero mb-4 shadow-sm">
      <div class="d-flex justify-content-between align-items-start flex-wrap gap-3">
        <div>
          <h1 class="h3 mb-1">Mission Control</h1>
          <div class="opacity-75">Monitor security posture and runtime fallback activity over time.</div>
        </div>
        <button id="refreshMissionBtn" class="btn btn-light btn-sm">Refresh</button>
      </div>
    </section>

    <section class="card shadow-sm mb-4">
      <div class="card-body">
        <div class="mission-grid mb-3">
          <div class="mission-item">
            <div class="text-secondary small">Stage</div>
            <span id="mcStage" class="badge text-bg-secondary">loading</span>
          </div>
          <div class="mission-item">
            <div class="text-secondary small">Network Profile</div>
            <span id="mcNetwork" class="badge text-bg-secondary">loading</span>
          </div>
          <div class="mission-item">
            <div class="text-secondary small">Storage Auth</div>
            <span id="mcStorageAuth" class="badge text-bg-secondary">loading</span>
          </div>
          <div class="mission-item">
            <div class="text-secondary small">API Key Source</div>
            <span id="mcApiKey" class="badge text-bg-secondary">loading</span>
          </div>
          <div class="mission-item">
            <div class="text-secondary small">Table Initialization</div>
            <span id="mcTableInit" class="badge text-bg-secondary">loading</span>
          </div>
          <div class="mission-item">
            <div class="text-secondary small">Last Storage Mode</div>
            <span id="mcStorageMode" class="badge text-bg-secondary">loading</span>
          </div>
        </div>

        <div class="row g-3 mb-2">
          <div class="col-md-3">
            <div class="border rounded p-2 bg-light">
              <div class="small text-secondary">Reads</div>
              <div id="mcReads" class="fw-semibold">0</div>
            </div>
          </div>
          <div class="col-md-3">
            <div class="border rounded p-2 bg-light">
              <div class="small text-secondary">Writes</div>
              <div id="mcWrites" class="fw-semibold">0</div>
            </div>
          </div>
          <div class="col-md-3">
            <div class="border rounded p-2 bg-light">
              <div class="small text-secondary">Fallback Reads</div>
              <div id="mcFallbackReads" class="fw-semibold">0</div>
            </div>
          </div>
          <div class="col-md-3">
            <div class="border rounded p-2 bg-light">
              <div class="small text-secondary">Fallback Writes</div>
              <div id="mcFallbackWrites" class="fw-semibold">0</div>
            </div>
          </div>
        </div>

        <div class="small text-danger mb-2" id="mcLastError"></div>
        <div class="small text-secondary mb-2">Recent security/runtime events</div>
        <ul id="events" class="list-group"></ul>
      </div>
    </section>
  </main>

  <script>
    const badgeMap = {
      success: 'text-bg-success',
      warning: 'text-bg-warning',
      danger: 'text-bg-danger',
      info: 'text-bg-info',
      secondary: 'text-bg-secondary'
    };

    function setBadge(id, value, tone = 'secondary') {
      const el = document.getElementById(id);
      el.className = `badge ${badgeMap[tone] || badgeMap.secondary}`;
      el.textContent = value ?? 'n/a';
    }

    function toneForValue(value, goodValues = [], warnValues = [], dangerValues = []) {
      if (goodValues.includes(value)) return 'success';
      if (dangerValues.includes(value)) return 'danger';
      if (warnValues.includes(value)) return 'warning';
      return 'secondary';
    }

    async function loadMissionControl() {
      const res = await fetch('/api/mission-control');
      const data = await res.json();

      setBadge('mcStage', data.stage, data.stage === 'final' ? 'success' : 'warning');
      setBadge('mcNetwork', data.networkProfile, toneForValue(data.networkProfile, ['private-networking'], ['public-endpoints-with-managed-identity']));
      setBadge('mcStorageAuth', data.storageAuthMode, toneForValue(data.storageAuthMode, ['managed-identity'], ['connection-string']));
      setBadge('mcApiKey', data.apiKeySource, toneForValue(data.apiKeySource, ['key-vault-reference'], ['app-setting-plain-text']));
      setBadge('mcTableInit', data.tableInitialization, toneForValue(data.tableInitialization, ['ready'], [], ['failed']));
      setBadge('mcStorageMode', data.lastStorageMode || 'n/a', toneForValue(data.lastStorageMode, ['table-storage'], ['in-memory-fallback']));

      document.getElementById('mcReads').textContent = data.reads;
      document.getElementById('mcWrites').textContent = data.writes;
      document.getElementById('mcFallbackReads').textContent = data.fallbackReads;
      document.getElementById('mcFallbackWrites').textContent = data.fallbackWrites;
      document.getElementById('mcLastError').textContent = data.lastError ? `Last error: ${data.lastError}` : '';

      const events = document.getElementById('events');
      events.innerHTML = '';
      (data.events || []).slice().reverse().forEach(e => {
        const li = document.createElement('li');
        li.className = 'list-group-item d-flex justify-content-between align-items-start';
        const left = document.createElement('div');
        const sev = document.createElement('span');
        sev.className = `badge ${badgeMap[e.severity] || badgeMap.info} me-2`;
        sev.textContent = e.severity;
        const cat = document.createElement('strong');
        cat.textContent = e.category;
        const text = document.createTextNode(` - ${e.message}`);
        left.appendChild(sev);
        left.appendChild(cat);
        left.appendChild(text);
        const right = document.createElement('small');
        right.className = 'text-secondary';
        right.textContent = new Date(e.timestamp).toLocaleTimeString();
        li.appendChild(left);
        li.appendChild(right);
        events.appendChild(li);
      });
    }

    document.getElementById('refreshMissionBtn').onclick = loadMissionControl;
    loadMissionControl();
    setInterval(loadMissionControl, 15000);
  </script>
</body>
</html>
""";

public sealed record CommentRequest(string Author, string Message);
public sealed record TicketRequest(string CreatedBy, string Title, string? Details, string? Priority);
public sealed record AssetDto(string AssetId, string Name, string Region, string Category, string Source);
public sealed record ActivityRow(string Id, string CreatedUtc, string? Author, string? Message, string? Title, string? Details, string? Priority, string? Status);
public sealed record MissionEvent(string Timestamp, string Severity, string Category, string Message);

public sealed class MissionRuntimeState
{
    public string TableInitialization { get; set; } = "pending";
    public string LastStorageMode { get; set; } = "unknown";
    public string? LastError { get; set; }
    public long Reads;
    public long Writes;
    public long FallbackReads;
    public long FallbackWrites;
    public ConcurrentQueue<MissionEvent> Events { get; } = new();
}
