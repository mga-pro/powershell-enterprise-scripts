<#
.SYNOPSIS
    Sets the Wi-Fi roaming aggressiveness on Intel and Realtek adapters.

.DESCRIPTION
    Detects the Wi-Fi adapters, finds the roaming registry keyword exposed by
    each driver, writes the registry value matching the requested -Level, then
    reads the value back to confirm it was applied.

    Registry keywords and values used:

      Realtek - RegRoamLevel
        0 = 1. Disable
        1 = 2. Lowest
        2 = 3. Medium-Low
        3 = 4. Medium
        4 = 5. Medium-High
        5 = 6. Highest

      Intel - RoamAggressiveness
        0 = 1. Min
        1 = 2. Low
        2 = 3. Medium
        3 = 4. High
        4 = 5. Max
        (display labels depend on the driver language)

    Only these two keywords are modified. Any other adapter setting is left
    untouched.

.PARAMETER Level
    Disable     Realtek only: roaming disabled (skipped on Intel).
    Lowest      Least aggressive (Realtek 1 / Intel 0).
    MediumLow   Realtek 2 / Intel 1.
    Medium      Realtek 3 / Intel 2.
    MediumHigh  Realtek 4 / Intel 3.
    Highest     Most aggressive (Realtek 5 / Intel 4).

.PARAMETER List
    Displays the detected roaming settings without changing anything.

.PARAMETER NoRestart
    Does not restart the adapter after the change (no Wi-Fi drop, but the
    setting only takes effect after an adapter or PC restart).

.PARAMETER AdapterName
    Restricts the action to one adapter (name shown by Get-NetAdapter, e.g. "Wi-Fi").

.PARAMETER VerifyTimeoutSec
    Maximum time in seconds to wait for the new value to be readable after the
    change (the adapter may restart). Default: 15.

.PARAMETER Help
    Shows this help text and exits. Running the script with no parameters at
    all does the same thing.

.EXAMPLE
    .\Set-WifiRoaming.ps1 -Help

.EXAMPLE
    .\Set-WifiRoaming.ps1 -List

.EXAMPLE
    .\Set-WifiRoaming.ps1 -Level Lowest -WhatIf

.EXAMPLE
    .\Set-WifiRoaming.ps1 -Level MediumLow

.NOTES
    Run from an elevated (administrator) PowerShell console.
    Exit codes: 0 = success, 1 = not elevated, 2 = no Wi-Fi adapter found,
    3 = at least one change failed or could not be verified.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Disable', 'Lowest', 'MediumLow', 'Medium', 'MediumHigh', 'Highest')]
    [string]$Level = 'MediumLow',

    [switch]$List,
    [switch]$NoRestart,
    [string]$AdapterName,
    [int]$VerifyTimeoutSec = 15,
    [switch]$Help
)

# --- Help: explicit -Help, or no parameter at all was passed on the command line ---
if ($Help -or $PSBoundParameters.Count -eq 0) {
    Get-Help -Full $PSCommandPath
    exit 0
}

# --- Level -> registry value tables ---
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

# --- Administrator check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $List -and -not $WhatIfPreference) {
    Write-Error "This script must be run from an elevated PowerShell console."
    exit 1
}

# --- Wi-Fi adapter detection ---
$adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object {
        $_.PhysicalMediaType -match '802\.11' -or
        $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11'
    }

if ($AdapterName) { $adapters = $adapters | Where-Object Name -eq $AdapterName }

if (-not $adapters) {
    Write-Warning "No Wi-Fi adapter found."
    exit 2
}

# Reads the current registry value of a keyword on an adapter (returns $null on failure).
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

$results = @()
$failed  = 0

foreach ($ad in $adapters) {

    $found = $false

    foreach ($keyword in $Maps.Keys) {

        $before = Get-RoamValue -Name $ad.Name -Keyword $keyword
        if (-not $before) { continue }

        $found  = $true
        $map    = $Maps[$keyword]
        $target = $map.Values[$Level]

        $row = [pscustomobject]@{
            Adapter      = $ad.Name
            Family       = $map.Family
            Keyword      = $keyword
            Before       = "$($before.Registry) ($($before.Display))"
            Target       = $(if ($null -ne $target) { "$target" } else { 'n/a' })
            After        = ''
            Status       = ''
        }

        if ($List) {
            $row.After  = '-'
            $row.Status = 'LIST'
            $results += $row
            continue
        }

        if ($null -eq $target) {
            Write-Warning "[$($ad.Name)] Level '$Level' is not available for $($map.Family): skipped."
            $row.After  = '-'
            $row.Status = 'SKIPPED'
            $results += $row
            continue
        }

        if ($before.Registry -eq "$target") {
            Write-Host "[$($ad.Name)] $keyword already set to $target." -ForegroundColor DarkGray
            $row.After  = "$($before.Registry) ($($before.Display))"
            $row.Status = 'UNCHANGED'
            $results += $row
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("$($ad.Name) / $keyword", "$($before.Registry) -> $target ($Level)")) {
            $row.After  = '-'
            $row.Status = 'WHATIF'
            $results += $row
            continue
        }

        # --- Apply ---
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
            Write-Warning "[$($ad.Name)] Failed to set ${keyword}: $($_.Exception.Message)"
            $row.After  = '-'
            $row.Status = 'FAILED'
            $results += $row
            $failed++
            continue
        }

        # --- Verify: read the value back (retry while the adapter restarts) ---
        $after    = $null
        $deadline = (Get-Date).AddSeconds($VerifyTimeoutSec)
        do {
            Start-Sleep -Seconds 1
            $after = Get-RoamValue -Name $ad.Name -Keyword $keyword
            if ($after -and $after.Registry -eq "$target") { break }
        } while ((Get-Date) -lt $deadline)

        if ($after -and $after.Registry -eq "$target") {
            Write-Host ("[{0}] {1}: {2} -> {3} VERIFIED (driver shows: '{4}')" -f `
                $ad.Name, $keyword, $before.Registry, $after.Registry, $after.Display) -ForegroundColor Green
            $row.After  = "$($after.Registry) ($($after.Display))"
            $row.Status = 'VERIFIED'
        }
        else {
            $seen = if ($after) { "$($after.Registry) ($($after.Display))" } else { 'unreadable' }
            Write-Warning "[$($ad.Name)] $keyword verification FAILED: expected $target, read $seen."
            $row.After  = $seen
            $row.Status = 'MISMATCH'
            $failed++
        }
        $results += $row
    }

    if (-not $found) {
        Write-Warning "[$($ad.Name)] $($ad.InterfaceDescription): neither RegRoamLevel nor RoamAggressiveness is exposed by the driver, adapter skipped."
    }
}

# --- Summary ---
if ($results) {
    Write-Host "`nRoaming settings:" -ForegroundColor Cyan
    $results | Format-Table -AutoSize -Wrap
}

if (-not $List -and -not $NoRestart -and -not $WhatIfPreference -and $results) {
    Write-Host "Note: Wi-Fi may have dropped for a few seconds (adapter restart)." -ForegroundColor Yellow
}

if ($failed -gt 0) { exit 3 }
