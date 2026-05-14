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

function Require-Env($name) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$name is missing in .env"
    }
    return $value
}

Write-Host "Checking local n8n..."
$health = Invoke-RestMethod -Uri "http://localhost:5678/healthz" -Method Get -TimeoutSec 20
if ($health.status -ne "ok") {
    throw "n8n healthz returned unexpected status"
}
Write-Host "n8n: OK"

Write-Host "Checking Telegram bot token..."
$telegramToken = Require-Env "TELEGRAM_BOT_TOKEN"
$telegram = Invoke-RestMethod -Uri "https://api.telegram.org/bot$telegramToken/getMe" -Method Get -TimeoutSec 20
if (-not $telegram.ok) {
    throw "Telegram getMe returned ok=false"
}
Write-Host "Telegram: OK, bot username @$($telegram.result.username)"

Write-Host "Checking Tavily..."
$tavilyKey = Require-Env "TAVILY_API_KEY"
$tavilyBody = @{
    api_key = $tavilyKey
    query = "n8n workflow automation"
    max_results = 1
} | ConvertTo-Json
$tavily = Invoke-RestMethod -Uri "https://api.tavily.com/search" -Method Post -ContentType "application/json" -Body $tavilyBody -TimeoutSec 30
Write-Host "Tavily: OK, results=$($tavily.results.Count)"

Write-Host "Checking OpenAI..."
$openAiKey = Require-Env "OPENAI_API_KEY"
$model = [Environment]::GetEnvironmentVariable("OPENAI_ROUTER_MODEL", "Process")
if ([string]::IsNullOrWhiteSpace($model)) {
    $model = "gpt-5.4-mini"
}
$openAiBody = @{
    model = $model
    messages = @(
        @{ role = "system"; content = "Return exactly OK." },
        @{ role = "user"; content = "ping" }
    )
    temperature = 0
    max_completion_tokens = 20
} | ConvertTo-Json -Depth 5
$headers = @{ Authorization = "Bearer $openAiKey" }
$openAi = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -ContentType "application/json" -Body $openAiBody -TimeoutSec 30
Write-Host "OpenAI: OK, model=$model"

Write-Host ""
Write-Host "All integration checks passed."
