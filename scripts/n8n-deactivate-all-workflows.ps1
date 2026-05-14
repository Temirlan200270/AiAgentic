$ErrorActionPreference = "Stop"

# Stops n8n from retrying broken/active workflows on startup (reduces DB load while recovering).
# Run from repo root after: docker compose up -d postgres

$envFile = Join-Path (Get-Location) ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^\s*([^#][^=]+)=(.*)$") {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

$dbUser = $env:POSTGRES_USER
$dbName = $env:POSTGRES_DB

if ([string]::IsNullOrWhiteSpace($dbUser) -or [string]::IsNullOrWhiteSpace($dbName)) {
    Write-Error "POSTGRES_USER or POSTGRES_DB is missing. Run from repo root with .env present."
}

Write-Host "Deactivating all workflows in n8n table workflow_entity..."
docker compose exec -T postgres psql -U $dbUser -d $dbName -c 'UPDATE "workflow_entity" SET active = false; SELECT id, name, active FROM "workflow_entity";'

Write-Host ""
Write-Host "Done. Restart n8n: docker compose restart n8n"
Write-Host "Then wait until: docker compose ps  shows n8n (healthy)"
