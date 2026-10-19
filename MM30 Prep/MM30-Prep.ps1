#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Prepares a Windows 11 PC before running BAPCo MobileMark 30 Professional (v1.0.0.14).

.DESCRIPTION
  Automates the manual pre-benchmark tuning while staying within the BAPCo
  Run Rules (v1.0):
    - no modification of the MobileMark software, no driver "optimized for MM30"
    - brightness >= 250 cd/m2 (measured with the Brightness Profiler, NOT by this script)
    - Windows Power Mode slider identical for the whole test
    - Battery Saver threshold <= 20 % and "Lower screen brightness in battery saver" unchecked
    - no sleep / hibernate (Modern Standby is allowed: it is the 5-min idle of each iteration)
    - every non-standard setting is listed at the end of the script -> document it with the FDR

  Everything is backed up to C:\MM30Prep\state.clixml and can be reverted with -Mode Restore.
  The MM30 Config Tool (Required / Recommended) already handles: UAC off, DPI 100 %, low battery
  actions, proxies, sleep/hibernate, Windows Update, WinSAT, "BAPCo MobileMark 30" power plan,
  CPU adaptive 5/100, lock screen, screensaver, font smoothing... This script COMPLEMENTS those
  settings and does not replace them (keep the Config Tool on "Recommended = ON").

  CONFIGURATION
  Every parameter can be set in a JSON file named MM30-Prep.config placed next to the script
  (or any file passed with -ConfigPath). Precedence: built-in defaults < config file < command line.
  Keys starting with "_" are comments. Use -Mode WriteConfig to generate a config file from the
  current effective values. Use -NoConfig to ignore the config file.

.NOTES
  Script  : MM30-Prep
  Version : 0.5
  Changelog:
    0.5 - Taskbar/shell: hides Widgets and Task view, disables Resume; when Windows blocks the registry value
          (Widgets button and policy are protected on recent builds) the Settings page is driven through UI
          Automation; the dark/light theme is now broadcast to Explorer (taskbar included) and Explorer is
          restarted once at the end; no more transcript noise from registry/task probing; new options
          HideWidgets, HideTaskView, DisableResume, RestartExplorer, UseSettingsUiFallback, RemoveWidgetsApp,
          ThemeAccentOnTaskbar.
    0.4 - JSON config file (MM30-Prep.config) for every parameter; new modes Language and WriteConfig;
          installs the en-US language pack if missing and makes it the default language while keeping
          the French AZERTY (legacy) keyboard; a single passwordless local account counts as auto-logon;
          default brightness 83 %; Power Mode configurable separately for DC and AC; log prefix is [Info];
          prerequisite thresholds, noisy services/tasks and Defender exclusions are configurable.
    0.3 - Protected objects: SYSTEM fallback (one-shot scheduled task) for protected services (DoSvc),
          scheduled tasks (UpdateOrchestrator...) and HKLM keys (power overlay); values already at target
          are skipped; backups only recorded after a successful change; Widgets hidden through policy
          only (TaskbarDa is blocked by Windows 11); bundled MM30 apps (Office/Photoshop/WinZip) no longer
          flagged once MobileMark is installed; CPU 2 GHz check is informational (boost clock counts).
    0.2 - Fix parser error in powercfg warning message ($setting: parsed as a drive-qualified variable).
    0.1 - Initial version: Check / PreInstall / PreRun / Restore modes, per-model brightness map,
          configurable Battery Saver threshold, English comments and on-screen messages (ASCII only).

.PARAMETER Mode
  Check       : report prerequisites and current state, no change (default)
  PreInstall  : prerequisites + language + remove UWP Office apps + Defender exclusions + time resync
  PreRun      : full optimization (run right before starting MM30, on AC power)
  Language    : only install/activate the language pack and keyboard layout (needs Internet)
  Restore     : revert everything to the original state (the language pack itself stays installed)
  WriteConfig : write the effective settings to the config file and exit

.PARAMETER ConfigPath
  JSON config file. Default: MM30-Prep.config next to the script (used only if it exists).

.PARAMETER BrightnessPercent
  Windows brightness in % (DC), default 83. The % -> cd/m2 relation is specific to each panel!
  Measure with the Brightness Profiler (button in the MM30 Verification screen)
  and adjust. Never go below 250 cd/m2 during the test.

.PARAMETER BrightnessMap
  Object { "Model (WMI substring)": percent } to set brightness per model (JSON object in the config file).
  Example: { "UX3405MA": 62, "UM3406": 55, "B5405CVA": 70 }
  The model is matched (partial match) against Win32_ComputerSystem.Model. BrightnessMapPath does the
  same from a separate JSON file.

.PARAMETER PowerMode
  Windows 11 Power Mode slider (Efficiency, Balanced, BetterPerformance, Performance), applied to both
  battery (DC) and plugged-in (AC) unless PowerModeDC / PowerModeAC are set. BetterPerformance is the
  "Better performance" overlay (3af9B8d9-...), not shown on every Windows 11 build.

.PARAMETER BatterySaverThreshold
  Charge level (%) at which Battery Saver kicks in. 0 = never, 20 = maximum allowed by the Run Rules.

.PARAMETER HideWidgets
  Hide the Widgets button (and disable Widgets by policy when Windows allows it).

.PARAMETER HideTaskView
  Hide the Task view button of the taskbar.

.PARAMETER DisableResume
  Turn off Settings > Apps > Resume (cross-device resume).

.PARAMETER RestartExplorer
  Restart Explorer once after the shell changes so that the taskbar picks up the theme and button changes.

.PARAMETER UseSettingsUiFallback
  When Windows blocks a taskbar registry value, toggle the switch in Settings > Personalization > Taskbar
  through UI Automation (needs the English display language and an interactive session).

.PARAMETER RemoveWidgetsApp
  Uninstall the Windows Web Experience Pack (Widgets) for all users. Not reverted by -Mode Restore.

.PARAMETER ThemeAccentOnTaskbar
  Keep the accent color on the taskbar when Theme is Dark or Light (default false: taskbar follows the theme).

.PARAMETER KeyboardKlid
  Keyboard layout identifier added to the default language. 0000040C = French AZERTY (legacy "French").

.PARAMETER AcceptPasswordlessSingleUser
  When true, a single enabled local account without password counts as auto-logon enabled.

.PARAMETER Aggressive
  Enables -DisableNetwork -DisableBluetooth -DefenderRealtimeOff (if Tamper Protection is OFF).

