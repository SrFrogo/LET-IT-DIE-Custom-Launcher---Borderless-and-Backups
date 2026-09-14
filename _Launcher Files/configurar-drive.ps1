[CmdletBinding()]
param(
    [string]$DrivePath = ''
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'launcher-config.ini'

function Find-DriveCandidate {
    $candidates = New-Object System.Collections.Generic.List[string]
    $profile = [Environment]::GetFolderPath('UserProfile')

    foreach ($name in @('My Drive', 'Mi unidad', 'Google Drive')) {
        $candidate = Join-Path $profile $name
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $candidates.Add($candidate)
        }
    }

    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        foreach ($name in @('My Drive', 'Mi unidad')) {
            $candidate = Join-Path $drive.RootDirectory.FullName $name
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $candidates.Add($candidate)
            }
        }
    }

    return $candidates | Select-Object -First 1
}

function Set-IniValue {
    param(
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $found = $false
    $escaped = [Regex]::Escape($Key)
    $updated = foreach ($line in $Lines) {
        if ($line -match "^\s*$escaped\s*=") {
            $found = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $found) { $updated += "$Key=$Value" }
    return $updated
}

try {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "No se encontro launcher-config.ini junto al configurador."
    }

    if ([string]::IsNullOrWhiteSpace($DrivePath)) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::EnableVisualStyles()

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select or create LETITDIE_Backups INSIDE Google Drive My Drive. / Selecciona o crea LETITDIE_Backups DENTRO de Mi unidad."
        $dialog.ShowNewFolderButton = $true

        $candidate = Find-DriveCandidate
        if ($candidate) {
            $suggested = Join-Path $candidate 'LETITDIE_Backups'
            if (-not (Test-Path -LiteralPath $suggested)) {
                New-Item -ItemType Directory -Path $suggested -Force | Out-Null
            }
            $dialog.SelectedPath = $suggested
        }

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Write-Host 'Configuration cancelled; no changes were made. / Configuracion cancelada; no se hicieron cambios.' -ForegroundColor Yellow
            exit 1
        }
        $selected = [IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
    } else {
        $selected = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DrivePath)).TrimEnd('\')
    }

    if (-not (Test-Path -LiteralPath $selected -PathType Container)) {
        New-Item -ItemType Directory -Path $selected -Force | Out-Null
    }

    $probe = Join-Path $selected ('.lid-write-test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($probe, 'OK', [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $probe -Force

    $lines = Get-Content -LiteralPath $configPath
    $lines = Set-IniValue -Lines $lines -Key 'DRIVE_ENABLED' -Value '1'
    $lines = Set-IniValue -Lines $lines -Key 'DRIVE_DEST' -Value $selected
    [IO.File]::WriteAllLines($configPath, $lines, [Text.UTF8Encoding]::new($true))

    Write-Host ''
    Write-Host 'Google Drive configured successfully / Google Drive configurado correctamente:' -ForegroundColor Green
    Write-Host $selected -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'The launcher verifies the copy in this local folder.'
    Write-Host 'El launcher verifica la copia en esta carpeta local.'
    Write-Host 'Google Drive for desktop uploads it to the cloud / se encarga de subirla a la nube.'
    exit 0
} catch {
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
