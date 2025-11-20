#!/usr/bin/env pwsh
<# 
Update a Cloudflare A record with the machine's current local IP (default route).
Requirements:
  - Env var CLOUDFLARE_API_TOKEN must be set.
  - Optional: CLOUDFLARE_ZONE_ID or CLOUDFLARE_ZONE_NAME to avoid guessing.
Usage:
  pwsh ./update_cloudflare_dns.ps1 <hostname>
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$Hostname
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Abort($Message) {
  Write-Error $Message
  exit 1
}

$Token = $env:CLOUDFLARE_API_TOKEN
if (-not $Token) { Abort "CLOUDFLARE_API_TOKEN is not set" }

function Get-DefaultInterface {
  if ($IsWindows) {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
      Sort-Object -Property RouteMetric |
      Select-Object -First 1
    return $route.InterfaceAlias
  }
  $ipCmd = Get-Command ip -ErrorAction SilentlyContinue
  if ($ipCmd) {
    $line = (& $ipCmd route get 1.1.1.1 2>$null) | Select-String -Pattern 'dev\s+(\S+)' | Select-Object -First 1
    if ($line) { return $line.Matches[0].Groups[1].Value }
  }
  $routeCmd = Get-Command route -ErrorAction SilentlyContinue
  if ($routeCmd) {
    $line = (& $routeCmd -n get default 2>$null) | Where-Object { $_ -match 'interface:' } | Select-Object -First 1
    if ($line) { return ($line -split '\s+')[1] }
  }
  return $null
}

function Get-LocalIPv4 {
  $iface = Get-DefaultInterface
  if (-not $iface) { Abort "could not determine default network interface" }

  if ($IsWindows) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $iface -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -ne $null } |
      Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
  }

  $ipCmd = Get-Command ip -ErrorAction SilentlyContinue
  if ($ipCmd) {
    $ip = (& $ipCmd -4 addr show dev $iface 2>$null) |
      Where-Object { $_ -match '\s+inet\s+' } |
      ForEach-Object { ($_ -split '\s+')[2].Split('/')[0] } |
      Select-Object -First 1
    if ($ip) { return $ip }
  }
  $ifconfigCmd = Get-Command ifconfig -ErrorAction SilentlyContinue
  if ($ifconfigCmd) {
    $ip = (& $ifconfigCmd $iface 2>$null) |
      Where-Object { $_ -match 'inet\s' -and $_ -notmatch 'inet6' } |
      ForEach-Object { ($_ -split '\s+')[1] } |
      Select-Object -First 1
    if ($ip) { return $ip }
  }
  return $null
}

function Guess-ZoneName {
  param([string]$HostNameValue)

  if ($env:CLOUDFLARE_ZONE_NAME) { return $env:CLOUDFLARE_ZONE_NAME }

  $parts = $HostNameValue.Split('.')
  if ($parts.Count -lt 2) { return $null }
  return "$($parts[-2]).$($parts[-1])"
}

function Fetch-ZoneId {
  param([string]$ZoneName)
  $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
  $uri = "https://api.cloudflare.com/client/v4/zones?name=$ZoneName&status=active"
  $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction SilentlyContinue
  if ($resp -and $resp.success -and $resp.result.Count -gt 0) {
    return $resp.result[0].id
  }
  return $null
}

$LocalIP = Get-LocalIPv4
if (-not $LocalIP) { Abort "could not determine local IPv4 address" }

$ZoneId = $env:CLOUDFLARE_ZONE_ID
if (-not $ZoneId) {
  $ZoneName = Guess-ZoneName -HostNameValue $Hostname
  if (-not $ZoneName) { Abort "could not derive zone from hostname; set CLOUDFLARE_ZONE_NAME or CLOUDFLARE_ZONE_ID" }
  $ZoneId = Fetch-ZoneId -ZoneName $ZoneName
  if (-not $ZoneId) { Abort "could not fetch zone id for $ZoneName" }
}

$headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
$lookupUri = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?type=A&name=$Hostname"
$recordLookup = Invoke-RestMethod -Method Get -Uri $lookupUri -Headers $headers -ErrorAction SilentlyContinue

$recordId = $null
$currentCloudflareIP = $null
$recordProxied = $false

if ($recordLookup -and $recordLookup.success -and $recordLookup.result -and $recordLookup.result.Count -gt 0) {
  $recordId = $recordLookup.result[0].id
  $currentCloudflareIP = $recordLookup.result[0].content
  $recordProxied = [bool]$recordLookup.result[0].proxied
}

if ($currentCloudflareIP -and $currentCloudflareIP -eq $LocalIP) {
  Write-Host "Cloudflare DNS for $Hostname already set to $LocalIP; no update needed."
  exit 0
}

$payload = @{
  type    = "A"
  name    = $Hostname
  content = $LocalIP
  ttl     = 45
  proxied = $recordProxied
} | ConvertTo-Json

$currentDisplay = if ($currentCloudflareIP) { $currentCloudflareIP } else { '<none>' }

if ($recordId) {
  Write-Host "Updating ${Hostname}: $currentDisplay -> $LocalIP"
  $updateUri = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$recordId"
  $updateResp = Invoke-RestMethod -Method Put -Uri $updateUri -Headers $headers -Body $payload -ErrorAction SilentlyContinue
} else {
  Write-Host "Creating A record for $Hostname -> $LocalIP"
  $createUri = "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records"
  $updateResp = Invoke-RestMethod -Method Post -Uri $createUri -Headers $headers -Body $payload -ErrorAction SilentlyContinue
}

if ($updateResp -and $updateResp.success) {
  Write-Host "Cloudflare record updated successfully."
  exit 0
}

$errMsg = if ($updateResp -and $updateResp.errors) {
  ($updateResp.errors | ForEach-Object { $_.message }) -join "; "
} else {
  "unknown error"
}
Abort "Cloudflare API call failed: $errMsg"