.EXAMPLE
  .\MM30-Prep.ps1 -Mode Check
  .\MM30-Prep.ps1 -Mode WriteConfig
  .\MM30-Prep.ps1 -Mode Language
  .\MM30-Prep.ps1 -Mode PreInstall
  .\MM30-Prep.ps1 -Mode PreRun
  .\MM30-Prep.ps1 -Mode PreRun -BrightnessPercent 65 -PowerModeDC Balanced -PowerModeAC Performance
  .\MM30-Prep.ps1 -Mode PreRun -ConfigPath D:\cfg\lab.config -Aggressive
  .\MM30-Prep.ps1 -Mode Restore
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','PreInstall','PreRun','Language','Restore','WriteConfig')]
    [string]$Mode = 'Check',
    [string]$ConfigPath,
    [switch]$NoConfig,

    # --- General ---
    [string]$WorkDir = 'C:\MM30Prep',

    # --- Display / audio ---
    [ValidateRange(1,100)][int]$BrightnessPercent = 83,
    [string]$BrightnessMapPath,
    [object]$BrightnessMap = $null,
    [switch]$SkipBrightness,
    [ValidateRange(0,100)][int]$Volume = 50,
    [ValidateSet('Keep','Light','Dark')][string]$Theme = 'Keep',
    [bool]$ThemeAccentOnTaskbar = $false,

    # --- Power ---
    [ValidateSet('Efficiency','Balanced','BetterPerformance','Performance')][string]$PowerMode = 'Balanced',
    [ValidateSet('Efficiency','Balanced','BetterPerformance','Performance')][string]$PowerModeDC,
    [ValidateSet('Efficiency','Balanced','BetterPerformance','Performance')][string]$PowerModeAC,
    [ValidateRange(0,20)][int]$BatterySaverThreshold = 20,   # charge % at which Battery Saver activates; 0 = never; Run Rules maximum = 20
    [ValidateRange(0,100)][int]$MinProcessorStateDC = 5,
    [ValidateRange(1,100)][int]$MaxProcessorStateDC = 100,
    [Nullable[int]]$CpuEppDC = $null,          # 0 (performance) .. 100 (efficiency); $null = leave untouched
    [Nullable[int]]$CpuBoostModeDC = $null,    # 0 disabled .. 2 aggressive; $null = leave untouched

    # --- Language / keyboard ---
    [bool]$ManageLanguage = $true,
    [string]$LanguageTag = 'en-US',
    [string]$KeyboardKlid = '0000040C',        # French AZERTY (legacy "French" layout)
    [string[]]$ExtraLanguages = @(),           # additional language tags kept after the default one
    [bool]$SetSystemLocale = $true,
    [Nullable[int]]$HomeLocationGeoId = $null, # e.g. 84 = France, 244 = United States; $null = leave untouched
    [bool]$CopyLanguageToSystem = $true,       # copy settings to the welcome screen and new accounts

    # --- Taskbar / shell ---
    [bool]$HideWidgets = $true,
    [bool]$HideTaskView = $true,
    [bool]$DisableResume = $true,
    [bool]$RestartExplorer = $true,
    [bool]$UseSettingsUiFallback = $true,
    [switch]$RemoveWidgetsApp,

    # --- Logon ---
    [bool]$AcceptPasswordlessSingleUser = $true,

    # --- Prerequisite thresholds ---
    [int]$MinBuild = 22621,
    [int]$MinRamGB = 16,
    [int]$MinFreeDiskGB = 30,

    # --- Optimizations ---
    [switch]$KeepVisualEffects,
    [switch]$KeepSysMain,
    [switch]$NoSystemFallback,
    [string[]]$StartupPatterns = @('OneDrive*','*Teams*','MicrosoftEdgeAutoLaunch*','Skype*','Spotify*','Discord*','Steam*','Dropbox*','Zoom*','Webex*'),
    [string[]]$NoiseServices = @('DiagTrack','dmwappushservice','WerSvc','MapsBroker','RetailDemo','XblAuthManager','XblGameSave','XboxNetApiSvc','XboxGipSvc','lfsvc','wisvc','edgeupdate','edgeupdatem'),
    [string[]]$NoiseTasks = @(
        '\Microsoft\Windows\Defrag\|ScheduledDefrag',
        '\Microsoft\Windows\Application Experience\|*',
        '\Microsoft\Windows\Customer Experience Improvement Program\|*',
        '\Microsoft\Windows\DiskDiagnostic\|*',
        '\Microsoft\Windows\Windows Error Reporting\|*',
        '\Microsoft\Windows\UpdateOrchestrator\|*',
        '\Microsoft\Windows\WindowsUpdate\|*',
        '\Microsoft\Windows\WaaSMedic\|*',
        '\Microsoft\Windows\InstallService\|*',
        '\Microsoft\Windows\Maintenance\|*',
        '\Microsoft\Windows\Power Efficiency Diagnostics\|*',
        '\Microsoft\Windows\Diagnosis\|*',
        '\Microsoft\Windows\Chkdsk\|*',
        '\Microsoft\Windows\Registry\|*',
        '\Microsoft\Windows\Feedback\Siuf\|*',
        '\Microsoft\Windows\SystemRestore\|*',
        '\Microsoft\Windows\Windows Defender\|*',
        '\|OneDrive*',
        '\|MicrosoftEdgeUpdate*'
    ),
    [string[]]$UpdateServices = @('wuauserv','UsoSvc','DoSvc','BITS'),
    [string[]]$DefenderExclusionPaths = @('C:\Program Files (x86)\BAPCo','%USERPROFILE%\Desktop\Results','%PUBLIC%\Desktop\Results'),

    # --- Advanced options (document them with the FDR) ---
    [switch]$DisableNetwork,
    [switch]$DisableBluetooth,
    [switch]$DefenderRealtimeOff,
    [switch]$DisableMemoryIntegrity,
    [switch]$StopOemServices,
    [string[]]$OemServicePatterns = @('Asus*','ASUS*','Armoury*'),
    [switch]$Aggressive
)

$ScriptVersion = '0.5'
$script:BoundParams = $PSBoundParameters
$script:ConfigurableNames = @($MyInvocation.MyCommand.Parameters.Keys | Where-Object {
    ($_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters) -and
    ($_ -notin [System.Management.Automation.PSCmdlet]::OptionalCommonParameters) -and
    ($_ -notin 'Mode','ConfigPath','NoConfig') })
# sections used when writing the config file (every configurable parameter must appear once)
$script:ConfigSections = [ordered]@{
    General       = @('WorkDir')
    Display       = @('BrightnessPercent','BrightnessMapPath','BrightnessMap','SkipBrightness','Volume','Theme','ThemeAccentOnTaskbar')
    Power         = @('PowerMode','PowerModeDC','PowerModeAC','BatterySaverThreshold','MinProcessorStateDC','MaxProcessorStateDC','CpuEppDC','CpuBoostModeDC')
    Shell         = @('HideWidgets','HideTaskView','DisableResume','RestartExplorer','UseSettingsUiFallback','RemoveWidgetsApp')
    Language      = @('ManageLanguage','LanguageTag','KeyboardKlid','ExtraLanguages','SetSystemLocale','HomeLocationGeoId','CopyLanguageToSystem')
    Logon         = @('AcceptPasswordlessSingleUser')
    Checks        = @('MinBuild','MinRamGB','MinFreeDiskGB')
    Optimizations = @('KeepVisualEffects','KeepSysMain','NoSystemFallback','StartupPatterns','NoiseServices','NoiseTasks','UpdateServices','DefenderExclusionPaths')
    Advanced      = @('DisableNetwork','DisableBluetooth','DefenderRealtimeOff','DisableMemoryIntegrity','StopOemServices','OemServicePatterns','Aggressive')
}
$script:SectionHelp = @{
    General       = 'Work folder for the state backup (used by Restore) and the logs.'
    Display       = 'BrightnessPercent = Windows brightness in %. Measure cd/m2 with the MM30 Brightness Profiler: it must stay >= 250. BrightnessMap = { "Model substring": percent } overrides it per model (matched against the WMI model). BrightnessMapPath = same map in a separate JSON file.'
    Power         = 'PowerMode applies to battery (DC) and plugged-in (AC) unless PowerModeDC / PowerModeAC are set. Values: Efficiency, Balanced, BetterPerformance, Performance. BatterySaverThreshold: 0 = never, maximum 20 (Run Rules).'
    Shell         = 'Taskbar buttons (Widgets, Task view), Resume and theme refresh. Windows protects the Widgets values: the Settings page is used as a fallback, and Explorer is restarted once to apply everything.'
    Language      = 'Installs and activates LanguageTag (needs Internet). KeyboardKlid 0000040C = French AZERTY (legacy). ExtraLanguages are kept after the default one. HomeLocationGeoId: 84 = France, 244 = United States, null = untouched.'
    Logon         = 'AcceptPasswordlessSingleUser: a single enabled local account without password counts as auto-logon.'
    Checks        = 'Minimum Windows build, RAM (GB) and free space on C: (GB) used by the prerequisite checks.'
    Optimizations = 'Startup entries, services, scheduled tasks (TaskPath|NamePattern), Windows Update services and Defender exclusion paths (environment variables allowed) handled by PreRun.'
    Advanced      = 'Options that move away from the calibration setup: document them with the FDR. Aggressive = DisableNetwork + DisableBluetooth + DefenderRealtimeOff.'
}
$script:CfgMessages = @()

# ------------------------------------------------------------------ helpers
function Log  { param($m) Write-Host "[Info] $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

$script:Report = @()      # applied settings (to document with the FDR)
$script:ProtectedTasks = @()   # tasks that need the SYSTEM fallback
$script:RebootNeeded = $false
$script:ShellChanged = $false
$script:RegOk = $false
function Note { param($m) $script:Report += $m }

# ---- JSON config file: walk the object, sections are flattened, keys are parameter names
function Import-ConfigNode {
    param($Node)
    foreach ($p in $Node.PSObject.Properties) {
        $k = $p.Name; $v = $p.Value
        if ($k.StartsWith('_') -or $k -eq 'ConfigVersion') { continue }
        if ($script:ConfigurableNames -contains $k) {
            if ($script:BoundParams.ContainsKey($k)) { $script:CfgMessages += "INFO|Config key '$k' ignored: command-line value wins"; continue }
            if ($null -eq $v -or ($v -is [string] -and $v -eq '')) { continue }
            try { Set-Variable -Name $k -Value $v -Scope Script -ErrorAction Stop }
            catch { $script:CfgMessages += "WARN|Config key '$k' has an invalid value: $($_.Exception.Message)" }
        }
        elseif ($v -is [System.Management.Automation.PSCustomObject]) { Import-ConfigNode -Node $v }
        else { $script:CfgMessages += "WARN|Unknown config key ignored: $k" }
    }
}
function Write-PrepConfig {
    param([string]$Path)
    $cfg = [ordered]@{
        ConfigVersion = $ScriptVersion
        _comment      = 'MM30_Prep configuration. Keys starting with an underscore are comments. Precedence: defaults < this file < command line. See the script header for details.'
    }
    foreach ($sec in $script:ConfigSections.Keys) {
        $o = [ordered]@{ _comment = $script:SectionHelp[$sec] }
        foreach ($n in $script:ConfigSections[$sec]) {
            $v = Get-Variable -Name $n -ValueOnly -Scope Script -ErrorAction SilentlyContinue
            if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v.IsPresent }
            if ($v -is [string] -and $v -eq '') { $v = $null }
            if ($n -eq 'BrightnessMap' -and $null -eq $v) { $v = [ordered]@{} }
            $o[$n] = $v
        }
        $cfg[$sec] = $o
    }
    $json = $cfg | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}
function Show-ConfigMessages {
    foreach ($m in $script:CfgMessages) {
        $kind, $text = $m -split '\|', 2
        if ($kind -eq 'WARN') { Warn $text } else { Log $text }
    }
    $script:CfgMessages = @()
}

