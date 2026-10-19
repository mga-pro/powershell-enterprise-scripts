<#
.SYNOPSIS
    Déclenche la mise à jour Windows des certificats Secure Boot 2023
    (db : Windows UEFI CA 2023, KEK : Microsoft KEK 2K CA 2023, boot manager signé 2023).

.DESCRIPTION
    Utilise le mécanisme officiel Microsoft : la valeur de registre
    HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates
    puis la tâche planifiée \Microsoft\Windows\PI\Secure-Boot-Update.
    Windows écrit ensuite les variables UEFI (db / KEK) au démarrage suivant.

    Masque AvailableUpdates :
      0x0004  Ajout de la KEK Microsoft 2023 (nécessite une KEK signée par la PK du constructeur)
      0x0040  Ajout de "Windows UEFI CA 2023" dans la db
      0x0100  Installation du boot manager signé 2023
      0x0800  Ajout de "Microsoft Option ROM UEFI CA 2023" dans la db
      0x1000  Ajout de "Microsoft UEFI CA 2023" dans la db
      0x4000  Modificateur (n'ajoute que si l'ancien certificat est présent)
      0x5944  = tout ce qui précède (valeur recommandée par Microsoft)

    À exécuter en administrateur, dans Windows, avec Secure Boot ACTIVÉ si possible
    (le mécanisme est conçu pour ce cas ; avec Secure Boot désactivé le résultat
    dépend du firmware, voir les messages affichés).

.PARAMETER Mask
    Valeur écrite dans AvailableUpdates. Défaut : 0x5944.
    Pour ne traiter que la db : 0x40.

.PARAMETER SuspendBitLocker
    Suspend BitLocker (2 redémarrages) sur le lecteur système avant la mise à jour,
    pour éviter une demande de clé de récupération.

.PARAMETER Restart
    Redémarre automatiquement le PC après le déclenchement (avec délai de 30 s).

.PARAMETER StatusOnly
    N'écrit rien : affiche seulement l'état du déploiement et les derniers événements.

.EXAMPLE
    .\Update-UEFICA2023.ps1 -WhatIf
    .\Update-UEFICA2023.ps1 -SuspendBitLocker
    .\Update-UEFICA2023.ps1 -Mask 0x40 -SuspendBitLocker -Restart
    .\Update-UEFICA2023.ps1 -StatusOnly

.NOTES
    Faites une sauvegarde et notez votre clé de récupération BitLocker avant de lancer.
    Une mise à jour du BIOS/UEFI par le constructeur reste la voie la plus sûre.
#>

#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [uint32]$Mask = 0x5944,
    [switch]$SuspendBitLocker,
    [switch]$Restart,
    [switch]$StatusOnly
)

$ErrorActionPreference = 'Stop'
$sbKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$servKey  = "$sbKey\Servicing"
$taskPath = '\Microsoft\Windows\PI\'
$taskName = 'Secure-Boot-Update'

