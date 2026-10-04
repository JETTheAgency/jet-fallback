# JET DNS failover: point a domain at the Vercel fallback page during a hosting outage,
# and restore the original records afterward.
#
#   ON  : .\failover.ps1 -Domain jettheagency.com -Mode on
#   OFF : .\failover.ps1 -Domain jettheagency.com -Mode off
#   Add -DryRun to see what would happen without changing anything.
#
# What it does:
#   on  = backs up the current apex + www DNS records to backup-<domain>.json,
#         then replaces them with Vercel's records (A 76.76.21.21 / CNAME cname.vercel-dns.com),
#         DNS-only (not proxied), TTL 300, per Vercel's own guidance for Cloudflare-managed DNS.
#   off = deletes the failover records and restores the backed-up originals exactly.
#
# Requires a Cloudflare API token with Zone.Zone Read + Zone.DNS Edit on the zone, stored at:
#   $env:USERPROFILE\.claude\secrets\cloudflare-jet-dns-token.txt

param(
    [Parameter(Mandatory = $true)][ValidateSet("jettheagency.com", "jet.furniture")][string]$Domain,
    [Parameter(Mandatory = $true)][ValidateSet("on", "off")][string]$Mode,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$TokenPath = Join-Path $env:USERPROFILE ".claude\secrets\cloudflare-jet-dns-token.txt"
$BackupPath = Join-Path $PSScriptRoot "backup-$Domain.json"
$VercelA = "76.76.21.21"
$VercelCname = "cname.vercel-dns.com"

if (-not (Test-Path $TokenPath)) { throw "Token file not found: $TokenPath" }
$Token = (Get-Content $TokenPath -Raw).Trim()
$Headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
$Api = "https://api.cloudflare.com/client/v4"

function Invoke-CF($Method, $Path, $Body = $null) {
    $args = @{ Method = $Method; Uri = "$Api$Path"; Headers = $Headers }
    if ($Body) { $args.Body = ($Body | ConvertTo-Json -Depth 10) }
    $resp = Invoke-RestMethod @args
    if (-not $resp.success) { throw "Cloudflare API error on $Method $Path : $($resp.errors | ConvertTo-Json -Compress)" }
    return $resp.result
}

# Verify the token before touching anything.
$verify = Invoke-CF GET "/user/tokens/verify"
if ($verify.status -ne "active") { throw "Cloudflare token status is '$($verify.status)', not active. Mint a fresh token first." }

$zone = Invoke-CF GET "/zones?name=$Domain"
if (-not $zone) { throw "Zone $Domain not visible to this token. Check the token's zone scope." }
$zoneId = $zone[0].id
Write-Host "Zone $Domain = $zoneId"

$names = @($Domain, "www.$Domain")
$current = @()
foreach ($n in $names) {
    foreach ($t in @("A", "AAAA", "CNAME")) {
        $current += @(Invoke-CF GET "/zones/$zoneId/dns_records?type=$t&name=$n")
    }
}
Write-Host "Current apex/www records: $($current.Count)"
$current | ForEach-Object { Write-Host ("  {0,-6} {1,-28} -> {2}  (proxied: {3})" -f $_.type, $_.name, $_.content, $_.proxied) }

if ($Mode -eq "on") {
    if ($DryRun) {
        Write-Host "[DryRun] Would back up the records above to $BackupPath, delete them, and create:"
        Write-Host "[DryRun]   A     $Domain -> $VercelA (DNS only, TTL 300)"
        Write-Host "[DryRun]   CNAME www.$Domain -> $VercelCname (DNS only, TTL 300)"
        exit 0
    }
    # Refuse to overwrite an existing backup: it holds the real origin records, and 'on' twice
    # in a row would replace it with the failover records, making 'off' restore the wrong thing.
    if (Test-Path $BackupPath) { throw "Backup already exists at $BackupPath. Failover looks already ON. Run -Mode off first, or move the backup away deliberately." }
    $current | ConvertTo-Json -Depth 10 | Set-Content $BackupPath
    Write-Host "Backed up $($current.Count) records to $BackupPath"

    foreach ($r in $current) { Invoke-CF DELETE "/zones/$zoneId/dns_records/$($r.id)" | Out-Null }
    Invoke-CF POST "/zones/$zoneId/dns_records" @{ type = "A"; name = $Domain; content = $VercelA; ttl = 300; proxied = $false } | Out-Null
    Invoke-CF POST "/zones/$zoneId/dns_records" @{ type = "CNAME"; name = "www.$Domain"; content = $VercelCname; ttl = 300; proxied = $false } | Out-Null
    Write-Host "FAILOVER ON for $Domain. The fallback page takes over as caches expire (TTL was 300s or less)."
    Write-Host "Vercel will issue the TLS certificate on first traffic; allow a minute or two."
}
else {
    if (-not (Test-Path $BackupPath)) { throw "No backup found at $BackupPath. Cannot restore without it." }
    $saved = Get-Content $BackupPath -Raw | ConvertFrom-Json
    if ($DryRun) {
        Write-Host "[DryRun] Would delete the current apex/www records and restore these from backup:"
        $saved | ForEach-Object { Write-Host ("[DryRun]   {0,-6} {1,-28} -> {2}  (proxied: {3})" -f $_.type, $_.name, $_.content, $_.proxied) }
        exit 0
    }
    foreach ($r in $current) { Invoke-CF DELETE "/zones/$zoneId/dns_records/$($r.id)" | Out-Null }
    foreach ($r in $saved) {
        Invoke-CF POST "/zones/$zoneId/dns_records" @{ type = $r.type; name = $r.name; content = $r.content; ttl = $r.ttl; proxied = $r.proxied } | Out-Null
    }
    Rename-Item $BackupPath "$BackupPath.restored-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "FAILOVER OFF for $Domain. Original records restored; backup archived."
}
