param(
    [string]$CF_API_TOKEN = $env:CF_API_TOKEN,
    [string]$CF_ZONE_ID   = $env:CF_ZONE_ID,
    [string]$VPS_IP       = $env:VPS_IP,
    [string]$DOMAIN       = $env:DOMAIN
)

if (-not $CF_API_TOKEN) { Write-Error "CF_API_TOKEN is required"; exit 1 }
if (-not $CF_ZONE_ID)   { Write-Error "CF_ZONE_ID is required";   exit 1 }
if (-not $VPS_IP)       { Write-Error "VPS_IP is required";        exit 1 }
if (-not $DOMAIN)       { Write-Error "DOMAIN is required";        exit 1 }

$headers = @{
    "Authorization" = "Bearer $CF_API_TOKEN"
    "Content-Type"  = "application/json"
}

function Upsert-ARecord {
    param([string]$subdomain)

    $fqdn = "$subdomain.$DOMAIN"
    $lookupUrl = "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$fqdn&type=A"

    $lookup = Invoke-RestMethod -Uri $lookupUrl -Headers $headers -Method GET
    if (-not $lookup.success) {
        Write-Error "Cloudflare lookup failed for $fqdn"
        exit 1
    }

    $body = @{
        type    = "A"
        name    = $fqdn
        content = $VPS_IP
        ttl     = 1
        proxied = $false
        comment = "Managed by cloudflare-dns.ps1"
    } | ConvertTo-Json

    $existing = $lookup.result | Where-Object { $_.type -eq "A" } | Select-Object -First 1

    if ($existing) {
        $updateUrl = "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$($existing.id)"
        $result = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method PUT -Body $body
        if ($result.success) {
            Write-Host "Updated: $fqdn -> $VPS_IP"
        } else {
            Write-Error "Failed to update $fqdn`: $($result.errors | ConvertTo-Json)"
        }
    } else {
        $createUrl = "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records"
        $result = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method POST -Body $body
        if ($result.success) {
            Write-Host "Created: $fqdn -> $VPS_IP"
        } else {
            Write-Error "Failed to create $fqdn`: $($result.errors | ConvertTo-Json)"
        }
    }
}

Upsert-ARecord "coolify"
Upsert-ARecord "n8n"

Write-Host ""
Write-Host "Done. DNS records created (proxied=false, DNS-only mode)."
Write-Host "Propagation may take up to 5 minutes."
