<#
.SYNOPSIS
    Intune detection script - checks Wi-Fi roaming aggressiveness on Intel and
    Realtek adapters against the configured target level.

.DESCRIPTION
    For use as the "Detection script" in an Intune "Scripts and remediations"
    (proactive remediation) policy, or as a standalone compliance check.

    Runs as SYSTEM, takes no parameters (Intune does not pass arguments to
    detection scripts), and only inspects the RegRoamLevel (Realtek) and
    RoamAggressiveness (Intel) registry keywords. No other adapter setting is
    read or changed.

    Exit codes (required by Intune):
      0 = compliant     (no Wi-Fi adapter present, or all detected adapters
                          already match the target level)
      1 = non-compliant (at least one adapter needs remediation)

    Set $TargetLevel below to the same value used in Remediate-WifiRoaming.ps1.

.NOTES
    Deploy as: Detection script, in the same Intune remediation as
    Remediate-WifiRoaming.ps1. "Run this script using the logged-on
    credentials": No. "Enforce script signature check": per your policy.
#>

# ============================================================
# CONFIGURATION - keep in sync with Remediate-WifiRoaming.ps1
# ============================================================
$TargetLevel = 'Lowest'   # Disable | Lowest | MediumLow | Medium | MediumHigh | Highest

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
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [Detect] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
    } catch { }
}

Write-Log "Detection started. TargetLevel=$TargetLevel"

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
    Write-Log "No Wi-Fi adapter found. Compliant (nothing to do)."
    Write-Output "No Wi-Fi adapter found."
    exit 0
}

$nonCompliant = @()

foreach ($ad in $adapters) {

    $adapterFound = $false

    foreach ($keyword in $Maps.Keys) {

        $prop = Get-NetAdapterAdvancedProperty -Name $ad.Name -RegistryKeyword $keyword -ErrorAction SilentlyContinue
        if (-not $prop) { continue }

        $adapterFound = $true
        $map     = $Maps[$keyword]
        $target  = $map.Values[$TargetLevel]
        $current = "$(@($prop.RegistryValue)[0])"

        if ($null -eq $target) {
            # e.g. 'Disable' requested on an Intel card: nothing to compare against, skip.
            Write-Log "[$($ad.Name)] ${keyword}: level '$TargetLevel' not applicable to $($map.Family), skipped."
            continue
        }

        if ($current -eq "$target") {
            Write-Log "[$($ad.Name)] $keyword OK ($current == $target)."
        }
        else {
            Write-Log "[$($ad.Name)] $keyword MISMATCH: current=$current target=$target"
            $nonCompliant += "$($ad.Name) ($($map.Family)/$keyword): current=$current expected=$target"
        }
    }

    if (-not $adapterFound) {
        Write-Log "[$($ad.Name)] $($ad.InterfaceDescription): neither RegRoamLevel nor RoamAggressiveness exposed, skipped."
    }
}

if ($nonCompliant.Count -gt 0) {
    $msg = "Non-compliant: " + ($nonCompliant -join '; ')
    Write-Log $msg
    Write-Output $msg
    exit 1
}

Write-Log "All detected adapters compliant."
Write-Output "Compliant."
exit 0
