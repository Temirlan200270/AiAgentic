$ErrorActionPreference = "Stop"

$backupPath = $args[0]

if ([string]::IsNullOrWhiteSpace($backupPath)) {
    Write-Error "Usage: .\scripts\restore-db.ps1 .\backups\personal_ai_assistant-YYYYMMDD-HHMMSS.sql"
}

if (-not (Test-Path $backupPath)) {
    Write-Error "Backup file not found: $backupPath"
}

Write-Host "Restoring PostgreSQL backup: $backupPath"
Get-Content -Raw -Path $backupPath | docker compose exec -T postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

Write-Host "Restore complete."