# ---- load the config file (defaults < config < command line)
$defaultConfig = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'MM30-Prep.config' } else { Join-Path (Get-Location).Path 'MM30-Prep.config' }
$cfgFile = $null
if (-not $NoConfig) {
    if ($ConfigPath) {
        if (Test-Path -LiteralPath $ConfigPath) { $cfgFile = $ConfigPath }
        elseif ($Mode -ne 'WriteConfig') { Fail "Config file not found: $ConfigPath"; exit 2 }
    }
    elseif (Test-Path -LiteralPath $defaultConfig) { $cfgFile = $defaultConfig }
}
if ($cfgFile) {
    try {
        $cfgObj = Get-Content -LiteralPath $cfgFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { Fail "Cannot read config file '$cfgFile': $($_.Exception.Message)"; exit 2 }
    $script:CfgMessages += "INFO|Config file loaded: $cfgFile"
    if ($cfgObj.ConfigVersion -and "$($cfgObj.ConfigVersion)" -ne $ScriptVersion) {
        $script:CfgMessages += "INFO|Config file written for version $($cfgObj.ConfigVersion), script is $ScriptVersion"
    }
    Import-ConfigNode -Node $cfgObj
} elseif (-not $NoConfig) {
    $script:CfgMessages += "INFO|No config file found, using built-in defaults and command line"
}
if ($Mode -eq 'WriteConfig') {
    $target = if ($ConfigPath) { $ConfigPath } else { $defaultConfig }
    Write-PrepConfig -Path $target
    Show-ConfigMessages
    Log "Config written: $target"
    exit 0
}

if ($Aggressive) { $DisableNetwork = $true; $DisableBluetooth = $true; $DefenderRealtimeOff = $true }

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$StatePath = Join-Path $WorkDir 'state.clixml'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
try { Start-Transcript -Path (Join-Path $WorkDir "MM30Prep_v${ScriptVersion}_${Mode}_$ts.log") | Out-Null } catch {}
Show-ConfigMessages

if (Test-Path $StatePath) { $State = Import-Clixml $StatePath }
else { $State = @{ Registry=@(); Services=@(); Tasks=@(); Adapters=@(); Bluetooth=@(); Exclusions=@(); Defender=$null; Power=$null; Language=$null; UiToggles=@() } }
if (-not $State.ContainsKey('Language')) { $State.Language = $null }
if (-not $State.ContainsKey('UiToggles')) { $State.UiToggles = @() }
function Save-State { $State | Export-Clixml -Path $StatePath }

# ---- Run a script as SYSTEM through a one-shot scheduled task (fallback for protected objects)
# Returns the script output (ending with a DONE marker) or $null on failure/timeout.
function Invoke-AsSystem {
    param([Parameter(Mandatory)][string]$ScriptText,[int]$TimeoutSec = 90)
    if ($NoSystemFallback) { return $null }
    $id  = 'MM30Prep_SYS_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $ps1 = Join-Path $WorkDir "$id.ps1"
    $out = Join-Path $WorkDir "$id.out"
    $wrapper = @(
        '$ErrorActionPreference = "Continue"',
        '$res = & {',
        $ScriptText,
        '} *>&1 | Out-String',
        "[IO.File]::WriteAllText('$out.tmp', (`$res + 'DONE'))",
        "Move-Item -LiteralPath '$out.tmp' -Destination '$out' -Force"
    ) -join "`r`n"
    try {
        Set-Content -Path $ps1 -Value $wrapper -Encoding ASCII
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ps1`""
        $princ  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $tset   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $id -Action $action -Principal $princ -Settings $tset -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $id -ErrorAction Stop
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path $out) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 500 }
        if (Test-Path $out) { return (Get-Content -Raw -Path $out) }
        return $null
    } catch {
        Warn "SYSTEM fallback failed: $($_.Exception.Message)"
        return $null
    } finally {
        Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ps1,$out,"$out.tmp" -Force -ErrorAction SilentlyContinue
    }
}

# ---- Registry with backup (skips values already at target, SYSTEM fallback for protected HKLM keys)
# Sets $script:RegOk to $true when the value ends up at the target. -Quiet skips the warning on failure.
function Set-Reg {
    param([string]$Path,[string]$Name,$Value,[string]$Type='DWord',[switch]$Quiet)
    $script:RegOk = $false
    $cur = $null; $had = $false
    $ip = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($ip -and ($ip.PSObject.Properties.Name -contains $Name)) { $cur = $ip.$Name; $had = $true }
    if ($had -and "$cur" -eq "$Value") { $script:RegOk = $true; return }
    $done = $false; $err = ''; $created = $false
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction SilentlyContinue -ErrorVariable ev | Out-Null
        if ($ev) { $err = $ev[0].Exception.Message } else { $created = $true }
    }
    if (-not $err) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction SilentlyContinue -ErrorVariable ev
        if ($ev) { $err = $ev[0].Exception.Message } else { $done = $true }
    }
    if (-not $done -and $Path -like 'HKLM:*' -and -not $NoSystemFallback) {
        $v = if ($Type -eq 'String') { "'" + ("$Value" -replace "'","''") + "'" } else { [string][int]$Value }
        $txt = "if (-not (Test-Path '$Path')) { New-Item -Path '$Path' -Force | Out-Null }; Set-ItemProperty -Path '$Path' -Name '$Name' -Value $v -Type $Type -Force"
        Invoke-AsSystem -ScriptText $txt | Out-Null
        $chk = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($chk -and ("$($chk.$Name)" -eq "$Value")) { $done = $true }
    }
    if ($done) {
        $key = "$Path|$Name"
        if (-not ($State.Registry | Where-Object { $_.Key -eq $key })) {
            $State.Registry += @{ Key=$key; Path=$Path; Name=$Name; Existed=$had; Value=$cur; Type=$Type }
        }
        if ($Path -like 'HKCU:*') { $script:ShellChanged = $true }
        $script:RegOk = $true
    } else {
        if ($created) { Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue }   # do not leave an empty key behind
        if (-not $Quiet) { Warn "Registry $Path\$Name : $err" }
    }
}

# ---- Services with backup (SYSTEM fallback for protected services such as DoSvc)
function Set-ServiceStart {
    param([string]$Name,[ValidateSet('auto','delayed-auto','demand','disabled')][string]$StartType)
    $want = switch ($StartType) { 'disabled' { 'Disabled' } 'demand' { 'Manual' } default { 'Auto' } }
    $regv = switch ($StartType) { 'disabled' { 4 } 'demand' { 3 } default { 2 } }
    & sc.exe config $Name start= $StartType | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $txt = "& sc.exe config '$Name' start= $StartType | Out-Null; if (`$LASTEXITCODE -ne 0) { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\$Name' -Name Start -Value $regv -Type DWord -Force }"
        Invoke-AsSystem -ScriptText $txt | Out-Null
    }
    $mode = (Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue).StartMode
    if ($mode -eq $want) { return $true }
    # registry-only change: effective after reboot
    $rv = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -ErrorAction SilentlyContinue).Start
    if ($rv -eq $regv) { $script:RebootNeeded = $true; return $true }
    return $false
}
function Set-SvcDisabled {
    param([string]$Name)
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $s) { return $false }
    if ($s.StartMode -eq 'Disabled') { return $true }
    $backup = @{ Name=$Name; Mode=$s.StartMode; Delayed=$s.DelayedAutoStart; WasRunning=($s.State -eq 'Running') }
    try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
    if (Set-ServiceStart -Name $Name -StartType disabled) {
        if (-not ($State.Services | Where-Object { $_.Name -eq $Name })) { $State.Services += $backup }
        return $true
    }
    Warn "Service $Name : could not be disabled, even as SYSTEM (left unchanged)"
    return $false
}

# ---- Scheduled tasks with backup (protected ones are retried in one batch as SYSTEM)
function Add-TaskBackup {
    param([string]$Path,[string]$Name)
    $full = "$Path$Name"
    if (-not ($State.Tasks | Where-Object { $_.Full -eq $full })) {
        $State.Tasks += @{ Full=$full; Path=$Path; Name=$Name }
    }
}
function Disable-Task {
    param([string]$Path,[string]$NamePattern)
    $tasks = Get-ScheduledTask -TaskPath $Path -TaskName $NamePattern -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        if ($t.State -eq 'Disabled') { continue }
        Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue | Out-Null
        $now = Get-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction SilentlyContinue
        if ($now -and $now.State -eq 'Disabled') { Add-TaskBackup -Path $t.TaskPath -Name $t.TaskName }
        else { $script:ProtectedTasks += [pscustomobject]@{ Path=$t.TaskPath; Name=$t.TaskName } }
    }
}
function Disable-ProtectedTasks {
    if ($script:ProtectedTasks.Count -eq 0) { return }
    if (-not $NoSystemFallback) {
        Log "Retrying $($script:ProtectedTasks.Count) protected task(s) as SYSTEM"
        $lines = foreach ($t in $script:ProtectedTasks) {
            $p = $t.Path.Replace("'","''"); $n = $t.Name.Replace("'","''")
            "try { Disable-ScheduledTask -TaskPath '$p' -TaskName '$n' -ErrorAction Stop | Out-Null } catch { 'FAIL: ' + `$_.Exception.Message }"
        }
        Invoke-AsSystem -ScriptText ($lines -join "`r`n") -TimeoutSec 120 | Out-Null
    }
    $left = @()
    foreach ($t in $script:ProtectedTasks) {
        $cur = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($cur -and $cur.State -eq 'Disabled') { Add-TaskBackup -Path $t.Path -Name $t.Name }
        elseif ($cur) { $left += "$($t.Path)$($t.Name)" }
    }
    if ($left.Count -gt 0) {
        Warn "$($left.Count) task(s) left enabled (protected by the OS): $($left -join '; ')"
        Warn "They only drive Windows Update / maintenance, which is disabled through services and policies."
    } else { Ok "Protected tasks disabled through the SYSTEM fallback" }
    $script:ProtectedTasks = @()
}

