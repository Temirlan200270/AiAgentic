$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $ScriptDir "..")
Set-Location $Root

$WorkflowName = "Personal AI Assistant MVP"
$DefaultBaseUrl = "http://127.0.0.1:5678"
$DockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"

function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Read-DotEnv {
    param([string] $Path)

    $envMap = @{}
    if (-not (Test-Path $Path)) {
        return $envMap
    }

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
            return
        }

        $parts = $line.Split("=", 2)
        $key = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        $envMap[$key] = $value
    }

    return $envMap
}

function Wait-ForDocker {
    param([int] $TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            docker version --format "{{.Server.Version}}" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return
            }
        } catch {
            # Keep waiting.
        }
        Start-Sleep -Seconds 5
    }

    throw "Docker daemon is not ready. Start Docker Desktop and run this script again."
}

function Wait-ForHttpOk {
    param(
        [string] $Url,
        [int] $TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return
            }
        } catch {
            # n8n can close connections while booting. Keep waiting.
        }
        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for $Url"
}

function Invoke-N8nApi {
    param(
        [string] $Method,
        [string] $Url,
        [hashtable] $Headers,
        [object] $Body = $null
    )

    if ($null -eq $Body) {
        if ($Method -in @("POST", "PUT", "PATCH")) {
            return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -ContentType "application/json" -Body "{}" -TimeoutSec 120
        }
        return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -TimeoutSec 120
    }

    $json = $Body | ConvertTo-Json -Depth 100
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $Headers -ContentType "application/json" -Body $json -TimeoutSec 120
}

function Get-AssistantWorkflow {
    param(
        [string] $BaseUrl,
        [hashtable] $Headers,
        [string] $Name
    )

    $response = Invoke-N8nApi -Method "GET" -Url "$BaseUrl/api/v1/workflows?limit=100" -Headers $Headers
    $matches = @($response.data | Where-Object { $_.name -eq $Name } | Sort-Object updatedAt, createdAt -Descending)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

Write-Host "Personal AI Assistant - one-click local deploy" -ForegroundColor Green

$envMap = Read-DotEnv (Join-Path $Root ".env")
if (-not (Test-Path (Join-Path $Root ".env"))) {
    throw ".env not found. Copy .env.example to .env and fill local values first."
}

Write-Step "Checking Docker Desktop"
try {
    docker version --format "{{.Server.Version}}" 2>$null | Out-Null
} catch {
    # Ignore; handled below.
}

if ($LASTEXITCODE -ne 0) {
    if (Test-Path $DockerDesktopExe) {
        Write-Host "Docker is not ready. Starting Docker Desktop..."
        Start-Process -FilePath $DockerDesktopExe -WindowStyle Hidden
    }
}
Wait-ForDocker -TimeoutSeconds 240

Write-Step "Starting local services"
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    throw "docker compose up -d failed."
}

Write-Step "Waiting for n8n"
$baseUrl = ($envMap["N8N_BASE_URL"], $envMap["N8N_EDITOR_BASE_URL"], $DefaultBaseUrl | Where-Object { $_ } | Select-Object -First 1).TrimEnd("/")
Wait-ForHttpOk -Url "$baseUrl/healthz" -TimeoutSeconds 240

Write-Step "Checking PostgreSQL schema"
& (Join-Path $ScriptDir "check-db.ps1")

Write-Step "Checking external integrations"
& (Join-Path $ScriptDir "test-integrations.ps1")

if (-not $envMap["N8N_API_KEY"]) {
    Write-Host ""
    Write-Host "n8n is running, but N8N_API_KEY is missing in .env." -ForegroundColor Yellow
    Write-Host "Create it in n8n: Settings -> API, add N8N_API_KEY=... to .env, then run this script again."
    Write-Host "Open n8n: $baseUrl"
    exit 2
}

$headers = @{
    "X-N8N-API-KEY" = $envMap["N8N_API_KEY"]
    "Accept" = "application/json"
}

Write-Step "Syncing workflow from repository"
$syncScript = Join-Path $ScriptDir "sync-mvp-workflow.py"
python $syncScript
if ($LASTEXITCODE -ne 0) {
    Write-Host "Sync did not find/update an existing workflow. Creating a new one..."
    python (Join-Path $ScriptDir "create-mvp-workflow-api.py")
    if ($LASTEXITCODE -ne 0) {
        throw "Workflow create failed."
    }
}

$workflow = Get-AssistantWorkflow -BaseUrl $baseUrl -Headers $headers -Name $WorkflowName
if ($null -eq $workflow) {
    throw "Could not find workflow '$WorkflowName' after sync/create."
}

Write-Step "Activating workflow"
try {
    Invoke-N8nApi -Method "POST" -Url "$baseUrl/api/v1/workflows/$($workflow.id)/deactivate" -Headers $headers | Out-Null
} catch {
    # It may already be inactive; activation below is the important operation.
}

$activated = Invoke-N8nApi -Method "POST" -Url "$baseUrl/api/v1/workflows/$($workflow.id)/activate" -Headers $headers
if (-not $activated.active) {
    throw "Workflow activation API returned active=false."
}

Write-Step "Final status"
docker compose ps
Write-Host ""
Write-Host "Workflow: $($activated.name)"
Write-Host "Workflow ID: $($activated.id)"
Write-Host "Active: $($activated.active)"
Write-Host "Open editor: $baseUrl/workflow/$($activated.id)"
Write-Host ""
Write-Host "Telegram polling is active. Send a message to the bot and wait about 10-20 seconds."
