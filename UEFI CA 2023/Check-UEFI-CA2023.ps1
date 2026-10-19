<#
.SYNOPSIS
    Vérifie la présence des certificats Secure Boot 2023 dans l'UEFI (db / KEK)
    et compare avec le certificat qui a signé le gestionnaire de démarrage Windows (ESP).

.DESCRIPTION
    Cas d'usage : un PC ne démarre plus sous Windows après avoir désactivé puis réactivé
    Secure Boot dans le BIOS (souvent un "Restore factory keys" / "Reset to Setup Mode"
    qui remet une base db ancienne, sans "Windows UEFI CA 2023").

    Si bootmgfw.efi est signé par "Windows UEFI CA 2023" mais que la db du firmware
    ne contient que "Microsoft Windows Production PCA 2011", Secure Boot refuse de démarrer.

    À exécuter en administrateur, sur une machine en mode UEFI.
    Fonctionne aussi avec Secure Boot désactivé (lecture des variables UEFI).

.NOTES
    Script  : Check-UEFI-CA2023
    Version : 0.1
    Lecture seule : ce script ne modifie rien dans l'UEFI.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Label, [string]$Value, [string]$Color = 'White')
    Write-Host ("{0,-55}" -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Get-UefiVarText {
    param([string]$Name)
    try {
        $var = Get-SecureBootUEFI -Name $Name
        # Les noms des certificats (CN) sont stockés en clair (ASCII) dans les structures X.509
        return [System.Text.Encoding]::ASCII.GetString($var.Bytes)
    } catch {
        return $null
    }
}

Write-Host ""
Write-Host "=== Vérification des certificats Secure Boot 2023 ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Mode de démarrage et état Secure Boot -------------------------------
try {
    $sb = Confirm-SecureBootUEFI
} catch {
    Write-Host "Impossible de lire l'état Secure Boot : cette machine n'est pas en mode UEFI, ou les cmdlets Secure Boot ne sont pas disponibles." -ForegroundColor Red
    Write-Host "Détail : $($_.Exception.Message)"
    exit 1
}

Write-Status "Secure Boot actuellement activé :" $sb $(if ($sb) { 'Green' } else { 'Yellow' })

# --- 2. Contenu de la db (base des signatures autorisées) -------------------
$dbText  = Get-UefiVarText 'db'
$kekText = Get-UefiVarText 'KEK'
$dbxText = Get-UefiVarText 'dbx'

if (-not $dbText) {
    Write-Host "Lecture de la variable 'db' impossible." -ForegroundColor Red
    exit 1
}

$checksDb = @(
    @{ Nom = 'Windows UEFI CA 2023';                   Role = 'Signe le boot manager Windows (NOUVEAU)' },
    @{ Nom = 'Microsoft UEFI CA 2023';                 Role = 'Signe shim/Linux et binaires tiers' },
    @{ Nom = 'Microsoft Option ROM UEFI CA 2023';      Role = 'Signe les Option ROM (GPU, cartes réseau...)' },
    @{ Nom = 'Microsoft Windows Production PCA 2011';  Role = 'Ancien certificat Windows (expire 10/2026)' },
    @{ Nom = 'Microsoft Corporation UEFI CA 2011';     Role = 'Ancien certificat tiers (expire 06/2026)' }
)

Write-Host ""
Write-Host "--- Base 'db' (signatures autorisées) ---" -ForegroundColor Cyan
$resultDb = @{}
foreach ($c in $checksDb) {
    $present = $dbText -match [regex]::Escape($c.Nom)
    $resultDb[$c.Nom] = $present
    $color = if ($present) { 'Green' } else { 'Red' }
    Write-Status ("{0}" -f $c.Nom) ($(if ($present) { 'PRÉSENT' } else { 'ABSENT' })) $color
}

# --- 3. Contenu de la KEK ---------------------------------------------------
Write-Host ""
Write-Host "--- Base 'KEK' (clés d'échange de clés) ---" -ForegroundColor Cyan
$kek2023 = $false
if ($kekText) {
    $kek2023 = $kekText -match 'Microsoft Corporation KEK 2K CA 2023'
    $kek2011 = $kekText -match 'Microsoft Corporation KEK CA 2011'
    Write-Status "Microsoft Corporation KEK 2K CA 2023" ($(if ($kek2023) { 'PRÉSENT' } else { 'ABSENT' })) ($(if ($kek2023) { 'Green' } else { 'Red' }))
    Write-Status "Microsoft Corporation KEK CA 2011"    ($(if ($kek2011) { 'PRÉSENT' } else { 'ABSENT' })) ($(if ($kek2011) { 'Green' } else { 'Yellow' }))
} else {
    Write-Status "Lecture KEK" "impossible" 'Yellow'
}

# --- 4. Révocation de l'ancien certificat (dbx) ------------------------------
if ($dbxText) {
    Write-Host ""
    Write-Host "--- Base 'dbx' (révocations) ---" -ForegroundColor Cyan
    $dbx2023 = $dbxText -match 'Windows UEFI CA 2023'
    Write-Status "Mention de 'Windows UEFI CA 2023' dans dbx" ($(if ($dbx2023) { 'OUI (anormal)' } else { 'non' })) ($(if ($dbx2023) { 'Red' } else { 'Green' }))
}

# --- 5. Signature du boot manager sur la partition EFI -----------------------
Write-Host ""
Write-Host "--- Boot manager Windows (bootmgfw.efi sur l'ESP) ---" -ForegroundColor Cyan

$bootMgrSigner = $null
$mountedLetter = $null
try {
    # Cherche une lettre libre pour monter l'ESP
    $used   = (Get-PSDrive -PSProvider FileSystem).Name
    $letter = ([char[]](90..68) | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1)
    if ($letter) {
        $mountedLetter = "$($letter):"
        & mountvol $mountedLetter /S 2>&1 | Out-Null
        $bootMgr = Join-Path $mountedLetter 'EFI\Microsoft\Boot\bootmgfw.efi'
        if (Test-Path $bootMgr) {
            $sig  = Get-AuthenticodeSignature -FilePath $bootMgr
            $cert = $sig.SignerCertificate
            if ($cert) {
                # Remonte la chaîne pour trouver l'autorité racine émettrice
                $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                $chain.ChainPolicy.RevocationMode = 'NoCheck'
                [void]$chain.Build($cert)
                $chainNames = ($chain.ChainElements | ForEach-Object { $_.Certificate.Subject }) -join ' <- '
                $bootMgrSigner = if ($chainNames -match 'Windows UEFI CA 2023') { '2023' }
                                 elseif ($chainNames -match 'Windows Production PCA 2011') { '2011' }
                                 else { 'inconnu' }
                Write-Status "Signé avec la chaîne :" $bootMgrSigner 'White'
                Write-Host "  $chainNames" -ForegroundColor DarkGray
            } else {
                Write-Status "Signature" "introuvable" 'Yellow'
            }
        } else {
            Write-Status "bootmgfw.efi" "introuvable sur l'ESP" 'Yellow'
        }
    }
} catch {
    Write-Status "Analyse de l'ESP" "échec : $($_.Exception.Message)" 'Yellow'
} finally {
    if ($mountedLetter) { & mountvol $mountedLetter /D 2>&1 | Out-Null }
}

# --- 6. État du déploiement Windows (registre) -------------------------------
Write-Host ""
Write-Host "--- État du déploiement Windows (registre) ---" -ForegroundColor Cyan
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
try {
    $reg = Get-ItemProperty -Path $regPath -ErrorAction Stop
    if ($null -ne $reg.UEFICA2023Status)      { Write-Status "UEFICA2023Status :"      $reg.UEFICA2023Status }
    if ($null -ne $reg.WindowsUEFICA2023Capable) { Write-Status "WindowsUEFICA2023Capable :" $reg.WindowsUEFICA2023Capable }
    if ($null -ne $reg.UEFICA2023Error)       { Write-Status "UEFICA2023Error :"       $reg.UEFICA2023Error 'Red' }
} catch {
    Write-Status "Clé Servicing" "absente (mise à jour Secure Boot non encore traitée)" 'Yellow'
}

# --- 7. Diagnostic -----------------------------------------------------------
Write-Host ""
Write-Host "=== DIAGNOSTIC ===" -ForegroundColor Cyan

$ca2023Db = $resultDb['Windows UEFI CA 2023']
$pca2011  = $resultDb['Microsoft Windows Production PCA 2011']

if ($ca2023Db) {
    Write-Host "OK : 'Windows UEFI CA 2023' est présent dans la db du firmware." -ForegroundColor Green
    if ($bootMgrSigner -eq '2023' -or $bootMgrSigner -eq '2011') {
        Write-Host "Le boot manager (signature $bootMgrSigner) doit être accepté." -ForegroundColor Green
    }
    Write-Host "Si le PC ne démarre toujours pas, chercher ailleurs (dbx, Option ROM, BitLocker, etc.)."
}
else {
    Write-Host "PROBLÈME : 'Windows UEFI CA 2023' est ABSENT de la db du firmware." -ForegroundColor Red
    if ($bootMgrSigner -eq '2023') {
        Write-Host "Le boot manager est signé 2023 et la db ne contient pas le certificat 2023 => Secure Boot refusera de démarrer." -ForegroundColor Red
        Write-Host "Cause probable : restauration des clés d'usine du BIOS (db ancienne) après le passage du boot manager en signature 2023."
    }
    elseif ($bootMgrSigner -eq '2011' -and $pca2011) {
        Write-Host "Le boot manager est encore signé 2011 et PCA 2011 est présent : démarrage possible, mais le certificat 2023 doit être ajouté avant l'expiration de PCA 2011 (10/2026)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Pistes :" -ForegroundColor Yellow
    Write-Host "  - Mettre à jour le BIOS/UEFI (les nouvelles versions embarquent les clés 2023 par défaut)."
    Write-Host "  - Dans le BIOS : Secure Boot > 'Restore Factory Keys' avec un BIOS récent, ou mode 'Custom' + import des certificats."
    Write-Host "  - Si Windows démarre (Secure Boot OFF) : déclencher la mise à jour Windows du db :"
    Write-Host "      reg add HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot /v AvailableUpdates /t REG_DWORD /d 0x5944 /f"
    Write-Host "      Start-ScheduledTask -TaskName '\Microsoft\Windows\PI\Secure-Boot-Update'"
    Write-Host "    (KEK signée par le fabricant requise ; vérifier ensuite l'événement 1808 dans le journal Système)"
    Write-Host "  - En dernier recours : désactiver Secure Boot le temps de réparer, ou restaurer un boot manager signé 2011 (bcdboot avec les fichiers 'EFI_EX' vs 'EFI' selon la cible)."
}

Write-Host ""
