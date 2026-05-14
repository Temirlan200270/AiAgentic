param (
    [string]$ContainerName = "personal-ai-local-postgres-1",
    [string]$DbUser = "assistant",
    [string]$DbName = "assistant_db",
    [string]$BackupDir = "backups"
)

# Load variables from .env if present
if (Test-Path ".env") {
    Get-Content ".env" | Where-Object { $_ -match "^POSTGRES_USER=" } | ForEach-Object { $DbUser = $_.Split("=",2)[1].Trim().Trim('"') }
    Get-Content ".env" | Where-Object { $_ -match "^POSTGRES_DB=" } | ForEach-Object { $DbName = $_.Split("=",2)[1].Trim().Trim('"') }
}

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $BackupDir "backup_${DbName}_${timestamp}.sql"

Write-Host "Creating backup for $DbName database to $backupFile..."

# Execute pg_dump inside the docker container
docker exec $ContainerName pg_dump -U $DbUser -d $DbName > $backupFile

if ($LASTEXITCODE -eq 0) {
    Write-Host "Backup successfully created: $backupFile" -ForegroundColor Green
} else {
    Write-Host "Error creating backup. Ensure the container is running." -ForegroundColor Red
}