# ---- Audio (master volume)
function Set-MasterVolume {
    param([int]$Percent)
    if (-not ('MM30Audio' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int f(); int g(); int h(); int i();
  int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
  int j();
  int GetMasterVolumeLevelScalar(out float pfLevel);
  int k(); int l(); int m(); int n();
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
  int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public class MM30Audio {
  static IAudioEndpointVolume Vol() {
    var e = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
    IMMDevice d = null; Marshal.ThrowExceptionForHR(e.GetDefaultAudioEndpoint(0, 1, out d));
    IAudioEndpointVolume v = null; Guid g = typeof(IAudioEndpointVolume).GUID;
    Marshal.ThrowExceptionForHR(d.Activate(ref g, 23, 0, out v)); return v;
  }
  public static void Set(float level) { var v = Vol(); Marshal.ThrowExceptionForHR(v.SetMute(false, Guid.Empty)); Marshal.ThrowExceptionForHR(v.SetMasterVolumeLevelScalar(level, Guid.Empty)); }
  public static float Get() { float l; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out l)); return l; }
}
'@
    }
    try { [MM30Audio]::Set([single]($Percent/100)); Ok ("Master volume = {0} %" -f [math]::Round([MM30Audio]::Get()*100)) }
    catch { Warn "Volume : $($_.Exception.Message) (no audio device?)" }
}

# ---- Brightness
function Resolve-Brightness {
    $pct = $BrightnessPercent
    $maps = @()
    if ($BrightnessMap) { $maps += $BrightnessMap }
    if ($BrightnessMapPath -and (Test-Path $BrightnessMapPath)) { $maps += (Get-Content $BrightnessMapPath -Raw | ConvertFrom-Json) }
    if ($maps.Count -gt 0) {
        $model = (Get-CimInstance Win32_ComputerSystem).Model
        :search foreach ($map in $maps) {
            $props = if ($map -is [hashtable]) { $map.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name=$_.Key; Value=$_.Value } } } else { $map.PSObject.Properties }
            foreach ($p in $props) {
                if ($p.Name.StartsWith('_')) { continue }
                if ($model -like "*$($p.Name)*") { $pct = [int]$p.Value; Log "Brightness from map for '$model': $pct %"; break search }
            }
        }
    }
    return $pct
}
function Set-PanelBrightness {
    param([int]$Percent)
    try {
        $lv = (Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1).Level
        $target = ($lv | Where-Object { $_ -ge $Percent } | Select-Object -First 1)
        if ($null -eq $target) { $target = ($lv | Select-Object -Last 1) }
        $m = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
        Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = [byte]$target } | Out-Null
        Ok "Panel brightness = $target % (requested $Percent %)"
        return $target
    } catch { Warn "WMI brightness unavailable ($($_.Exception.Message)): set it manually"; return $Percent }
}

# ---- System info
function Get-BatteryInfo {
    $b    = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $full = Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
    $des  = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
    $health = $null
    if ($full -and $des -and $des.DesignedCapacity) { $health = [math]::Round(100 * $full.FullChargedCapacity / $des.DesignedCapacity) }
    [pscustomobject]@{ Present=[bool]$b; Charge=$b.EstimatedChargeRemaining; OnAC=($b.BatteryStatus -in 2,6,7,8,9,11); Health=$health }
}
function Get-TamperState { try { (Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch { $null } }

# ------------------------------------------------------------------ AUTO-LOGON
# A single enabled local account without password signs in straight to the desktop: same effect as auto-logon.
function Get-SinglePasswordlessUser {
    try { $users = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled }) } catch { return $null }
    if ($users.Count -ne 1) { return $null }
    $u = $users[0]
    if ($u.PrincipalSource -and "$($u.PrincipalSource)" -ne 'Local') { return $null }   # Microsoft account = has a password
    if (($u.PasswordRequired -eq $false) -or ($null -eq $u.PasswordLastSet)) { return $u.Name }
    return $null
}
function Show-AutoLogonStatus {
    $al = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
    if ($al -eq '1') { Ok "Auto-logon enabled (AutoAdminLogon)"; return }
    if ($AcceptPasswordlessSingleUser) {
        $name = Get-SinglePasswordlessUser
        if ($name) { Ok "Auto-logon equivalent: single enabled local account '$name' without password"; return }
    }
    Warn "Auto-logon NOT enabled (required: use netplwiz or Sysinternals Autologon, or keep a single local account without password; same admin account to install AND run)"
}

