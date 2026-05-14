# Creates or updates user_profile rows so local search defaults to Pavlodar, Kazakhstan.
#
# Prerequisites: table user_profile exists (run apply-user-profile-migration.ps1 once if needed).
#
# Usage (repo root):
#   .\scripts\seed-user-profile-pavlodar.ps1 -Mode Allowlist
#   .\scripts\seed-user-profile-pavlodar.ps1 -Mode FromMemory

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Allowlist", "FromMemory")]
    [string] $Mode,

    [string] $City = "Pavlodar",
    [string] $Country = "Kazakhstan"
)

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

$cityEsc = $City.Replace("'", "''")
$countryEsc = $Country.Replace("'", "''")

$sql = ""
if ($Mode -eq "Allowlist") {
    $raw = $env:TELEGRAM_ALLOWED_USER_IDS
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Error "TELEGRAM_ALLOWED_USER_IDS is empty. Set it in .env or use -Mode FromMemory."
    }
    $ids = @(
        $raw.Split(",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match "^\d+$" } |
            ForEach-Object { [long]$_ }
    )
    if ($ids.Count -eq 0) {
        Write-Error "No numeric user IDs found in TELEGRAM_ALLOWED_USER_IDS."
    }
    foreach ($id in $ids) {
        $sql += @"
INSERT INTO user_profile (user_id, default_city, default_country, location_mode)
VALUES ($id, '$cityEsc', '$countryEsc', 'auto')
ON CONFLICT (user_id) DO UPDATE SET
  default_city = EXCLUDED.default_city,
  default_country = EXCLUDED.default_country,
  location_mode = EXCLUDED.location_mode,
  updated_at = NOW();

"@
    }
    Write-Host "Seeding user_profile for $($ids.Count) allowlisted user_id(s) -> $City, $Country"
}

if ($Mode -eq "FromMemory") {
    $sql = @"
INSERT INTO user_profile (user_id, default_city, default_country, location_mode)
SELECT DISTINCT user_id, '$cityEsc', '$countryEsc', 'auto'
FROM chat_memory
WHERE user_id IS NOT NULL
ON CONFLICT (user_id) DO UPDATE SET
  default_city = EXCLUDED.default_city,
  default_country = EXCLUDED.default_country,
  location_mode = EXCLUDED.location_mode,
  updated_at = NOW();

"@
    Write-Host "Seeding user_profile for all user_id in chat_memory -> $City, $Country"
}

$sql | docker compose exec -T postgres psql -U $dbUser -d $dbName
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "OK: user_profile seed completed."
