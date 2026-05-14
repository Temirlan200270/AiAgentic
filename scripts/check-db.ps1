$ErrorActionPreference = "Stop"

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
    Write-Error "POSTGRES_USER or POSTGRES_DB is missing. Check local .env."
}

Write-Host "Checking PostgreSQL readiness..."
docker compose exec -T postgres pg_isready -U $dbUser -d $dbName

Write-Host ""
Write-Host "Assistant tables:"
docker compose exec -T postgres psql -U $dbUser -d $dbName -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

Write-Host ""
Write-Host "Expected tables:"
docker compose exec -T postgres psql -U $dbUser -d $dbName -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('chat_memory', 'finance_log', 'reminders', 'telegram_poll_state', 'llm_usage_log', 'processed_telegram_updates', 'execution_log', 'tool_execution_log', 'unsent_telegram_messages', 'telegram_response_placeholders', 'user_profile') ORDER BY table_name;"