# ------------------------------------------------------------------ LANGUAGE
# Run an action with the Windows Update related services temporarily enabled (language packs come from Windows Update)
function Invoke-WithUpdateServices {
    param([scriptblock]$Action)
    $reverted = @()
    foreach ($n in $UpdateServices) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s -and $s.StartMode -eq 'Disabled') {
            if (Set-ServiceStart -Name $n -StartType demand) { $reverted += $n; Start-Service -Name $n -ErrorAction SilentlyContinue }
        }
    }
    try { & $Action }
    finally { foreach ($n in $reverted) { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue; Set-ServiceStart -Name $n -StartType disabled | Out-Null } }
}
function Get-LanguageStatus {
    $tag = $LanguageTag
    $st = [ordered]@{ Installed=$false; UiOk=$false; LocaleOk=$true; KeyboardOk=$false; Tip='' }
    try { if (Get-InstalledLanguage -Language $tag -ErrorAction Stop) { $st.Installed = $true } }
    catch { if (-not (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue)) { $st.Installed = ((Get-WinUserLanguageList).LanguageTag -contains $tag) } }
    $ov = $null; try { $ov = (Get-WinUILanguageOverride).Name } catch {}
    $st.UiOk = ($ov -eq $tag) -or ((Get-UICulture).Name -eq $tag)
    if ($SetSystemLocale) { $st.LocaleOk = ((Get-WinSystemLocale).Name -eq $tag) }
    $lcid = '{0:X4}' -f ([System.Globalization.CultureInfo]::GetCultureInfo($tag).KeyboardLayoutId)
    $st.Tip = "${lcid}:$KeyboardKlid"
    $first = @(Get-WinUserLanguageList) | Select-Object -First 1
    $st.KeyboardOk = [bool]($first -and $first.LanguageTag -eq $tag -and (@($first.InputMethodTips) -contains $st.Tip) -and (@($first.InputMethodTips).Count -eq 1))
    [pscustomobject]$st
}
function Show-LanguageStatus {
    if (-not $ManageLanguage) {
        $loc = (Get-WinSystemLocale).Name; $ui = (Get-UICulture).Name
        if ($loc -eq $LanguageTag -and $ui -eq $LanguageTag) { Ok "Language $LanguageTag" } else { Warn "System locale '$loc' / UI '$ui': MM30 1.0 only supports English (US)" }
        return
    }
    $st = Get-LanguageStatus
    if ($st.Installed)  { Ok "Language pack $LanguageTag installed" } else { Warn "Language pack $LanguageTag NOT installed (PreInstall, PreRun or Language mode installs it)" }
    if ($st.UiOk)       { Ok "Display language $LanguageTag" } else { Warn "Display language is not $LanguageTag (MM30 1.0 only supports English (US))" }
    if ($SetSystemLocale) { if ($st.LocaleOk) { Ok "System locale $LanguageTag" } else { Warn "System locale is not $LanguageTag" } }
    if ($st.KeyboardOk) { Ok "Default keyboard layout $($st.Tip) (KLID $KeyboardKlid)" } else { Warn "Keyboard layout is not $($st.Tip) (KLID $KeyboardKlid) as the only layout of the default language" }
}
function Get-LanguageBackup {
    $b = @{ Languages=@(); SystemLocale=$null; Culture=$null; UIOverride=$null; PreferredUI=$null; GeoId=$null; DefaultTip=$null }
    try { foreach ($l in (Get-WinUserLanguageList)) { $b.Languages += @{ Tag=$l.LanguageTag; Tips=@($l.InputMethodTips) } } } catch {}
    try { $b.SystemLocale = (Get-WinSystemLocale).Name } catch {}
    try { $b.Culture = (Get-Culture).Name } catch {}
    try { $b.UIOverride = (Get-WinUILanguageOverride).Name } catch {}
    try { $b.PreferredUI = @(Get-SystemPreferredUILanguage)[0] } catch {}
    try { $b.GeoId = (Get-WinHomeLocation).GeoId } catch {}
    try { $b.DefaultTip = "$(Get-WinDefaultInputMethodOverride)" } catch {}
    $b
}
function Install-LanguagePack {
    try {
        if (Get-Command Install-Language -ErrorAction SilentlyContinue) { Install-Language -Language $LanguageTag -ErrorAction Stop | Out-Null }
        else { Add-WindowsCapability -Online -Name "Language.Basic~~~${LanguageTag}~0.0.1.0" -ErrorAction Stop | Out-Null }
    } catch { Warn "Language pack installation failed: $($_.Exception.Message)" }
    return [bool](Get-LanguageStatus).Installed
}
function Invoke-LanguageSetup {
    if (-not $ManageLanguage) { Log "Language management disabled (ManageLanguage = false)"; return }
    Log "Language: $LanguageTag with keyboard layout KLID $KeyboardKlid"
    $st = Get-LanguageStatus
    if ($st.Installed -and $st.UiOk -and $st.LocaleOk -and $st.KeyboardOk) { Ok "Language $LanguageTag already installed and active, keyboard $($st.Tip)"; return }
    if (-not $State.Language) { $State.Language = Get-LanguageBackup; Save-State }
    $tag = $LanguageTag; $tip = $st.Tip
    if (-not $st.Installed) {
        Log "Installing language pack $tag (Internet and Windows Update needed, can take several minutes)"
        $res = @(Invoke-WithUpdateServices { Install-LanguagePack })
        if (-not ($res.Count -gt 0 -and $res[-1])) { Fail "Language pack $tag could not be installed: check Internet access and rerun with -Mode Language"; return }
        Ok "Language pack $tag installed"
    }
    $changed = $false
    if (-not $st.KeyboardOk) {
        try {
            $list = New-WinUserLanguageList -Language $tag
            $list[0].InputMethodTips.Clear()
            [void]$list[0].InputMethodTips.Add($tip)
            foreach ($x in $ExtraLanguages) { if ($x) { $e = New-WinUserLanguageList -Language $x; [void]$list.Add($e[0]) } }
            Set-WinUserLanguageList -LanguageList $list -Force
            Set-WinDefaultInputMethodOverride -InputTip $tip
            Ok "Language list set: $tag with keyboard $tip"
            $changed = $true
        } catch { Warn "Language list: $($_.Exception.Message)" }
    }
    if (-not $st.UiOk) {
        try {
            Set-WinUILanguageOverride -Language $tag
            Set-SystemPreferredUILanguage -Language $tag
            Ok "Display language set to $tag"
            $changed = $true
        } catch { Warn "Display language: $($_.Exception.Message)" }
    }
    try { if ((Get-Culture).Name -ne $tag) { Set-Culture -CultureInfo $tag; Ok "Regional format set to $tag"; $changed = $true } } catch { Warn "Regional format: $($_.Exception.Message)" }
    if ($SetSystemLocale -and -not $st.LocaleOk) {
        try { Set-WinSystemLocale -SystemLocale $tag; Ok "System locale set to $tag"; $changed = $true } catch { Warn "System locale: $($_.Exception.Message)" }
    }
    if ($null -ne $HomeLocationGeoId) {
        try { if ((Get-WinHomeLocation).GeoId -ne $HomeLocationGeoId) { Set-WinHomeLocation -GeoId $HomeLocationGeoId; Ok "Home location set (GeoId $HomeLocationGeoId)"; $changed = $true } } catch { Warn "Home location: $($_.Exception.Message)" }
    }
    if ($changed -and $CopyLanguageToSystem) {
        try { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true; Ok "Language settings copied to the welcome screen and new accounts" } catch { Warn "Copy to system: $($_.Exception.Message)" }
    }
    if ($changed) {
        $script:RebootNeeded = $true
        Note "Display/system language = $tag, keyboard layout $tip (KLID $KeyboardKlid)"
        Save-State
    }
}
function Restore-PrepLanguage {
    $b = $State.Language
    if (-not $b) { return }
    try {
        if (@($b.Languages).Count -gt 0) {
            $list = New-WinUserLanguageList -Language $b.Languages[0].Tag
            for ($i = 1; $i -lt @($b.Languages).Count; $i++) { $e = New-WinUserLanguageList -Language $b.Languages[$i].Tag; [void]$list.Add($e[0]) }
            for ($i = 0; $i -lt @($b.Languages).Count; $i++) {
                $list[$i].InputMethodTips.Clear()
                foreach ($t in @($b.Languages[$i].Tips)) { if ($t) { [void]$list[$i].InputMethodTips.Add($t) } }
            }
            Set-WinUserLanguageList -LanguageList $list -Force
        }
        if ($b.SystemLocale) { Set-WinSystemLocale -SystemLocale $b.SystemLocale }
        if ($b.Culture) { Set-Culture -CultureInfo $b.Culture }
        if ($b.UIOverride) { Set-WinUILanguageOverride -Language $b.UIOverride }
        if ($b.PreferredUI) { Set-SystemPreferredUILanguage -Language $b.PreferredUI }
        if ($b.GeoId) { Set-WinHomeLocation -GeoId $b.GeoId }
        if ($b.DefaultTip) { Set-WinDefaultInputMethodOverride -InputTip $b.DefaultTip }
        Ok "Language settings restored (the language pack stays installed)"
        $script:RebootNeeded = $true
    } catch { Warn "Language restore: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ CHECKS
function Invoke-Checks {
    param([switch]$ForInstall)
    Log "Checking MobileMark 30 Professional prerequisites"
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -ge $MinBuild) { Ok "Windows build $build (>= $MinBuild required: Windows 11 22H2)" } else { Fail "Build $build < $MinBuild (Windows 11 22H2 minimum)" }

    $cs = Get-CimInstance Win32_ComputerSystem
    $ram = [math]::Round($cs.TotalPhysicalMemory/1GB)
    if ($ram -ge $MinRamGB) { Ok "RAM ~ $ram GB" } else { Warn "RAM $ram GB < $MinRamGB GB (below the expected minimum)" }

    $disk = Get-PSDrive C
    $free = [math]::Round($disk.Free/1GB,1)
    if ($free -ge $MinFreeDiskGB) { Ok "Free space on C: $free GB" } else { Fail "Free space on C: $free GB < $MinFreeDiskGB GB" }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Ok "CPU $($cpu.Name.Trim()) (reported clock $($cpu.MaxClockSpeed) MHz)"
    if ($cpu.MaxClockSpeed -lt 2000) { Log "Reported clock is below 2 GHz: MM30 requires a CPU capable of 2 GHz or higher (boost clocks count), check the CPU spec sheet" }

    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
    if ($vc -and $vc.CurrentHorizontalResolution -ge 1366 -and $vc.CurrentVerticalResolution -ge 768) {
        Ok "Resolution $($vc.CurrentHorizontalResolution)x$($vc.CurrentVerticalResolution)"
    } else { Warn "Resolution below 1366x768?" }

    Show-LanguageStatus

    $bat = Get-BatteryInfo
    if (-not $bat.Present) { Fail "No battery detected" }
    else {
        $msg = "Battery $($bat.Charge) %, health $(if($bat.Health){"$($bat.Health) %"}else{'n/a'}), AC=$($bat.OnAC)"
        if ($bat.Charge -ge 99) { Ok $msg } else { Warn "$msg -> charge to 100 % before the run" }
    }

    Show-AutoLogonStatus

    $tp = Get-TamperState
    if ($null -eq $tp) { Warn "Tamper Protection: state unreadable (third-party antivirus?)" }
    elseif ($tp) { if ($ForInstall) { Fail "Tamper Protection ENABLED: disable it manually (Windows Security > Virus & threat protection > Manage settings) before installation" } else { Warn "Tamper Protection enabled (turn it off before installation; it also blocks some Defender settings)" } }
    else { Ok "Tamper Protection disabled" }

    $apps = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Microsoft 365|Microsoft Office|Adobe Photoshop|WinZip|MobileMark' }
    if ($apps | Where-Object { $_.DisplayName -match 'MobileMark' }) {
        Ok "MobileMark 30 installed: its bundled Office 2021 / Photoshop / WinZip are expected"
    } else {
        foreach ($a in $apps) { Warn "App detected: $($a.DisplayName) (must be removed before installing MM30, see User Guide)" }
    }
    $uwp = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'officehub|OneNote|Office' }
    if ($uwp) { Warn "UWP Office apps present: $($uwp.Name -join ', ')" } else { Ok "No UWP Office apps" }

    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $hvci = $dg -and ($dg.SecurityServicesRunning -contains 2)
    Log "VBS = $(if($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2){'active'}else{'inactive'}) ; Memory Integrity (HVCI) = $(if($hvci){'active'}else{'inactive'})  (shown in the FDR, the calibration machine shows it active)"

    $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA
    Log "UAC EnableLUA = $uac (the Config Tool disables it, reboot required)"

    $oem = Get-Service -Name $OemServicePatterns -ErrorAction SilentlyContinue
    if ($oem) { Log "OEM services detected: $(($oem | ForEach-Object { "$($_.Name)[$($_.Status)]" }) -join ', ')" }

    Log "System time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (do not change it after installing MM30)"
    Log "Reminder: vendor profile (MyASUS / Armoury Crate: Whisper/Standard/Performance, fans) must stay identical from start to end of the test and be documented."
}