function Write-Status {
    param([string]$Label, $Value, [string]$Color = 'White')
    Write-Host ("{0,-45}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Show-State {
    Write-Host ""
    Write-Host "--- État du déploiement ---" -ForegroundColor Cyan

    try { $sb = Confirm-SecureBootUEFI } catch { $sb = $null }
    Write-Status "Secure Boot activé :" $(if ($null -eq $sb) { 'inconnu (BIOS non UEFI ?)' } else { $sb }) $(if ($sb) { 'Green' } else { 'Yellow' })

    try {
        $db  = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes)
        $kek = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name KEK).Bytes)
        $has = $db -match 'Windows UEFI CA 2023'
        Write-Status "db contient Windows UEFI CA 2023 :" $(if ($has) { 'OUI' } else { 'NON' }) $(if ($has) { 'Green' } else { 'Red' })
        $hasK = $kek -match 'KEK 2K CA 2023'
        Write-Status "KEK contient KEK 2K CA 2023 :" $(if ($hasK) { 'OUI' } else { 'NON' }) $(if ($hasK) { 'Green' } else { 'Yellow' })
    } catch {
        Write-Status "Lecture db / KEK :" "impossible ($($_.Exception.Message))" 'Yellow'
    }

    $au = (Get-ItemProperty -Path $sbKey -Name AvailableUpdates -ErrorAction SilentlyContinue).AvailableUpdates
    Write-Status "AvailableUpdates (registre) :" $(if ($null -eq $au) { '(absent)' } else { '0x{0:X}' -f $au })

    $srv = Get-ItemProperty -Path $servKey -ErrorAction SilentlyContinue
    if ($srv) {
        if ($null -ne $srv.UEFICA2023Status) { Write-Status "UEFICA2023Status :" $srv.UEFICA2023Status }
        if ($null -ne $srv.UEFICA2023Error)  { Write-Status "UEFICA2023Error :"  ('0x{0:X}' -f $srv.UEFICA2023Error) 'Red' }
    }

    Write-Host ""
    Write-Host "--- Derniers événements Secure Boot (journal Système) ---" -ForegroundColor Cyan
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-TPM-WMI' } -MaxEvents 40 -ErrorAction Stop |
              Where-Object { $_.Id -ge 1000 -and $_.Id -le 1900 } | Select-Object -First 8
        if ($ev) {
            foreach ($e in $ev) {
                $c = switch ($e.Id) { 1808 { 'Green' } { $_ -in 1795, 1796, 1802, 1803 } { 'Red' } default { 'White' } }
                $msg = ($e.Message -split "`r?`n")[0]
                Write-Host ("{0:yyyy-MM-dd HH:mm}  ID {1}  {2}" -f $e.TimeCreated, $e.Id, $msg) -ForegroundColor $c
            }
            Write-Host "(1808 = mise à jour appliquée avec succès ; 1795/1796 = erreur firmware ; 1801 = en attente ; 1800 = redémarrage requis)" -ForegroundColor DarkGray
        } else {
            Write-Host "Aucun événement Secure Boot trouvé."
        }
    } catch {
        Write-Host "Aucun événement lisible : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "=== Mise à jour des certificats Secure Boot 2023 ===" -ForegroundColor Cyan

if ($StatusOnly) { Show-State; exit 0 }

# --- Pré-vérifications ------------------------------------------------------
try { $null = Confirm-SecureBootUEFI } catch {
    Write-Host "Cette machine n'est pas en mode UEFI ou Secure Boot n'est pas pris en charge. Abandon." -ForegroundColor Red
    exit 1
}

Show-State

if (-not (Confirm-SecureBootUEFI)) {
    Write-Host ""
    Write-Host "ATTENTION : Secure Boot est désactivé. Windows peut ne pas pouvoir écrire la db/KEK dans ce mode" -ForegroundColor Yellow
    Write-Host "(selon le firmware). Si l'événement 1808 n'apparaît pas après redémarrage, mettez à jour le BIOS" -ForegroundColor Yellow
    Write-Host "ou restaurez les clés d'usine avec un BIOS récent, puis relancez ce script." -ForegroundColor Yellow
}

# --- BitLocker --------------------------------------------------------------
$blNote = $false
try {
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($vol.ProtectionStatus -eq 'On') {
        Write-Host ""
        Write-Status "BitLocker sur $($env:SystemDrive) :" "actif" 'Yellow'
        if ($SuspendBitLocker) {
            if ($PSCmdlet.ShouldProcess($env:SystemDrive, "Suspendre BitLocker (2 redémarrages)")) {
                Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 | Out-Null
                Write-Host "BitLocker suspendu pour 2 redémarrages." -ForegroundColor Green
            }
        } else {
            $blNote = $true
            Write-Host "Le changement de db/boot manager peut déclencher la clé de récupération BitLocker." -ForegroundColor Yellow
            Write-Host "Relancez avec -SuspendBitLocker, ou assurez-vous de posséder la clé de récupération." -ForegroundColor Yellow
        }
    }
} catch { }

# --- Déclenchement ----------------------------------------------------------
Write-Host ""
$maskHex = '0x{0:X}' -f $Mask
if ($PSCmdlet.ShouldProcess("$sbKey\AvailableUpdates", "Écrire $maskHex")) {
    Set-ItemProperty -Path $sbKey -Name AvailableUpdates -Type DWord -Value $Mask
    Write-Host "AvailableUpdates = $maskHex" -ForegroundColor Green
}

if ($PSCmdlet.ShouldProcess("$taskPath$taskName", "Démarrer la tâche planifiée")) {
    try {
        Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        Write-Host "Tâche $taskName démarrée." -ForegroundColor Green
        Start-Sleep -Seconds 15
    } catch {
        Write-Host "Impossible de lancer la tâche : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Elle sera exécutée automatiquement (toutes les 12 h) ou au prochain redémarrage." -ForegroundColor Yellow
    }
}

Show-State

Write-Host ""
Write-Host "=== Suite ===" -ForegroundColor Cyan
Write-Host "1. Redémarrez le PC (souvent 2 redémarrages nécessaires : db/KEK puis boot manager)."
Write-Host "2. Relancez ensuite : .\Update-UEFICA2023.ps1 -StatusOnly   (attendu : UEFICA2023Status = Updated, événement 1808)."
Write-Host "3. Puis lancez Check-UEFICA2023.ps1 pour confirmer la présence des certificats dans la db."
Write-Host "4. Si UEFICA2023Error ou événement 1795/1796/1803 : le firmware refuse l'écriture -> mise à jour du BIOS constructeur nécessaire."
Write-Host ""

if ($Restart -and $PSCmdlet.ShouldProcess("ce PC", "Redémarrer dans 30 s")) {
    shutdown.exe /r /t 30 /c "Mise à jour des certificats Secure Boot 2023"
}
elseif ($blNote) {
    Write-Host "(Pas de redémarrage automatique : BitLocker actif et non suspendu.)" -ForegroundColor DarkGray
}
