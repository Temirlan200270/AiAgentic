$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CoolifyHost = if ($env:VPS_IP) { $env:VPS_IP } else { '178.104.28.145' }
$CoolifyApiBase = if ($env:COOLIFY_API_BASE) { $env:COOLIFY_API_BASE } else { "http://${CoolifyHost}:8000/api/v1" }
$CoolifyToken = $env:COOLIFY_TOKEN
$InvocationPath = $null
if ($MyInvocation -and $MyInvocation.MyCommand -and ($MyInvocation.MyCommand.PSObject.Properties.Name -contains 'Path')) {
    $InvocationPath = $MyInvocation.MyCommand.Path
}
$ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($InvocationPath) { Split-Path -LiteralPath $InvocationPath -Parent } else { (Get-Location).Path }
$EnvFilePath = Join-Path -Path $ProjectRoot -ChildPath '.env'
$ComposeFilePath = Join-Path -Path $ProjectRoot -ChildPath 'docker-compose.yml'

$ProjectName = if ($env:COOLIFY_PROJECT_NAME) { $env:COOLIFY_PROJECT_NAME } else { 'personal-ai-assistant' }
$ProjectDescription = if ($env:COOLIFY_PROJECT_DESCRIPTION) { $env:COOLIFY_PROJECT_DESCRIPTION } else { 'Personal AI assistant stack deployed from local docker-compose.yml' }
$EnvironmentName = if ($env:COOLIFY_ENVIRONMENT_NAME) { $env:COOLIFY_ENVIRONMENT_NAME } else { 'production' }
$ServiceName = if ($env:COOLIFY_SERVICE_NAME) { $env:COOLIFY_SERVICE_NAME } else { 'personal-ai-assistant' }
$ComposePublicServiceName = if ($env:COOLIFY_PUBLIC_SERVICE_NAME) { $env:COOLIFY_PUBLIC_SERVICE_NAME } else { 'n8n' }
$N8nDomain = if ($env:N8N_PUBLIC_URL) { $env:N8N_PUBLIC_URL } else { 'https://n8n.plovxanapvl.com' }
$ExpectedN8nHost = if ($env:N8N_PUBLIC_HOST) { $env:N8N_PUBLIC_HOST } else { 'n8n.plovxanapvl.com' }
$ExpectedProxyTargetPort = 5678

$DeploymentPollIntervalSeconds = 5
$DeploymentTimeoutMinutes = 20

if (-not $CoolifyToken) {
    throw 'COOLIFY_TOKEN env var is required.'
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function ConvertTo-Array {
    [OutputType([object[]])]
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    $result = $null

    if ($null -eq $InputObject) {
        $result = [object[]]@()
    }
    elseif ($InputObject -is [System.Array]) {
        $result = [object[]]$InputObject
    }
    elseif ($InputObject -is [string]) {
        $result = [object[]]@($InputObject)
    }
    else {
        $result = [object[]]@($InputObject)
    }

    Write-Output -NoEnumerate $result
}

function Get-ResponseBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $hasResponse = $Exception.PSObject.Properties.Name -contains 'Response'
    if (-not $hasResponse -or $null -eq $Exception.Response) {
        return $null
    }

    $stream = $Exception.Response.GetResponseStream()
    if ($null -eq $stream) {
        return $null
    }

    $reader = New-Object System.IO.StreamReader($stream)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-ExceptionResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    if ($Exception.PSObject.Properties.Name -contains 'Response') {
        return $Exception.Response
    }

    return $null
}

function Invoke-CoolifyApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        $Body,

        [switch]$AllowNotFound
    )

    $uri = '{0}{1}' -f $CoolifyApiBase, $Path
    $headers = @{
        Authorization = "Bearer $CoolifyToken"
        Accept        = 'application/json'
    }

    $requestParams = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $headers
        ErrorAction = 'Stop'
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $headers['Content-Type'] = 'application/json'
        $requestParams['Body'] = ($Body | ConvertTo-Json -Depth 50 -Compress)
    }

    try {
        return Invoke-RestMethod @requestParams
    }
    catch {
        $response = Get-ExceptionResponse -Exception $_.Exception

        if ($AllowNotFound -and $response) {
            $statusCode = [int]$response.StatusCode.value__
            if ($statusCode -eq 404) {
                return $null
            }
        }

        $bodyText = Get-ResponseBody -Exception $_.Exception
        $message = "Coolify API $Method $Path failed."

        if ($response) {
            $statusCode = [int]$response.StatusCode.value__
            $statusDescription = [string]$response.StatusDescription
            $message = "$message HTTP $statusCode"
            if ($statusDescription) {
                $message = "$message $statusDescription"
            }
        }

        if ($bodyText) {
            $message = "$message Response: $bodyText"
        }

        throw $message
    }
}