# ------------------------------------------------------------------ TASKBAR / SHELL
# Windows 11 protects some taskbar values (Widgets button, Widgets policy): registry writes fail with
# "Attempted to perform an unauthorized operation" even as SYSTEM. The Settings page is the supported route.
function Get-RegValue {
    param([string]$Path,[string]$Name)
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}
function Send-ThemeBroadcast {
    if (-not ('MM30Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MM30Native {
  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
'@
    }
    $res = [IntPtr]::Zero
    # WM_SETTINGCHANGE (0x1A) with "ImmersiveColorSet" tells Explorer and apps to reload the theme
    [void][MM30Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$res)
}
function Update-Shell {
    try { Send-ThemeBroadcast } catch { Warn "Theme broadcast: $($_.Exception.Message)" }
    if (-not $RestartExplorer) { Log "Explorer restart skipped (RestartExplorer = false): sign out and in to fully apply the taskbar changes"; return }
    Log "Restarting Explorer to apply the taskbar changes"
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 3
    Ok "Explorer restarted"
    $script:ShellChanged = $false
}
function Set-ThemeMode {
    if ($Theme -eq 'Keep') { return }
    $pk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $v = if ($Theme -eq 'Dark') { 0 } else { 1 }
    Set-Reg $pk AppsUseLightTheme $v
    Set-Reg $pk SystemUsesLightTheme $v
    if (-not $ThemeAccentOnTaskbar) { Set-Reg $pk ColorPrevalence 0 }   # no accent color on the taskbar
    # some builds only repaint the taskbar after SystemUsesLightTheme changed twice: flip it, then set it back
    try {
        Set-ItemProperty -Path $pk -Name SystemUsesLightTheme -Value (1 - $v) -Type DWord -ErrorAction SilentlyContinue
        Send-ThemeBroadcast
        Start-Sleep -Milliseconds 300
        Set-ItemProperty -Path $pk -Name SystemUsesLightTheme -Value $v -Type DWord -ErrorAction SilentlyContinue
        Send-ThemeBroadcast
    } catch { Warn "Theme refresh: $($_.Exception.Message)" }
    $script:ShellChanged = $true
    if ((Get-RegValue $pk SystemUsesLightTheme) -eq $v) { Ok "Theme $Theme (the calibration machine uses the light theme; visible in the FDR)" }
    else { Warn "Theme $Theme could not be written to the registry" }
    Note "Windows theme = $Theme"
}
# Toggle a switch of a Settings page through UI Automation. Returns an object with Ok (final state reached) and Was (state before).
function Set-SettingsToggle {
    param([string]$Label,[ValidateSet('On','Off')][string]$State,[string]$PageUri = 'ms-settings:taskbar')
    $out = [pscustomobject]@{ Ok = $false; Was = $null }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $ae = [System.Windows.Automation.AutomationElement]
        $scopeChildren = [System.Windows.Automation.TreeScope]::Children
        $scopeDesc = [System.Windows.Automation.TreeScope]::Descendants
        $togglePattern = [System.Windows.Automation.TogglePattern]::Pattern
        Start-Process $PageUri
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $win = $null
        $winCond = New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, 'Settings')
        while (-not $win -and $sw.Elapsed.TotalSeconds -lt 20) {
            Start-Sleep -Milliseconds 500
            $win = $ae::RootElement.FindFirst($scopeChildren, $winCond)
        }
        if (-not $win) { Warn "Settings window not found (display language must be English for the Settings fallback)"; return $out }
        $labelCond = New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, $Label)
        $tog = $null
        $sw.Restart()
        while (-not $tog -and $sw.Elapsed.TotalSeconds -lt 15) {
            Start-Sleep -Milliseconds 700
            foreach ($e in $win.FindAll($scopeDesc, $labelCond)) {
                $p = $null
                if ($e.TryGetCurrentPattern($togglePattern, [ref]$p)) { $tog = $p; break }
                # the named element may be a label inside the card: look for the single switch of the element or of its parent
                $scope = $e
                for ($i = 0; $i -lt 2 -and -not $tog -and $scope; $i++) {
                    $found = @()
                    foreach ($c in $scope.FindAll($scopeDesc, [System.Windows.Automation.Condition]::TrueCondition)) {
                        $cp = $null
                        if ($c.TryGetCurrentPattern($togglePattern, [ref]$cp)) { $found += ,@($c, $cp) }
                    }
                    if ($found.Count -eq 1) { $tog = $found[0][1] }
                    elseif ($found.Count -gt 1) { $named = @($found | Where-Object { $_[0].Current.Name -eq $Label }); if ($named.Count -eq 1) { $tog = $named[0][1] } }
                    if (-not $tog) { $scope = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($scope) }
                }
                if ($tog) { break }
            }
        }
        if (-not $tog) { Warn "Settings switch '$Label' not found"; return $out }
        $out.Was = if ($tog.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) { 'On' } else { 'Off' }
        if ($out.Was -ne $State) { $tog.Toggle(); Start-Sleep -Milliseconds 800 }
        $now = if ($tog.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) { 'On' } else { 'Off' }
        $out.Ok = ($now -eq $State)
    } catch { Warn "Settings UI automation: $($_.Exception.Message)" }
    finally { Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    return $out
}
# Hide a taskbar button: registry first, Settings switch when Windows blocks the registry value.
function Hide-TaskbarItem {
    param([string]$ValueName,[string]$Label)
    $pk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $pk $ValueName 0 -Quiet
    if ((Get-RegValue $pk $ValueName) -eq 0) { Ok "$Label button hidden from the taskbar"; $script:ShellChanged = $true; return }
    if ($UseSettingsUiFallback) {
        Log "$Label : registry value is protected on this build, using the Settings page"
        $r = Set-SettingsToggle -Label $Label -State Off
        if ($r.Ok) {
            if ($r.Was -and -not ($State.UiToggles | Where-Object { $_.Label -eq $Label })) { $State.UiToggles += @{ Label=$Label; Was=$r.Was } }
            Ok "$Label button hidden from the taskbar (Settings page)"
            $script:ShellChanged = $true
            return
        }
    }
    Warn "$Label button could not be hidden automatically: turn it off in Settings > Personalization > Taskbar"
}
function Set-ShellTweaks {
    if ($DisableResume) {
        $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration'
        Set-Reg $rk IsResumeAllowed 0
        Set-Reg $rk IsOneDriveResumeAllowed 0
        if ((Get-RegValue $rk IsResumeAllowed) -eq 0) { Ok "Resume (cross-device) disabled"; Note "Resume (Settings > Apps > Resume) disabled" }
        else { Warn "Resume could not be disabled: turn it off in Settings > Apps > Resume" }
    }
    if ($HideTaskView) { Hide-TaskbarItem -ValueName ShowTaskViewButton -Label 'Task view' }
    if ($HideWidgets) {
        Hide-TaskbarItem -ValueName TaskbarDa -Label 'Widgets'
        # the policy also stops the Widgets background processes; it is protected on recent builds
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests 0 -Quiet
        if ($script:RegOk) { Ok "Widgets disabled by policy (AllowNewsAndInterests = 0)" }
        else { Log "Widgets policy (HKLM Dsh) is protected on this build: the button is hidden but the Widgets process may keep running (RemoveWidgetsApp removes it)" }
    }
    if ($RemoveWidgetsApp) {
        Get-AppxPackage -AllUsers -Name '*WebExperience*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*WebExperience*' } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        if (Get-AppxPackage -AllUsers -Name '*WebExperience*' -ErrorAction SilentlyContinue) { Warn "Windows Web Experience Pack (Widgets) could not be removed" }
        else { Ok "Windows Web Experience Pack (Widgets) removed"; Note "Windows Web Experience Pack removed (reinstall from the Microsoft Store to restore Widgets)" }
        $script:ShellChanged = $true
    }
}

# ------------------------------------------------------------------ PRE-INSTALL
function Invoke-PreInstall {
    Invoke-Checks -ForInstall
    Invoke-LanguageSetup
    Log "Removing UWP Office apps (User Guide procedure)"
    foreach ($p in '*officehub*','*OneNote*','*Office*') {
        Get-AppxPackage -AllUsers $p -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $p } |
            Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
    }
    Ok "UWP Office/OneNote apps processed (if Office Click-to-Run remains: use the Microsoft uninstall tool / SaRA)"
    Add-DefenderTuning
    Log "Resyncing system time (do this BEFORE installing MM30)"
    & w32tm /resync /force 2>&1 | Out-Null
    Ok "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Warn "Take a disk image BEFORE installing MM30 (reinstalling after an uninstall is not possible: DRM, Office/Photoshop 30-day licenses)."
}

# ------------------------------------------------------------------ DEFENDER
function Add-DefenderTuning {
    $tp = Get-TamperState
    if ($null -eq $tp) { Warn "Defender unavailable: settings skipped"; return }
    try {
        $pref = Get-MpPreference
        if (-not $State.Defender) {
            $State.Defender = @{
                Realtime=$pref.DisableRealtimeMonitoring; ScanDay=$pref.ScanScheduleDay
                CatchFull=$pref.DisableCatchupFullScan; CatchQuick=$pref.DisableCatchupQuickScan; Idle=$pref.ScanOnlyIfIdleEnabled
            }
        }
        $paths = @($DefenderExclusionPaths | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }) | Select-Object -Unique
        foreach ($p in $paths) {
            if ($pref.ExclusionPath -notcontains $p) { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; $State.Exclusions += $p }
        }
        Set-MpPreference -ScanScheduleDay 8 -DisableCatchupFullScan $true -DisableCatchupQuickScan $true -ScanOnlyIfIdleEnabled $true -ErrorAction Stop
        Ok "Defender: BAPCo exclusions + scheduled/catch-up scans disabled (real-time protection kept)"
        Note "Defender: exclusions $($paths -join ', '); scheduled scans disabled"
    } catch { Warn "Defender: $($_.Exception.Message) (Tamper Protection?)" }
    Save-State
}
function Set-DefenderRealtime {
    if (Get-TamperState) { Warn "Tamper Protection active: real-time protection NOT disabled"; return }
    try {
        if (-not $State.Defender) { $State.Defender = @{ Realtime=$false } }
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        Ok "Defender real-time protection disabled"
        Note "Defender: real-time protection disabled (the calibration machine had it ENABLED -> mention it in the publication)"
    } catch { Warn "Defender real-time: $($_.Exception.Message)" }
}

