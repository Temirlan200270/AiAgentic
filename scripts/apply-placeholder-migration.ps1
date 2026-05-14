# Applies docker/postgres/init/003_telegram_response_placeholders.sql to the running Postgres container.
# Run once if your volume was created before placeholder UX support existed.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$envFile = Join-Path $root ".env"
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
    Write-Error "POSTGRES_USER or POSTGRES_DB is missing. Check local .env."
}

$sqlPath = Join-Path $root "docker\postgres\init\003_telegram_response_placeholders.sql"
if (-not (Test-Path $sqlPath)) {
    Write-Error "Missing file: $sqlPath"
}

$sql = Get-Content -Raw -Encoding UTF8 $sqlPath
$sql | docker compose exec -T postgres psql -U $dbUser -d $dbName
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "OK: telegram_response_placeholders migration applied."