function Get-EnvMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $envMap = [ordered]@{}
    $lines = Get-Content -LiteralPath $Path

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1)

        if ($value.Length -ge 2) {
            $startsWithSingle = $value.StartsWith("'")
            $endsWithSingle = $value.EndsWith("'")
            $startsWithDouble = $value.StartsWith('"')
            $endsWithDouble = $value.EndsWith('"')

            if (($startsWithSingle -and $endsWithSingle) -or ($startsWithDouble -and $endsWithDouble)) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $envMap[$key] = $value
    }

    return $envMap
}

function Get-ComposeBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $composeText = Get-Content -LiteralPath $Path -Raw

    if (-not $composeText.Trim()) {
        throw "docker-compose.yml is empty."
    }

    if ($composeText -notmatch '(?m)^\s*services\s*:') {
        throw "docker-compose.yml does not look like a valid compose file: missing 'services:'."
    }

    if ($composeText -notmatch '(?m)^\s{2}n8n\s*:') {
        Write-Warning "The compose file does not contain a top-level 'n8n' service block exactly as expected. Domain mapping assumes the service name is 'n8n'."
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($composeText)
    return [Convert]::ToBase64String($bytes)
}

function Get-FirstUsableServer {
    $servers = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path '/servers')

    if (-not $servers.Count) {
        throw 'No Coolify servers were returned by the API.'
    }

    $preferred = $servers |
        Where-Object { $_.is_usable -and $_.is_reachable -and $_.is_coolify_host } |
        Select-Object -First 1

    if (-not $preferred) {
        $preferred = $servers |
            Where-Object { $_.is_usable -and $_.is_reachable } |
            Select-Object -First 1
    }

    if (-not $preferred) {
        throw 'No reachable and usable Coolify server is available.'
    }

    return $preferred
}

function Ensure-Project {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $projects = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path '/projects')
    $existing = $projects | Where-Object { $_.name -eq $Name } | Select-Object -First 1

    if ($existing) {
        return $existing
    }

    Write-Step "Creating Coolify project '$Name'"
    $created = Invoke-CoolifyApi -Method POST -Path '/projects' -Body @{
        name        = $Name
        description = $Description
    }

    return [pscustomobject]@{
        uuid        = $created.uuid
        name        = $Name
        description = $Description
    }
}

function Ensure-Environment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectUuid,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $path = "/projects/$ProjectUuid/environments"
    $environments = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path $path)
    $existing = $environments | Where-Object { $_.name -eq $Name } | Select-Object -First 1

    if ($existing) {
        return $existing
    }

    Write-Step "Creating Coolify environment '$Name'"
    $created = Invoke-CoolifyApi -Method POST -Path $path -Body @{ name = $Name }

    return [pscustomobject]@{
        uuid = $created.uuid
        name = $Name
    }
}

function Get-ServiceByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $services = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path '/services')
    $matches = @($services | Where-Object { $_.name -eq $Name })

    if ($matches.Count -gt 1) {
        throw "More than one Coolify service named '$Name' exists. The API list endpoint does not include project metadata, so the script cannot safely pick one."
    }

    return $matches | Select-Object -First 1
}

function Get-ServiceResource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerUuid,

        [Parameter(Mandatory = $true)]
        [string]$ServiceName,

        [Parameter()]
        [string]$ServiceUuid
    )

    $resources = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path "/servers/$ServerUuid/resources")

    if ($ServiceUuid) {
        $byUuid = $resources | Where-Object { $_.uuid -eq $ServiceUuid } | Select-Object -First 1
        if ($byUuid) {
            return $byUuid
        }
    }

    $byNameAndType = $resources | Where-Object { $_.name -eq $ServiceName -and $_.type -eq 'service' } | Select-Object -First 1
    if ($byNameAndType) {
        return $byNameAndType
    }

    return $resources | Where-Object { $_.name -eq $ServiceName } | Select-Object -First 1
}