# ------------------------------------------------------------------ POWER
function Set-PowerPlan {
    $guidRx = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    $orig = [regex]::Match((powercfg /getactivescheme | Out-String), $guidRx).Value
    if (-not $State.Power) {
        $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
        $State.Power = @{ Orig=$orig; New=$null; Hibernate=$hib }
    }
    # plan derived from the Balanced template (required for the Power Mode slider to be available)
    $dup = [regex]::Match((powercfg /duplicatescheme SCHEME_BALANCED | Out-String), $guidRx).Value
    if (-not $dup) { Warn "Unable to duplicate the Balanced plan"; return }
    powercfg /changename $dup "MM30 Prep" "MobileMark 30 preparation plan" | Out-Null
    $State.Power.New = $dup

    $set = {
        param($sub,$setting,$ac,$dc)
        if ($null -ne $ac) { powercfg /setacvalueindex $dup $sub $setting $ac | Out-Null }
        if ($null -ne $dc) { powercfg /setdcvalueindex $dup $sub $setting $dc | Out-Null }
        if ($LASTEXITCODE -ne 0) { Warn "powercfg ${sub}/${setting}: failed" }
    }
    & $set SUB_VIDEO      VIDEOIDLE        0 0      # display never turns off
    & $set SUB_VIDEO      VIDEODIM         0 0
    & $set SUB_VIDEO      ADAPTBRIGHT      0 0      # no adaptive brightness (forbidden by the run rules)
    & $set SUB_SLEEP      STANDBYIDLE      0 0      # no sleep (Modern Standby is handled by the benchmark)
    & $set SUB_SLEEP      HIBERNATEIDLE    0 0
    & $set SUB_DISK       DISKIDLE         0 0
    & $set SUB_BUTTONS    LIDACTION        0 0
    & $set SUB_PROCESSOR  PROCTHROTTLEMIN  $MinProcessorStateDC $MinProcessorStateDC
    & $set SUB_PROCESSOR  PROCTHROTTLEMAX  $MaxProcessorStateDC $MaxProcessorStateDC
    # Battery Saver: configurable threshold (rule: <= 20 %), no brightness reduction in Battery Saver (rule: unchecked)
    & $set SUB_ENERGYSAVER ESBATTTHRESHOLD $BatterySaverThreshold $BatterySaverThreshold
    & $set SUB_ENERGYSAVER ESBRIGHTNESS    100 100
    Note "Battery Saver threshold = $BatterySaverThreshold % (BAPCo rule: <= 20 %), brightness reduction in Battery Saver disabled"
    if ($null -ne $CpuEppDC)       { & $set SUB_PROCESSOR PERFEPP $null $CpuEppDC;       Note "CPU EPP DC = $CpuEppDC" }
    if ($null -ne $CpuBoostModeDC) { & $set SUB_PROCESSOR PERFBOOSTMODE $null $CpuBoostModeDC; Note "CPU Boost mode DC = $CpuBoostModeDC" }
    Ok "Plan 'MM30 Prep' created (display/sleep/hibernate off, CPU $MinProcessorStateDC-$MaxProcessorStateDC %, Battery Saver threshold $BatterySaverThreshold %)"
    Note "Power plan derived from Balanced: CPU min/max DC $MinProcessorStateDC/$MaxProcessorStateDC %"

    return $dup
}
function Get-OverlayGuid {
    param([string]$Mode)
    switch ($Mode) {
        'Efficiency'        { '961cc777-2547-4f9d-8174-7d86181b8a7a' }
        'Balanced'          { '00000000-0000-0000-0000-000000000000' }
        'BetterPerformance' { '3af9B8d9-7c97-431d-ad78-34a8bfea439f' }
        'Performance'       { 'ded574b5-45a0-4f42-8737-46345c09c238' }
    }
}
function Apply-PowerExtras {
    param([string]$SchemeGuid,[int]$Brightness)
    if ($SchemeGuid) {
        powercfg /setdcvalueindex $SchemeGuid SUB_VIDEO VIDEONORMALLEVEL $Brightness | Out-Null
        powercfg /setactive $SchemeGuid | Out-Null
    }
    powercfg /h off | Out-Null
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0
    Ok "Hibernate and fast startup disabled"

    # Windows 11 "Power Mode" slider, set separately for DC (battery) and AC; must stay identical for the whole test
    $modeDc = if ($PowerModeDC) { $PowerModeDC } else { $PowerMode }
    $modeAc = if ($PowerModeAC) { $PowerModeAC } else { $PowerMode }
    $ovDc = Get-OverlayGuid $modeDc
    $ovAc = Get-OverlayGuid $modeAc
    $zero = '00000000-0000-0000-0000-000000000000'
    $pk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    # powercfg applies the overlay to the power source in use right now; registry values below finalize both sources
    $curGuid = if ((Get-BatteryInfo).OnAC) { $ovAc } else { $ovDc }
    powercfg /overlaysetactive $(if ($curGuid -eq $zero) { 'OVERLAY_SCHEME_NONE' } else { $curGuid }) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { powercfg /overlaysetactive $curGuid 2>&1 | Out-Null }
    foreach ($item in @(@('ActiveOverlayDcPowerScheme',$ovDc),@('ActiveOverlayAcPowerScheme',$ovAc))) {
        $n = $item[0]; $want = $item[1]
        $c = (Get-ItemProperty -Path $pk -Name $n -ErrorAction SilentlyContinue).$n
        if ($want -eq $zero -and -not $c) { continue }   # missing value = Balanced
        Set-Reg $pk $n $want 'String'
    }
    $norm = { param($v) if ($v) { $v } else { $zero } }
    $dcNow = & $norm (Get-ItemProperty -Path $pk -Name ActiveOverlayDcPowerScheme -ErrorAction SilentlyContinue).ActiveOverlayDcPowerScheme
    $acNow = & $norm (Get-ItemProperty -Path $pk -Name ActiveOverlayAcPowerScheme -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme
    if ($dcNow -eq $ovDc -and $acNow -eq $ovAc) { Ok "Power Mode: DC = $modeDc, AC = $modeAc (verified in registry; also check visually ON BATTERY: battery icon > slider, see User Guide step 5)" }
    else { Warn "Power Mode could not be verified (DC=$dcNow AC=$acNow): set the slider manually (DC = $modeDc, AC = $modeAc)" }
    Note "Windows Power Mode: DC = $modeDc, AC = $modeAc"
}

# ------------------------------------------------------------------ SYSTEM OPTIMIZATIONS
function Disable-WindowsUpdateAndMaintenance {
    foreach ($s in $UpdateServices) { if (Set-SvcDisabled $s) { Ok "Service $s disabled" } }
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Set-Reg "$wu\AU" NoAutoUpdate 1
    Set-Reg "$wu\AU" AUOptions 1
    Set-Reg "$wu\AU" NoAutoRebootWithLoggedOnUsers 1
    Set-Reg $wu SetAutoRestartNotificationDisable 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' DODownloadMode 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' AutoDownload 2
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' MaintenanceDisabled 1
    Note "Windows Update / Delivery Optimization / Store auto-update / automatic maintenance disabled"
}
function Disable-NoiseTasks {
    $script:ProtectedTasks = @()
    foreach ($x in $NoiseTasks) {
        $parts = $x -split '\|', 2
        if ($parts.Count -ne 2) { Warn "Invalid NoiseTasks entry (expected 'TaskPath|NamePattern'): $x"; continue }
        Disable-Task -Path $parts[0] -NamePattern $parts[1]
    }
    Disable-ProtectedTasks
    Ok "Noisy scheduled tasks disabled (restorable)"
}
function Disable-NoiseServices {
    $list = @($NoiseServices)
    if (-not $KeepSysMain) { $list += 'SysMain' }
    $n = 0; foreach ($s in $list) { if (Set-SvcDisabled $s) { $n++ } }
    Ok "$n non-essential services disabled (WSearch kept: required by the Config Tool)"
}
function Remove-StartupEntries {
    foreach ($p in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        if (-not (Test-Path $p)) { continue }
        $props = (Get-ItemProperty $p).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
        foreach ($pr in $props) {
            if ($StartupPatterns | Where-Object { $pr.Name -like $_ }) {
                $key = "$p|$($pr.Name)"
                try {
                    Remove-ItemProperty -Path $p -Name $pr.Name -ErrorAction Stop
                    if (-not ($State.Registry | Where-Object { $_.Key -eq $key })) {
                        $State.Registry += @{ Key=$key; Path=$p; Name=$pr.Name; Existed=$true; Value=$pr.Value; Type='String' }
                    }
                    Ok "Startup entry removed: $($pr.Name)"
                } catch { Warn "Startup entry $($pr.Name) : $($_.Exception.Message)" }
            }
        }
    }
    foreach ($proc in 'OneDrive','Teams','ms-teams') { Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
}
function Set-QuietDesktop {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','SystemPaneSuggestionsEnabled','RotatingLockScreenEnabled','SubscribedContent-310093Enabled','SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { Set-Reg $cdm $n 0 }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1
    # notifications / pop-ups (a window stealing focus breaks the automation)
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' ToastEnabled 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' NoToastApplicationNotification 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows Defender Security Center\Notifications' DisableNotifications 1
    # widgets / chat / Copilot / dynamic search
    # Widgets button / Task view are handled by Set-ShellTweaks (Windows protects those values)
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarMn 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' IsDynamicSearchBoxEnabled 0
    # background apps / Game Bar / telemetry / OneDrive / Edge / Dynamic Lighting
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' GlobalUserDisabled 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' LetAppsRunInBackground 2
    Set-Reg 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' DisableFileSyncNGSC 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' StartupBoostEnabled 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' BackgroundModeEnabled 0
    Set-Reg 'HKCU:\Software\Microsoft\Lighting' AmbientLightingEnabled 0
    Ok "Pop-ups, widgets, suggestions, background apps, Game Bar, OneDrive/Edge boost disabled"
    if (-not $KeepVisualEffects) {
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0
        Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate '0' 'String'
        Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarAnimations 0
        Ok "Transparency and animations disabled"
        Note "Visual effects: transparency and animations disabled"
    }
    Set-ThemeMode
}
function Disable-Radios {
    if ($DisableNetwork) {
        foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' }) {
            $State.Adapters += $a.Name
            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
            Ok "Network adapter disabled: $($a.Name)"
        }
    }
    if ($DisableBluetooth) {
        foreach ($d in Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^(USB|PCI|ACPI)\\' }) {
            $State.Bluetooth += $d.InstanceId
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            Ok "Bluetooth disabled: $($d.FriendlyName) (Bluetooth mouse/keyboard are cut off!)"
        }
    }
}

# ------------------------------------------------------------------ PRE-RUN
function Invoke-PreRun {
    Invoke-Checks
    $pct = if ($SkipBrightness) { $BrightnessPercent } else { Resolve-Brightness }

    Invoke-LanguageSetup
    $dcEff = if ($PowerModeDC) { $PowerModeDC } else { $PowerMode }

    Log "Power"
    $scheme = Set-PowerPlan
    Apply-PowerExtras -SchemeGuid $scheme -Brightness $pct

    Log "Windows Update / maintenance"
    Disable-WindowsUpdateAndMaintenance
    Log "Defender (non-intrusive settings)"
    Add-DefenderTuning
    Log "Scheduled tasks / services / startup"
    Disable-NoiseTasks
    Disable-NoiseServices
    Remove-StartupEntries
    Log "Quiet desktop"
    Set-QuietDesktop
    Log "Taskbar / shell"
    Set-ShellTweaks
    if ($script:ShellChanged) { Update-Shell }

    if ($StopOemServices) {
        foreach ($s in Get-Service -Name $OemServicePatterns -ErrorAction SilentlyContinue) {
            if (Set-SvcDisabled $s.Name) { Ok "OEM service stopped: $($s.Name)"; Note "OEM service disabled: $($s.Name)" }
        }
        Warn "Check that the OEM fan/performance profile has not changed (it must stay constant)"
    }
    if ($DefenderRealtimeOff) { Set-DefenderRealtime }
    if ($DisableMemoryIntegrity) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' Enabled 0
        Warn "Memory Integrity (HVCI) turned off: REBOOT required. The calibration machine had it enabled -> mention it."
        Note "Memory Integrity (HVCI) disabled (calibration: enabled)"
    }

    Log "Audio / display"
    Set-MasterVolume -Percent $Volume
    if (-not $SkipBrightness) { $applied = Set-PanelBrightness -Percent $pct; Note "Windows brightness DC = $applied %" }

    Save-State
    Disable-Radios
    Save-State

    Write-Host ""
    Log "Non-standard settings to document with the FDR:"
    $script:Report | ForEach-Object { Write-Host "   - $_" }
    Write-Host @"

=== MANUAL CHECKLIST (cannot be automated) ===
 [ ] Reboot if HVCI/UAC/language were changed, then restart MM30 with the SAME admin account (auto-logon)
 [ ] Battery at 100 %, charger plugged in until MM30 shows the "Please unplug" prompt
 [ ] Brightness Profiler (MM30 Verification screen): >= 250 cd/m2 on DC, otherwise set brightness to MAX and note it in the FDR
 [ ] Disable: adaptive brightness / ambient light sensor, CABC (Intel DPST, AMD Vari-Bright, ASUS Splendid/Eye Care),
     Night Light, HDR, Auto-HDR; on OLED: no dynamic dimming
 [ ] OEM profile (MyASUS / Armoury Crate) fixed and identical for the whole run
 [ ] Taskbar: Widgets and Task view hidden, taskbar dark if Theme = Dark (if a button is still visible, toggle it in Settings > Personalization > Taskbar)
 [ ] Power Mode verified on battery (slider in the battery icon = $dcEff)
 [ ] Wi-Fi / Ethernet OFF (rerun with -DisableNetwork last); volume 50 %
 [ ] MM30: Recommended = ON, Optional = OFF (default), Full discharge 100 %, Conditioning ON
 [ ] Do not touch the system time anymore; send the FDR to report@bapco.com after the run
"@
}

