$ErrorActionPreference = "Stop"

$service = $args[0]

if ([string]::IsNullOrWhiteSpace($service)) {
    docker compose logs -f --tail=150
} else {
    docker compose logs -f --tail=150 $service
}