function Sync-ServiceEnvironmentVariables {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceUuid,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DesiredEnvMap
    )

    $existingEntries = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path "/services/$ServiceUuid/envs")
    $existingByKey = @{}

    foreach ($entry in $existingEntries) {
        $existingByKey[[string]$entry.key] = $entry
    }

    $updatedCount = 0
    $createdCount = 0

    foreach ($key in $DesiredEnvMap.Keys) {
        $value = [string]$DesiredEnvMap[$key]
        $isMultiline = $value.Contains("`n") -or $value.Contains("`r")
        $payload = @{
            key           = $key
            value         = $value
            is_preview    = $false
            is_literal    = $true
            is_multiline  = $isMultiline
            is_shown_once = $false
        }

        if ($existingByKey.ContainsKey($key)) {
            Invoke-CoolifyApi -Method PATCH -Path "/services/$ServiceUuid/envs" -Body $payload | Out-Null
            $updatedCount++
        }
        else {
            Invoke-CoolifyApi -Method POST -Path "/services/$ServiceUuid/envs" -Body $payload | Out-Null
            $createdCount++
        }
    }

    Write-Step "Service env sync complete: created $createdCount, updated $updatedCount."
}

function Wait-ForServiceReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerUuid,

        [Parameter(Mandatory = $true)]
        [string]$ServiceName,

        [Parameter(Mandatory = $true)]
        [string]$ServiceUuid,

        [int]$TimeoutMinutes = 20,

        [int]$PollIntervalSeconds = 5
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $runningStreak = 0
    $failureStreak = 0

    while ((Get-Date) -lt $deadline) {
        $resource = Get-ServiceResource -ServerUuid $ServerUuid -ServiceName $ServiceName -ServiceUuid $ServiceUuid
        $runningDeployments = ConvertTo-Array (Invoke-CoolifyApi -Method GET -Path '/deployments')

        $status = if ($resource) { [string]$resource.status } else { 'not-created-yet' }
        $normalizedStatus = $status.ToLowerInvariant()

        if ($normalizedStatus -match 'dead|error|failed|crash') {
            throw "Service resource entered a terminal failure state: '$status'. Check the Coolify UI or container logs."
        }

        if ($normalizedStatus -match 'running|healthy') {
            $runningStreak++
            $failureStreak = 0
        }
        else {
            $runningStreak = 0
            if ($normalizedStatus -match 'exited|unhealthy') {
                $failureStreak++
            }
            else {
                $failureStreak = 0
            }
        }

        $activeDeploymentCount = $runningDeployments.Count
        Write-Host ("Polling: resource status='{0}', active deployments={1}" -f $status, $activeDeploymentCount)

        if ($failureStreak -ge 3 -and $activeDeploymentCount -eq 0) {
            throw "Service resource stayed in a failing transitional state: '$status'. Check the Coolify UI or container logs."
        }

        if ($runningStreak -ge 1 -and $activeDeploymentCount -eq 0) {
            return $resource
        }

        if ($runningStreak -ge 3) {
            Write-Warning 'The service looks healthy, but the generic /deployments queue is still non-empty. Continuing because the service has been running consistently.'
            return $resource
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for service '$ServiceName' to become ready."
}

Require-File -Path $EnvFilePath
Require-File -Path $ComposeFilePath

Write-Step 'Loading local deployment inputs'
$envMap = Get-EnvMap -Path $EnvFilePath
$composeBase64 = Get-ComposeBase64 -Path $ComposeFilePath

if (-not $envMap.Contains('N8N_HOST')) {
    throw '.env is missing N8N_HOST.'
}

if ($envMap['N8N_HOST'] -ne $ExpectedN8nHost) {
    Write-Warning "N8N_HOST in .env is '$($envMap['N8N_HOST'])', but the deployment target is '$ExpectedN8nHost'."
}

Write-Step 'Checking Coolify API availability'
$version = Invoke-CoolifyApi -Method GET -Path '/version'
Write-Host "Coolify API version: $version"

Write-Step 'Resolving target server'
$server = Get-FirstUsableServer
$serverDetails = Invoke-CoolifyApi -Method GET -Path "/servers/$($server.uuid)"

Write-Host ("Using server '{0}' ({1})" -f $server.name, $server.uuid)

if ($serverDetails.proxy -and [string]$serverDetails.proxy.status -ne 'running') {
    Write-Warning "Coolify proxy status is '$($serverDetails.proxy.status)'. Domain routing may fail until the proxy is healthy."
}

# The verified API supports { name, url } domain mappings for services, but it does not expose
# an explicit per-domain port field. Coolify usually infers the internal port from the compose
# service/image. If the UI does not bind the domain to the n8n container's port 5678 automatically,
# manually confirm the domain mapping in the Coolify UI after the script finishes.

Write-Step 'Ensuring project and environment exist'
$project = Ensure-Project -Name $ProjectName -Description $ProjectDescription
$environment = Ensure-Environment -ProjectUuid $project.uuid -Name $EnvironmentName

Write-Host ("Project UUID: {0}" -f $project.uuid)
Write-Host ("Environment UUID: {0}" -f $environment.uuid)

Write-Step 'Ensuring service exists with the current docker-compose.yml'
$servicePayload = @{
    name                               = $ServiceName
    description                        = $ProjectDescription
    project_uuid                       = $project.uuid
    environment_name                   = $environment.name
    environment_uuid                   = $environment.uuid
    server_uuid                        = $server.uuid
    instant_deploy                     = $false
    docker_compose_raw                 = $composeBase64
    urls                               = @(
        @{
            name = $ComposePublicServiceName
            url  = $N8nDomain
        }
    )
    force_domain_override              = $true
    is_container_label_escape_enabled  = $true
}

$serviceUpdatePayload = @{
    name                               = $ServiceName
    description                        = $ProjectDescription
    instant_deploy                     = $false
    docker_compose_raw                 = $composeBase64
    urls                               = $servicePayload.urls
    force_domain_override              = $true
    is_container_label_escape_enabled  = $true
}

$existingService = Get-ServiceByName -Name $ServiceName
$serviceWasCreated = $false

if ($existingService) {
    Write-Step "Updating existing service '$ServiceName'"
    $serviceMutationResult = Invoke-CoolifyApi -Method PATCH -Path "/services/$($existingService.uuid)" -Body $serviceUpdatePayload
    $serviceUuid = $existingService.uuid
}
else {
    Write-Step "Creating new service '$ServiceName'"
    $serviceMutationResult = Invoke-CoolifyApi -Method POST -Path '/services' -Body $servicePayload
    $serviceUuid = [string]$serviceMutationResult.uuid
    $serviceWasCreated = $true
}

if (-not $serviceUuid) {
    throw 'Coolify did not return a service UUID.'
}

Write-Host ("Service UUID: {0}" -f $serviceUuid)

if ($serviceMutationResult.domains) {
    $returnedDomains = (ConvertTo-Array $serviceMutationResult.domains) -join ', '
    Write-Host ("Coolify returned domains: {0}" -f $returnedDomains)
}

Write-Step 'Syncing environment variables from local .env'
Sync-ServiceEnvironmentVariables -ServiceUuid $serviceUuid -DesiredEnvMap $envMap

Write-Step 'Triggering deployment'
$existingResource = Get-ServiceResource -ServerUuid $server.uuid -ServiceName $ServiceName -ServiceUuid $serviceUuid
$resourceStatus = if ($existingResource) { [string]$existingResource.status } else { '' }
$resourceStatusNormalized = $resourceStatus.ToLowerInvariant()

if ($serviceWasCreated -or -not $existingResource -or $resourceStatusNormalized -notmatch 'running|healthy') {
    Write-Host 'Using /start because the service is new or not currently healthy.'
    Invoke-CoolifyApi -Method GET -Path "/services/$serviceUuid/start" | Out-Null
}
else {
    Write-Host 'Using /restart to apply compose or env updates to the running service.'
    Invoke-CoolifyApi -Method GET -Path "/services/$serviceUuid/restart" | Out-Null
}

Write-Step 'Polling deployment status until ready'
$finalResource = Wait-ForServiceReady `
    -ServerUuid $server.uuid `
    -ServiceName $ServiceName `
    -ServiceUuid $serviceUuid `
    -TimeoutMinutes $DeploymentTimeoutMinutes `
    -PollIntervalSeconds $DeploymentPollIntervalSeconds

Write-Host ''
Write-Host 'Deployment completed.' -ForegroundColor Green
Write-Host ("Service: {0}" -f $ServiceName)
Write-Host ("Service UUID: {0}" -f $serviceUuid)
Write-Host ("Runtime status: {0}" -f $finalResource.status)
Write-Host ("Public n8n URL: {0}" -f $N8nDomain)
Write-Host ''

# Manual follow-up if needed:
# 1. DNS is outside the Coolify API scope. Ensure n8n.plovxanapvl.com resolves to 178.104.28.145.
# 2. If the Coolify proxy is not running, fix that in the Coolify UI or on the host.
# 3. If the domain is present in Coolify but does not route to n8n, manually verify that the
#    compose service 'n8n' is attached to container port 5678 in the Coolify UI.
