<#
.SYNOPSIS
    Intune remediation script - sets Wi-Fi roaming aggressiveness on Intel and
    Realtek adapters to a fixed target level.

.DESCRIPTION
    For use as the "Remediation script" in an Intune "Scripts and
    remediations" policy, paired with Detect-WifiRoaming.ps1. Can also be
    pushed on its own as a Platform script for a one-time push (in that case
    the detection logic is not needed).

    Runs as SYSTEM, takes no parameters (Intune does not pass arguments to
    remediation scripts), writes the registry value matching $TargetLevel on
    every Wi-Fi adapter that exposes RegRoamLevel (Realtek) or
    RoamAggressiveness (Intel), then reads the value back to confirm it was
    applied. No other adapter setting is touched.

    Exit codes (used by Intune to mark the remediation succeeded/failed):
      0 = success (no Wi-Fi adapter present, already compliant, or fixed)
      1 = at least one adapter failed to apply or failed verification

    Set $TargetLevel below to the same value used in Detect-WifiRoaming.ps1.

.NOTES
    Deploy as: Remediation script, in the same Intune remediation as
    Detect-WifiRoaming.ps1. "Run this script using the logged-on
    credentials": No (must run as SYSTEM to change adapter settings).
    The adapter is restarted to apply the change ($NoRestart = $false below),
    which briefly drops Wi-Fi on the device - schedule accordingly.
#>

# ============================================================
# CONFIGURATION - keep in sync with Detect-WifiRoaming.ps1
# ============================================================
$TargetLevel      = 'Lowest'   # Disable | Lowest | MediumLow | Medium | MediumHigh | Highest
$NoRestart        = $false        # $true = do not restart the adapter (change applies after next reboot)
$VerifyTimeoutSec = 20

$LogDir  = Join-Path $env:ProgramData 'IntuneWifiRoaming'
$LogFile = Join-Path $LogDir 'WifiRoaming.log'

# ============================================================

$Maps = @{
    'RegRoamLevel'       = @{   # Realtek
        Family = 'Realtek'
        Values = @{ Disable = 0; Lowest = 1; MediumLow = 2; Medium = 3; MediumHigh = 4; Highest = 5 }
    }
    'RoamAggressiveness' = @{   # Intel
        Family = 'Intel'
        Values = @{ Lowest = 0; MediumLow = 1; Medium = 2; MediumHigh = 3; Highest = 4 }
    }
}

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Remediate] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch { }
}

function Get-RoamValue {
    param([string]$Name, [string]$Keyword)
    $prop = Get-NetAdapterAdvancedProperty -Name $Name -RegistryKeyword $Keyword -ErrorAction SilentlyContinue
    if ($prop) {
        return [pscustomobject]@{
            Registry = "$(@($prop.RegistryValue)[0])"
            Display  = $prop.DisplayValue
        }
    }
    return $null
}

Write-Log "Remediation started. TargetLevel=$TargetLevel NoRestart=$NoRestart"

try {
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PhysicalMediaType -match '802\.11' -or
            $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11'
        }
}
catch {
    Write-Log "ERROR enumerating adapters: $($_.Exception.Message)"
    Write-Output "ERROR enumerating adapters: $($_.Exception.Message)"
    exit 1
}

if (-not $adapters) {
    Write-Log "No Wi-Fi adapter found. Nothing to do."
    Write-Output "No Wi-Fi adapter found."
    exit 0
}

$failed = 0

foreach ($ad in $adapters) {

    $adapterFound = $false

    foreach ($keyword in $Maps.Keys) {

        $before = Get-RoamValue -Name $ad.Name -Keyword $keyword
        if (-not $before) { continue }

        $adapterFound = $true
        $map    = $Maps[$keyword]
        $target = $map.Values[$TargetLevel]

        if ($null -eq $target) {
            Write-Log "[$($ad.Name)] ${keyword}: level '$TargetLevel' not applicable to $($map.Family), skipped."
            continue
        }

        if ($before.Registry -eq "$target") {
            Write-Log "[$($ad.Name)] $keyword already at $target ($($before.Display))."
            continue
        }

        try {
            $splat = @{
                Name            = $ad.Name
                RegistryKeyword = $keyword
                RegistryValue   = "$target"
                ErrorAction     = 'Stop'
            }
            if ($NoRestart) { $splat['NoRestart'] = $true }
            Set-NetAdapterAdvancedProperty @splat
        }
        catch {
            Write-Log "[$($ad.Name)] FAILED to set ${keyword}: $($_.Exception.Message)"
            Write-Output "[$($ad.Name)] Failed to set ${keyword}: $($_.Exception.Message)"
            $failed++
            continue
        }

        # Verify: read the value back (retry while the adapter restarts)
        $after    = $null
        $deadline = (Get-Date).AddSeconds($VerifyTimeoutSec)
        do {
            Start-Sleep -Seconds 1
            $after = Get-RoamValue -Name $ad.Name -Keyword $keyword
            if ($after -and $after.Registry -eq "$target") { break }
        } while ((Get-Date) -lt $deadline)

        if ($after -and $after.Registry -eq "$target") {
            Write-Log "[$($ad.Name)] ${keyword}: $($before.Registry) -> $($after.Registry) VERIFIED (driver shows '$($after.Display)')."
            Write-Output "[$($ad.Name)] $keyword set to $target and verified."
        }
        else {
            $seen = if ($after) { "$($after.Registry) ($($after.Display))" } else { 'unreadable' }
            Write-Log "[$($ad.Name)] $keyword verification FAILED: expected $target, read $seen."
            Write-Output "[$($ad.Name)] $keyword verification failed: expected $target, read $seen."
            $failed++
        }
    }

    if (-not $adapterFound) {
        Write-Log "[$($ad.Name)] $($ad.InterfaceDescription): neither RegRoamLevel nor RoamAggressiveness exposed, skipped."
    }
}

if ($failed -gt 0) {
    Write-Log "Remediation finished with $failed failure(s)."
    exit 1
}

Write-Log "Remediation finished successfully."
Write-Output "Done."
exit 0
