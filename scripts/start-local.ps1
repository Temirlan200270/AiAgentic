$ErrorActionPreference = "Stop"

Write-Host "Starting local n8n + PostgreSQL..."
docker compose up -d

Write-Host ""
Write-Host "Services:"
docker compose ps

Write-Host ""
Write-Host "n8n should be available at: http://localhost:5678"