# ------------------------------------------------------------------ RESTORE
function Invoke-Restore {
    if (-not (Test-Path $StatePath)) { Fail "No saved state ($StatePath)"; return }
    Log "Restoring original state"
    foreach ($a in $State.Adapters)   { Enable-NetAdapter -Name $a -Confirm:$false -ErrorAction SilentlyContinue; Ok "Network adapter re-enabled: $a" }
    foreach ($b in $State.Bluetooth)  { Enable-PnpDevice -InstanceId $b -Confirm:$false -ErrorAction SilentlyContinue; Ok "Bluetooth re-enabled" }
    foreach ($s in $State.Services) {
        $arg = switch ($s.Mode) { 'Auto' { if ($s.Delayed) { 'delayed-auto' } else { 'auto' } } 'Manual' { 'demand' } default { 'disabled' } }
        if (-not (Set-ServiceStart -Name $s.Name -StartType $arg)) { Warn "Service $($s.Name) : could not be restored" }
        if ($s.WasRunning -and $s.Mode -ne 'Disabled') { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    }
    Ok "Services restored"
    foreach ($t in $State.Tasks) { Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null }
    Ok "Scheduled tasks re-enabled"
    foreach ($r in $State.Registry) {
        try {
            if ($r.Existed) { Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type -Force -ErrorAction Stop }
            else { Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue }
        } catch { Warn "Registry restore $($r.Key) : $($_.Exception.Message)" }
    }
    Ok "Registry restored"
    if ($State.Defender) {
        try {
            $d = $State.Defender
            Set-MpPreference -DisableRealtimeMonitoring $d.Realtime -ErrorAction Stop
            if ($null -ne $d.ScanDay) { Set-MpPreference -ScanScheduleDay $d.ScanDay -DisableCatchupFullScan $d.CatchFull -DisableCatchupQuickScan $d.CatchQuick -ScanOnlyIfIdleEnabled $d.Idle -ErrorAction Stop }
            foreach ($p in $State.Exclusions) { Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
            Ok "Defender restored"
        } catch { Warn "Defender: $($_.Exception.Message)" }
    }
    if ($State.Power) {
        if ($State.Power.Orig) { powercfg /setactive $State.Power.Orig | Out-Null }
        if ($State.Power.New)  { powercfg /delete $State.Power.New | Out-Null }
        if ($State.Power.Hibernate -eq 1) { powercfg /h on | Out-Null }
        Ok "Original power plan restored"
    }
    foreach ($t in @($State.UiToggles)) {
        if (-not $t.Label) { continue }
        $r = Set-SettingsToggle -Label $t.Label -State $t.Was
        if ($r.Ok) { Ok "Taskbar item '$($t.Label)' restored ($($t.Was))" } else { Warn "Taskbar item '$($t.Label)' could not be restored: toggle it in Settings > Personalization > Taskbar" }
    }
    Update-Shell
    Restore-PrepLanguage
    Move-Item $StatePath "$StatePath.restored_$ts" -Force
    Warn "Reboot recommended. If MM30 is installed, its Config Tool already restores its own settings at the end of the run."
}

# ------------------------------------------------------------------ MAIN
try {
    Log "MM30_Prep v$ScriptVersion - mode: $Mode"
    switch ($Mode) {
        'Check'      { Invoke-Checks }
        'PreInstall' { Invoke-PreInstall; Save-State }
        'PreRun'     { Invoke-PreRun }
        'Language'   { Invoke-LanguageSetup; Save-State }
        'Restore'    { Invoke-Restore }
    }
    if ($script:RebootNeeded) { Warn "Reboot required: language settings and/or service changes (written to the registry as SYSTEM) apply after a restart." }
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
