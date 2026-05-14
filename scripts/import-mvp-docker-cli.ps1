# Import MVP workflow into n8n container via CLI and append container logs to a file.
# Use when the web UI "Import from File" fails silently — everything is captured in logs/n8n-import-cli-*.log
#
# Prerequisites: docker compose up -d (n8n service name: n8n), workflows/personal_assistant_mvp.json present.

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$json = Join-Path $root "workflows/personal_assistant_mvp.json"
if (-not (Test-Path -LiteralPath $json)) {
    Write-Error "File not found: $json"
    exit 1
}

$logsDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logsDir "n8n-import-cli-$stamp.log"

function Write-LogLine {
    param([string]$Line)
    Add-Content -LiteralPath $logFile -Value $Line -Encoding utf8
}

Write-LogLine "=== $(Get-Date -Format o) ==="
Write-LogLine "Host JSON: $json"

Write-Host "Copying JSON into n8n container..."
docker compose cp -- "$json" "n8n:/tmp/personal_assistant_mvp.json" 2>&1 | ForEach-Object {
    Write-Host $_
    Write-LogLine $_
}

Write-Host "Running n8n import:workflow..."
Write-LogLine "--- n8n import:workflow stdout/stderr ---"
docker compose exec -T n8n n8n import:workflow --input=/tmp/personal_assistant_mvp.json 2>&1 | ForEach-Object {
    Write-Host $_
    Write-LogLine $_
}

Write-LogLine "--- docker compose logs n8n (tail 120) ---"
docker compose logs n8n --tail 120 2>&1 | ForEach-Object { Write-LogLine $_ }

Write-Host ""
Write-Host "Full log written to: $logFile"
