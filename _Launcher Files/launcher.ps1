# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 SrFrogo

[CmdletBinding()]
param(
    [switch]$BackupOnly,
    [switch]$SelfTest,
    [string]$ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'launcher-config.ini'
}
$script:LogPath = Join-Path $PSScriptRoot 'launcher.log'
$script:DriveWarning = $false

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Write-Status {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
    Write-Log -Message $Message -Level $Level
}

function Read-LauncherConfig {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No se encontro el archivo de configuracion: $Path"
    }

    $settings = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim().ToUpperInvariant()
        $value = $trimmed.Substring($separator + 1).Trim()
        $settings[$key] = $value
    }
    return $settings
}

function Get-RequiredSetting {
    param([hashtable]$Settings, [string]$Name)
    if (-not $Settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Settings[$Name])) {
        throw "Falta el valor obligatorio $Name en launcher-config.ini."
    }
    return [string]$Settings[$Name]
}

function Get-BoolSetting {
    param([hashtable]$Settings, [string]$Name, [bool]$Default)
    if (-not $Settings.ContainsKey($Name)) { return $Default }
    $value = ([string]$Settings[$Name]).Trim().ToLowerInvariant()
    if ($value -in @('1','true','yes','si','on')) { return $true }
    if ($value -in @('0','false','no','off')) { return $false }
    throw "$Name debe ser 1 o 0."
}

function Get-IntSetting {
    param([hashtable]$Settings, [string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum)
    if (-not $Settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Settings[$Name])) {
        return $Default
    }
    $number = 0
    if (-not [int]::TryParse([string]$Settings[$Name], [ref]$number)) {
        throw "$Name debe ser un numero entero."
    }
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name debe estar entre $Minimum y $Maximum."
    }
    return $number
}

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $PSScriptRoot $expanded
    }
    return Get-NormalizedPath $expanded
}

function Get-NormalizedPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\','/') }
    return $full
}

function Test-SameOrNested {
    param([string]$First, [string]$Second)
    $a = Get-NormalizedPath $First
    $b = Get-NormalizedPath $Second
    if ($a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeDestination {
    param([string]$Source, [string]$Destination, [string]$Label)
    $sourceFull = Get-NormalizedPath $Source
    $destFull = Get-NormalizedPath $Destination
    $root = [IO.Path]::GetPathRoot($destFull)
    if ($destFull.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label no puede ser la raiz de una unidad: $destFull"
    }
    if ((Test-SameOrNested $destFull $sourceFull) -or (Test-SameOrNested $sourceFull $destFull)) {
        throw "$Label no puede ser igual, contener ni estar dentro de SOURCE."
    }
}

function Remove-SafeTree {
    param([string]$Target, [string]$SafetyRoot)
    if (-not (Test-Path -LiteralPath $Target)) { return }
    $targetFull = Get-NormalizedPath $Target
    $rootFull = Get-NormalizedPath $SafetyRoot
    if (-not $targetFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Se bloqueo una limpieza fuera del destino permitido: $targetFull"
    }
    Remove-Item -LiteralPath $targetFull -Recurse -Force
}

function Get-DirectoryManifest {
    param([Parameter(Mandatory=$true)][string]$Path)
    $root = Get-NormalizedPath $Path
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)
    $manifest = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\','/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        $manifest.Add(("{0}`t{1}`t{2}" -f $hash, $file.Length, $relative))
    }
    return $manifest.ToArray()
}

function Test-ManifestsEqual {
    param([string[]]$First, [string[]]$Second)
    if ($First.Count -ne $Second.Count) { return $false }
    for ($i = 0; $i -lt $First.Count; $i++) {
        if (-not $First[$i].Equals($Second[$i], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Copy-DirectoryContents {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Publish-VerifiedDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Final,
        [Parameter(Mandatory=$true)][string]$SafetyRoot,
        [Parameter(Mandatory=$true)][string]$Label,
        [int]$Retries = 3
    )

    $sourceFull = Get-NormalizedPath $Source
    $finalFull = Get-NormalizedPath $Final
    $rootFull = Get-NormalizedPath $SafetyRoot
    $parent = Split-Path -Parent $finalFull
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    if (-not $finalFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Destino interno inseguro para ${Label}: $finalFull"
    }

    $verifiedManifest = $null
    $stage = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $stage = Join-Path $parent ('.staging-' + [Guid]::NewGuid().ToString('N'))
        try {
            $before = @(Get-DirectoryManifest $sourceFull)
            if ($before.Count -eq 0) { throw "SOURCE no contiene archivos; no se reemplazara ningun backup." }

            Copy-DirectoryContents -Source $sourceFull -Destination $stage
            $after = @(Get-DirectoryManifest $sourceFull)
            $copied = @(Get-DirectoryManifest $stage)

            if ((Test-ManifestsEqual $before $after) -and (Test-ManifestsEqual $after $copied)) {
                $verifiedManifest = $copied
                break
            }

            Write-Log -Level 'WARN' -Message "$Label cambio durante la copia o no coincidio (intento $attempt de $Retries)."
        } finally {
            if ($null -eq $verifiedManifest -and $stage -and (Test-Path -LiteralPath $stage)) {
                Remove-SafeTree -Target $stage -SafetyRoot $rootFull
            }
        }
        Start-Sleep -Seconds 2
    }

    if ($null -eq $verifiedManifest) {
        throw "$Label no supero la verificacion SHA-256 despues de $Retries intentos. La copia anterior sigue intacta."
    }

    $previous = Join-Path $parent ('.previous-' + [Guid]::NewGuid().ToString('N'))
    $hadPrevious = Test-Path -LiteralPath $finalFull
    $movedPrevious = $false
    $publishedNew = $false
    try {
        if ($hadPrevious) {
            if (-not (Test-Path -LiteralPath $finalFull -PathType Container)) {
                throw "El destino existente de $Label no es una carpeta: $finalFull"
            }
            [IO.Directory]::Move($finalFull, $previous)
            $movedPrevious = $true
        }
        [IO.Directory]::Move($stage, $finalFull)
        $publishedNew = $true
        $published = @(Get-DirectoryManifest $finalFull)
        if (-not (Test-ManifestsEqual $verifiedManifest $published)) {
            throw "La verificacion final de $Label no coincidio."
        }
    } catch {
        if ($publishedNew -and (Test-Path -LiteralPath $finalFull)) {
            Remove-SafeTree -Target $finalFull -SafetyRoot $rootFull
        }
        if ($movedPrevious -and (Test-Path -LiteralPath $previous)) {
            [IO.Directory]::Move($previous, $finalFull)
        }
        if (Test-Path -LiteralPath $stage) {
            Remove-SafeTree -Target $stage -SafetyRoot $rootFull
        }
        throw
    }

    if ($hadPrevious -and (Test-Path -LiteralPath $previous)) {
        try {
            Remove-SafeTree -Target $previous -SafetyRoot $rootFull
        } catch {
            Write-Log -Level 'WARN' -Message "La copia nueva de $Label esta verificada, pero no se pudo limpiar una copia temporal anterior: $previous"
        }
    }

    return [PSCustomObject]@{
        Path = $finalFull
        Files = $verifiedManifest.Count
        Manifest = $verifiedManifest
    }
}

function Write-HashManifest {
    param([string]$BackupRoot, [string[]]$Manifest)
    $verification = Join-Path $BackupRoot 'verification'
    New-Item -ItemType Directory -Path $verification -Force | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# SHA-256  archivo relativo')
    foreach ($entry in $Manifest) {
        $parts = $entry -split "`t", 3
        $lines.Add(('{0}  {1}' -f $parts[0], $parts[2]))
    }
    [IO.File]::WriteAllLines((Join-Path $verification 'current-save.sha256'), $lines, [Text.UTF8Encoding]::new($true))
}

function Test-HistoryDue {
    param([string]$HistoryRoot, [int]$EveryDays)
    if ($EveryDays -eq 0) { return $true }
    if (-not (Test-Path -LiteralPath $HistoryRoot -PathType Container)) { return $true }
    $latest = Get-ChildItem -LiteralPath $HistoryRoot -Directory -Force |
        Where-Object { $_.Name -like 'let it die *' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return $true }
    return (([DateTime]::UtcNow - $latest.LastWriteTimeUtc).TotalDays -ge $EveryDays)
}

function New-HistoricBackup {
    param([string]$CurrentPath, [string]$LocalRoot, [int]$EveryDays)
    $historyRoot = Join-Path $LocalRoot 'historic saves'
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    if (-not (Test-HistoryDue -HistoryRoot $historyRoot -EveryDays $EveryDays)) {
        Write-Log -Message "El historico aun no corresponde (intervalo: $EveryDays dia(s))."
        return $null
    }

    $name = 'let it die ' + (Get-Date -Format 'yyyy-MM-dd HH-mm-ss')
    $final = Join-Path $historyRoot $name
    $result = Publish-VerifiedDirectory -Source $CurrentPath -Final $final -SafetyRoot $LocalRoot -Label 'backup historico'
    Write-Status -Level 'OK' -Message ("Historico verificado: {0}" -f $result.Path)
    return $result.Path
}

function Sync-HistoryToDrive {
    param([string]$LocalRoot, [string]$DriveRoot)
    $localHistory = Join-Path $LocalRoot 'historic saves'
    if (-not (Test-Path -LiteralPath $localHistory -PathType Container)) { return }
    $driveHistory = Join-Path $DriveRoot 'historic saves'
    New-Item -ItemType Directory -Path $driveHistory -Force | Out-Null

    foreach ($directory in Get-ChildItem -LiteralPath $localHistory -Directory -Force | Where-Object { $_.Name -like 'let it die *' }) {
        $remote = Join-Path $driveHistory $directory.Name
        $needsCopy = $true
        if (Test-Path -LiteralPath $remote -PathType Container) {
            $localManifest = @(Get-DirectoryManifest $directory.FullName)
            $remoteManifest = @(Get-DirectoryManifest $remote)
            $needsCopy = -not (Test-ManifestsEqual $localManifest $remoteManifest)
        }
        if ($needsCopy) {
            $null = Publish-VerifiedDirectory -Source $directory.FullName -Final $remote -SafetyRoot $DriveRoot -Label ("historico de Drive " + $directory.Name)
            Write-Status -Level 'OK' -Message ("Historico sincronizado con Drive: {0}" -f $directory.Name)
        }
    }
}

function Write-LastRunReport {
    param(
        [string]$LocalRoot,
        [string]$Source,
        [int]$Files,
        [string]$DriveResult
    )
    $verification = Join-Path $LocalRoot 'verification'
    New-Item -ItemType Directory -Path $verification -Force | Out-Null
    $report = @(
        'LET IT DIE Custom Launcher v2.3',
        ('Fecha: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')),
        ('Origen: ' + $Source),
        ('Archivos verificados: ' + $Files),
        'Backup local: OK (SHA-256)',
        ('Google Drive: ' + $DriveResult)
    )
    [IO.File]::WriteAllLines((Join-Path $verification 'last-run.txt'), $report, [Text.UTF8Encoding]::new($true))
}

function Invoke-Backups {
    param([hashtable]$Settings)

    $source = Resolve-ConfiguredPath (Get-RequiredSetting $Settings 'SOURCE')
    $localRoot = Resolve-ConfiguredPath (Get-RequiredSetting $Settings 'LOCAL_DEST')
    $historyDays = Get-IntSetting $Settings 'HISTORIC_EVERY_DAYS' 1 0 3650

    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "No existe SOURCE: $source"
    }
    Assert-SafeDestination -Source $source -Destination $localRoot -Label 'LOCAL_DEST'
    New-Item -ItemType Directory -Path $localRoot -Force | Out-Null

    Write-Status -Message 'Creando backup local temporal y calculando SHA-256...'
    $current = Join-Path $localRoot 'current save'
    $local = Publish-VerifiedDirectory -Source $source -Final $current -SafetyRoot $localRoot -Label 'backup local actual'
    Write-HashManifest -BackupRoot $localRoot -Manifest $local.Manifest
    Write-Status -Level 'OK' -Message ("BACKUP LOCAL VERIFICADO: {0} archivo(s)." -f $local.Files)

    $null = New-HistoricBackup -CurrentPath $current -LocalRoot $localRoot -EveryDays $historyDays

    $driveResult = 'desactivado'
    $driveEnabled = Get-BoolSetting $Settings 'DRIVE_ENABLED' $true
    if ($driveEnabled) {
        $driveValue = if ($Settings.ContainsKey('DRIVE_DEST')) { [string]$Settings['DRIVE_DEST'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($driveValue)) {
            $script:DriveWarning = $true
            $driveResult = 'PENDIENTE: ejecuta Configurar Google Drive.cmd'
            Write-Status -Level 'WARN' -Message 'Google Drive no esta configurado. El backup local si quedo protegido.'
        } else {
            try {
                $driveRoot = Resolve-ConfiguredPath $driveValue
                Assert-SafeDestination -Source $source -Destination $driveRoot -Label 'DRIVE_DEST'
                if ((Test-SameOrNested $driveRoot $localRoot) -or (Test-SameOrNested $localRoot $driveRoot)) {
                    throw 'DRIVE_DEST y LOCAL_DEST no pueden ser iguales ni estar uno dentro del otro.'
                }
                if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
                    throw "La carpeta local de Google Drive no esta disponible: $driveRoot"
                }

                Write-Status -Message 'Copiando el backup actual a la carpeta local de Google Drive...'
                $driveCurrent = Join-Path $driveRoot 'current save'
                $drive = Publish-VerifiedDirectory -Source $current -Final $driveCurrent -SafetyRoot $driveRoot -Label 'backup actual de Google Drive'
                Write-HashManifest -BackupRoot $driveRoot -Manifest $drive.Manifest
                Sync-HistoryToDrive -LocalRoot $localRoot -DriveRoot $driveRoot
                $driveResult = "OK en carpeta local ($($drive.Files) archivo(s)); subida gestionada por Google Drive for desktop"
                Write-Status -Level 'OK' -Message 'GOOGLE DRIVE LOCAL VERIFICADO. El cliente de Google gestionara la subida.'
            } catch {
                $script:DriveWarning = $true
                $driveResult = 'ERROR: ' + $_.Exception.Message
                Write-Status -Level 'WARN' -Message ("No se pudo actualizar Google Drive: " + $_.Exception.Message)
                Write-Status -Level 'WARN' -Message 'El backup local verificado se conserva y Drive se reintentara la proxima vez.'
            }
        }
    }

    Write-LastRunReport -LocalRoot $localRoot -Source $source -Files $local.Files -DriveResult $driveResult
    if ($driveEnabled -and -not $script:DriveWarning) {
        $driveRoot = Resolve-ConfiguredPath ([string]$Settings['DRIVE_DEST'])
        Write-LastRunReport -LocalRoot $driveRoot -Source $source -Files $local.Files -DriveResult $driveResult
    }
}

function Add-BorderlessNativeType {
    if ('BorderlessNative' -as [type]) { return }

    $source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class BorderlessNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extraData);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hWnd, int command);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")] private static extern int GetWindowLong32(IntPtr hWnd, int index);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong")] private static extern int SetWindowLong32(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int index, IntPtr value);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);

    private const int GWL_STYLE = -16;
    private const int GWL_EXSTYLE = -20;
    private const uint GW_OWNER = 4;
    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_FRAMECHANGED = 0x0020;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_NOOWNERZORDER = 0x0200;
    private const uint SWP_NOSENDCHANGING = 0x0400;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const int SW_MAXIMIZE = 3;
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    private const long WS_VISIBLE = 0x10000000L;
    private const long WS_POPUP = 0x80000000L;
    private const long REMOVE_STYLE = 0x00CF0000L; // caption, border, dlgframe, thickframe, sysmenu, min/max
    private const long REMOVE_EXSTYLE = 0x00020301L; // dlgmodalframe, windowedge, clientedge, staticedge
    private const long WS_EX_TOPMOST = 0x00000008L;

    private static long GetLong(IntPtr hWnd, int index)
    {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, index).ToInt64() : (long)GetWindowLong32(hWnd, index);
    }

    private static void SetLong(IntPtr hWnd, int index, long value)
    {
        if (IntPtr.Size == 8) SetWindowLongPtr64(hWnd, index, new IntPtr(value));
        else SetWindowLong32(hWnd, index, unchecked((int)value));
    }

    public static void EnablePerMonitorDpi()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
    }

    public static IntPtr FindBestWindow(int processId)
    {
        IntPtr foreground = GetForegroundWindow();
        if (foreground != IntPtr.Zero && IsWindowVisible(foreground))
        {
            uint foregroundPid;
            GetWindowThreadProcessId(foreground, out foregroundPid);
            RECT foregroundRect;
            if (foregroundPid == (uint)processId && GetWindow(foreground, GW_OWNER) == IntPtr.Zero &&
                GetWindowRect(foreground, out foregroundRect) &&
                foregroundRect.Right - foregroundRect.Left >= 320 && foregroundRect.Bottom - foregroundRect.Top >= 200)
                return foreground;
        }

        IntPtr best = IntPtr.Zero;
        long bestScore = 0;
        EnumWindows(delegate(IntPtr hWnd, IntPtr unused)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != (uint)processId || !IsWindowVisible(hWnd) || GetWindow(hWnd, GW_OWNER) != IntPtr.Zero)
                return true;

            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) return true;
            long width = Math.Max(0, rect.Right - rect.Left);
            long height = Math.Max(0, rect.Bottom - rect.Top);
            long score = width * height;
            if (GetWindowTextLength(hWnd) > 0) score += 10000000000L;
            if (width >= 320 && height >= 200 && score > bestScore)
            {
                bestScore = score;
                best = hWnd;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    public static void PrepareBorderless(IntPtr hWnd)
    {
        if (hWnd != IntPtr.Zero && !IsIconic(hWnd)) ShowWindowAsync(hWnd, SW_MAXIMIZE);
    }

    public static int GetPrimaryWidth() { return GetSystemMetrics(0); }
    public static int GetPrimaryHeight() { return GetSystemMetrics(1); }

    public static bool IsManualHotkeyDown()
    {
        return (GetAsyncKeyState(0x11) & 0x8000) != 0 &&
               (GetAsyncKeyState(0x12) & 0x8000) != 0 &&
               (GetAsyncKeyState(0x7A) & 0x8000) != 0;
    }

    public static int EnsureBorderless(IntPtr hWnd, bool keepTopmost)
    {
        if (hWnd == IntPtr.Zero || IsIconic(hWnd)) return 0;

        long style = GetLong(hWnd, GWL_STYLE);
        long exStyle = GetLong(hWnd, GWL_EXSTYLE);
        long wantedStyle = (style & ~REMOVE_STYLE) | WS_POPUP | WS_VISIBLE;
        long wantedExStyle = exStyle & ~REMOVE_EXSTYLE;
        bool styleChanged = style != wantedStyle || exStyle != wantedExStyle;

        if (style != wantedStyle) SetLong(hWnd, GWL_STYLE, wantedStyle);
        if (exStyle != wantedExStyle) SetLong(hWnd, GWL_EXSTYLE, wantedExStyle);

        IntPtr monitor = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO info = new MONITORINFO();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return -1;

        RECT current;
        if (!GetWindowRect(hWnd, out current)) return -1;
        int width = info.rcMonitor.Right - info.rcMonitor.Left;
        int height = info.rcMonitor.Bottom - info.rcMonitor.Top;
        bool rectChanged = current.Left != info.rcMonitor.Left || current.Top != info.rcMonitor.Top ||
                           current.Right != info.rcMonitor.Right || current.Bottom != info.rcMonitor.Bottom;
        bool topmostChanged = keepTopmost && (exStyle & WS_EX_TOPMOST) == 0;

        if (!styleChanged && !rectChanged && !topmostChanged) return 0;

        uint flags = SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING | SWP_SHOWWINDOW;
        bool ok;
        if (keepTopmost)
        {
            ok = SetWindowPos(hWnd, HWND_TOPMOST, info.rcMonitor.Left, info.rcMonitor.Top, width, height, flags);
        }
        else
        {
            // Pulso topmost/no-topmost: coloca la ventana sobre la barra de tareas sin dejarla siempre encima.
            SetWindowPos(hWnd, HWND_TOPMOST, info.rcMonitor.Left, info.rcMonitor.Top, width, height, flags);
            ok = SetWindowPos(hWnd, HWND_NOTOPMOST, info.rcMonitor.Left, info.rcMonitor.Top, width, height, flags);
        }
        return ok ? 1 : -1;
    }

    public static string GetBounds(IntPtr hWnd)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return "desconocido";
        return String.Format("{0},{1} - {2}x{3}", rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }

    public static void BeginHighResolutionTimer() { try { timeBeginPeriod(1); } catch { } }
    public static void EndHighResolutionTimer() { try { timeEndPeriod(1); } catch { } }
}

public sealed class BorderlessTracker : IDisposable
{
    private readonly int processId;
    private readonly bool keepTopmost;
    private readonly int intervalMs;
    private readonly Thread worker;
    private volatile bool stopping;
    private long currentHandle;
    private long applyCount;
    private long errorCount;

    public BorderlessTracker(int processId, bool keepTopmost, int intervalMs)
    {
        this.processId = processId;
        this.keepTopmost = keepTopmost;
        this.intervalMs = Math.Max(5, intervalMs);
        this.worker = new Thread(Run);
        this.worker.IsBackground = true;
        this.worker.Name = "LET IT DIE Borderless Lock";
        this.worker.Start();
    }

    public long CurrentHandle { get { return Interlocked.Read(ref currentHandle); } }
    public long ApplyCount { get { return Interlocked.Read(ref applyCount); } }
    public long ErrorCount { get { return Interlocked.Read(ref errorCount); } }

    private void Run()
    {
        BorderlessNative.BeginHighResolutionTimer();
        IntPtr preparedHandle = IntPtr.Zero;
        int aliveCounter = 0;
        try
        {
            while (!stopping)
            {
                if ((aliveCounter++ % 100) == 0)
                {
                    try
                    {
                        Process process = Process.GetProcessById(processId);
                        if (process.HasExited) break;
                    }
                    catch { break; }
                }

                IntPtr hWnd = BorderlessNative.FindBestWindow(processId);
                Interlocked.Exchange(ref currentHandle, hWnd.ToInt64());
                if (hWnd != IntPtr.Zero)
                {
                    if (hWnd != preparedHandle)
                    {
                        BorderlessNative.PrepareBorderless(hWnd);
                        Thread.Sleep(30);
                        preparedHandle = hWnd;
                    }
                    int result = BorderlessNative.EnsureBorderless(hWnd, keepTopmost);
                    if (result > 0) Interlocked.Increment(ref applyCount);
                    else if (result < 0) Interlocked.Increment(ref errorCount);
                }
                Thread.Sleep(intervalMs);
            }
        }
        finally
        {
            BorderlessNative.EndHighResolutionTimer();
        }
    }

    public void Stop()
    {
        stopping = true;
        if (worker != null && worker.IsAlive) worker.Join(1500);
    }

    public void Dispose() { Stop(); }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
    [BorderlessNative]::EnablePerMonitorDpi()
}

function Set-GameWindowed {
    param([hashtable]$Settings, [switch]$QuietIfMissing)
    if (-not (Get-BoolSetting $Settings 'FORCE_WINDOWED' $true)) { return $true }

    $configValue = if ($Settings.ContainsKey('GRAPHICS_CONFIG')) { [string]$Settings['GRAPHICS_CONFIG'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($configValue)) {
        $savePath = Resolve-ConfiguredPath (Get-RequiredSetting $Settings 'SOURCE')
        $gameRoot = Split-Path -Parent $savePath
        $configPath = Join-Path $gameRoot 'BrgGame\Config\BrgGraphicsConfig.ini'
    } else {
        $configPath = Resolve-ConfiguredPath $configValue
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        if (-not $QuietIfMissing) {
            Write-Status -Level 'WARN' -Message 'No se encontro BrgGraphicsConfig.ini; se usaran los parametros de ventana y resolucion.'
        }
        return $false
    }

    try {
        $originalBackup = $configPath + '.before-custom-launcher'
        if (-not (Test-Path -LiteralPath $originalBackup -PathType Leaf)) {
            Copy-Item -LiteralPath $configPath -Destination $originalBackup -Force
        }
        $text = [IO.File]::ReadAllText($configPath)
        if ($text -match '(?im)^\s*mbFullScreen\s*=') {
            $updated = [Regex]::Replace($text, '(?im)^\s*mbFullScreen\s*=.*$', 'mbFullScreen=False')
        } else {
            $updated = $text.TrimEnd() + [Environment]::NewLine + 'mbFullScreen=False' + [Environment]::NewLine
        }
        if ($updated -ne $text) {
            [IO.File]::WriteAllText($configPath, $updated, [Text.UTF8Encoding]::new($false))
            Write-Log -Message "Modo ventana confirmado en $configPath"
        }
        return $true
    } catch {
        Write-Status -Level 'WARN' -Message ("No se pudo editar la configuracion grafica: " + $_.Exception.Message)
        Write-Status -Level 'WARN' -Message 'Se continuara con -windowed; no es necesario ejecutar como administrador.'
        return $false
    }
}

function Get-GameProcesses {
    param([string]$ExeName)
    $name = [IO.Path]::GetFileNameWithoutExtension($ExeName)
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue)
}

function Invoke-BorderlessOneShot {
    param(
        [object[]]$Processes,
        [bool]$Topmost
    )

    foreach ($process in $Processes) {
        $handle = [BorderlessNative]::FindBestWindow($process.Id)
        if ($handle -eq [IntPtr]::Zero) { continue }

        [BorderlessNative]::PrepareBorderless($handle)
        Start-Sleep -Milliseconds 120
        $result = [BorderlessNative]::EnsureBorderless($handle, $Topmost)
        if ($result -lt 0) {
            Write-Status -Level 'WARN' -Message 'Windows no permitio modificar la ventana. Espera al menu y pulsa Ctrl+Alt+F11 otra vez.'
            return $false
        }

        $bounds = [BorderlessNative]::GetBounds($handle)
        Write-Status -Level 'OK' -Message "BORDERLESS APLICADO UNA VEZ ($bounds)."
        Write-Log -Message "Borderless manual aplicado una vez al PID $($process.Id), handle $handle."
        return $true
    }

    Write-Status -Level 'WARN' -Message 'Todavia no se encontro la ventana del juego. Espera al menu y pulsa Ctrl+Alt+F11 otra vez.'
    return $false
}

function Start-AndMonitorGame {
    param([hashtable]$Settings)

    $gameExe = Get-RequiredSetting $Settings 'GAME_EXE'
    $steamExe = Resolve-ConfiguredPath (Get-RequiredSetting $Settings 'STEAM_EXE')
    $appId = Get-RequiredSetting $Settings 'APPID'
    $borderless = Get-BoolSetting $Settings 'BORDERLESS_ENABLED' $true
    $topmost = Get-BoolSetting $Settings 'BORDERLESS_TOPMOST' $false
    $pollMs = Get-IntSetting $Settings 'BORDERLESS_POLL_MS' 100 50 2000
    $lockMs = Get-IntSetting $Settings 'BORDERLESS_LOCK_MS' 8 5 100
    $automaticDelay = Get-IntSetting $Settings 'BORDERLESS_DELAY_SECONDS' 20 0 300
    $forceNativeResolution = Get-BoolSetting $Settings 'FORCE_NATIVE_RESOLUTION' $true
    $launchArguments = if ($Settings.ContainsKey('LAUNCH_ARGUMENTS')) { [string]$Settings['LAUNCH_ARGUMENTS'] } else { '-windowed' }
    $borderlessMode = if ($Settings.ContainsKey('BORDERLESS_MODE')) { ([string]$Settings['BORDERLESS_MODE']).Trim().ToLowerInvariant() } else { 'manual' }
    if ($borderlessMode -notin @('manual', 'once', 'lock')) {
        throw "BORDERLESS_MODE debe ser manual, once o lock; valor recibido: $borderlessMode"
    }

    if ($borderless) { Add-BorderlessNativeType }
    $windowConfigReady = Set-GameWindowed -Settings $Settings -QuietIfMissing

    if ($borderless -and $forceNativeResolution) {
        $nativeWidth = [BorderlessNative]::GetPrimaryWidth()
        $nativeHeight = [BorderlessNative]::GetPrimaryHeight()
        if ($launchArguments -notmatch '(?i)(^|\s)-ResX=') { $launchArguments += " -ResX=$nativeWidth" }
        if ($launchArguments -notmatch '(?i)(^|\s)-ResY=') { $launchArguments += " -ResY=$nativeHeight" }
        if ($launchArguments -notmatch '(?i)(^|\s)-WinX=') { $launchArguments += ' -WinX=0' }
        if ($launchArguments -notmatch '(?i)(^|\s)-WinY=') { $launchArguments += ' -WinY=0' }
        Write-Log -Message "Resolucion interna solicitada: ${nativeWidth}x${nativeHeight}."
    }

    $running = @(Get-GameProcesses $gameExe)
    if ($running.Count -gt 0) {
        Write-Status -Level 'WARN' -Message 'LET IT DIE ya esta abierto; el launcher se conectara a esa sesion.'
    } else {
        Write-Status -Message 'Abriendo LET IT DIE mediante Steam...'
        if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
            $argumentLine = "-applaunch $appId"
            if (-not [string]::IsNullOrWhiteSpace($launchArguments)) { $argumentLine += ' ' + $launchArguments.Trim() }
            Start-Process -FilePath $steamExe -ArgumentList $argumentLine | Out-Null
        } else {
            Write-Status -Level 'WARN' -Message "No se encontro steam.exe en $steamExe; se intentara abrir el protocolo de Steam."
            Start-Process ("steam://rungameid/" + $appId) | Out-Null
        }
    }

    if ($borderless -and $borderlessMode -eq 'manual') {
        Write-Status -Message 'Modo borderless sin parpadeo: espera a que aparezca el menu y pulsa Ctrl+Alt+F11 una vez.'
    } elseif ($borderless -and $borderlessMode -eq 'once') {
        Write-Status -Message "Borderless automatico de una sola aplicacion: se intentara $automaticDelay segundos despues de detectar la ventana."
    } elseif ($borderless -and $borderlessMode -eq 'lock') {
        Write-Status -Level 'WARN' -Message 'Modo lock continuo activo. Puede causar parpadeo si el juego restaura su ventana.'
    }

    $startDeadline = [DateTime]::UtcNow.AddMinutes(3)
    $seenGame = $false
    $lastSeen = [DateTime]::MinValue
    $knownHandles = @{}
    $trackers = @{}
    $lastApplyCounts = @{}
    $lastReapplyLog = [DateTime]::MinValue
    $hotkeyWasDown = $false
    $hotkeyPromptShown = $false
    $firstWindowSeen = [DateTime]::MinValue
    $onceApplied = $false
    $warnedNoWindow = $false
    $warnedNoConfig = $false
    $gameFirstSeen = [DateTime]::MinValue
    $lastConfigTry = [DateTime]::MinValue

    try {
        while ($true) {
            $processes = @(Get-GameProcesses $gameExe)
            if ($processes.Count -gt 0) {
                if (-not $seenGame) {
                    $seenGame = $true
                    $gameFirstSeen = [DateTime]::UtcNow
                    Write-Status -Level 'OK' -Message 'Proceso de LET IT DIE detectado.'
                }
                $lastSeen = [DateTime]::UtcNow

                if (-not $windowConfigReady -and ([DateTime]::UtcNow - $lastConfigTry).TotalSeconds -ge 1) {
                    $lastConfigTry = [DateTime]::UtcNow
                    $windowConfigReady = Set-GameWindowed -Settings $Settings -QuietIfMissing
                }
                if (-not $windowConfigReady -and -not $warnedNoConfig -and ([DateTime]::UtcNow - $gameFirstSeen).TotalSeconds -ge 30) {
                    $warnedNoConfig = $true
                    Write-Status -Level 'WARN' -Message 'BrgGraphicsConfig.ini aun no existe; se mantienen -windowed y la resolucion nativa por parametros.'
                }

                if ($borderless) {
                    $foundWindow = $false
                    foreach ($process in $processes) {
                        $handle = [BorderlessNative]::FindBestWindow($process.Id)
                        if ($handle -ne [IntPtr]::Zero) {
                            $foundWindow = $true
                            if ($firstWindowSeen -eq [DateTime]::MinValue) {
                                $firstWindowSeen = [DateTime]::UtcNow
                            }
                        }
                    }

                    if ($foundWindow -and -not $hotkeyPromptShown -and $borderlessMode -ne 'lock') {
                        $hotkeyPromptShown = $true
                        Write-Status -Level 'OK' -Message 'Ventana lista. En el menu, pulsa Ctrl+Alt+F11 para aplicar o repetir el borderless.'
                    }

                    if ($borderlessMode -eq 'manual' -or $borderlessMode -eq 'once') {
                        $hotkeyDown = [BorderlessNative]::IsManualHotkeyDown()
                        if ($hotkeyDown -and -not $hotkeyWasDown) {
                            $manualApplied = Invoke-BorderlessOneShot -Processes $processes -Topmost $topmost
                            if ($manualApplied -and $borderlessMode -eq 'once') { $onceApplied = $true }
                        }
                        $hotkeyWasDown = $hotkeyDown

                        if ($borderlessMode -eq 'once' -and -not $onceApplied -and $firstWindowSeen -ne [DateTime]::MinValue -and ([DateTime]::UtcNow - $firstWindowSeen).TotalSeconds -ge $automaticDelay) {
                            $onceApplied = Invoke-BorderlessOneShot -Processes $processes -Topmost $topmost
                        }
                    } else {
                        $activePids = @{}
                        foreach ($process in $processes) {
                            $pidKey = $process.Id.ToString()
                            $activePids[$pidKey] = $true
                            if (-not $trackers.ContainsKey($pidKey)) {
                                $trackers[$pidKey] = [BorderlessTracker]::new($process.Id, $topmost, $lockMs)
                                $lastApplyCounts[$pidKey] = 0L
                                Write-Log -Message "Vigilante nativo iniciado para PID $pidKey cada $lockMs ms."
                            }

                            $tracker = $trackers[$pidKey]
                            $handleValue = [long]$tracker.CurrentHandle
                            if ($handleValue -eq 0) { continue }
                            $handleKey = $handleValue.ToString()
                            if (-not $knownHandles.ContainsKey($handleKey)) {
                                $knownHandles[$handleKey] = $true
                                $bounds = [BorderlessNative]::GetBounds([IntPtr]$handleValue)
                                Write-Status -Level 'OK' -Message "BORDERLESS BLOQUEADO ($bounds; respuesta ${lockMs}ms)."
                            }

                            $applyCount = [long]$tracker.ApplyCount
                            if ($applyCount -gt [long]$lastApplyCounts[$pidKey] -and ([DateTime]::UtcNow - $lastReapplyLog).TotalSeconds -ge 10) {
                                $lastReapplyLog = [DateTime]::UtcNow
                                Write-Log -Message "LET IT DIE intento restaurar la ventana; bloqueo borderless activo (reaplicaciones: $applyCount)."
                            }
                            $lastApplyCounts[$pidKey] = $applyCount
                        }

                        foreach ($pidKey in @($trackers.Keys)) {
                            if (-not $activePids.ContainsKey([string]$pidKey)) {
                                $trackers[$pidKey].Dispose()
                                $null = $trackers.Remove($pidKey)
                                $null = $lastApplyCounts.Remove($pidKey)
                            }
                        }
                    }

                    if (-not $foundWindow -and -not $warnedNoWindow -and $seenGame -and ([DateTime]::UtcNow - $gameFirstSeen).TotalSeconds -gt 20) {
                        $warnedNoWindow = $true
                        Write-Status -Level 'WARN' -Message 'El proceso existe, pero aun no se encontro una ventana visible.'
                    }
                }
            } elseif (-not $seenGame) {
                if ([DateTime]::UtcNow -gt $startDeadline) {
                    throw 'LET IT DIE no aparecio despues de 3 minutos. No se hizo backup porque el juego no llego a ejecutarse.'
                }
            } else {
                if (([DateTime]::UtcNow - $lastSeen).TotalSeconds -ge 5) { break }
            }

            Start-Sleep -Milliseconds $pollMs
        }
    } finally {
        foreach ($tracker in @($trackers.Values)) {
            try { $tracker.Dispose() } catch { }
        }
    }

    Write-Status -Message 'LET IT DIE se cerro.'
}

$mutex = $null
$mutexAcquired = $false
try {
    $mutex = New-Object Threading.Mutex($false, 'Local\LETITDIE_Custom_Launcher_v2')
    try { $mutexAcquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (-not $mutexAcquired) {
        throw 'Ya hay otra instancia del launcher o de la prueba de backup en ejecucion.'
    }

    Write-Log -Message ('--- Inicio v2.3; modo=' + $(if ($BackupOnly) { 'backup-only' } elseif ($SelfTest) { 'self-test' } else { 'launcher' }))
    $settings = Read-LauncherConfig -Path $ConfigPath

    if ($SelfTest) {
        Add-BorderlessNativeType
        $null = Get-RequiredSetting $settings 'SOURCE'
        $null = Get-RequiredSetting $settings 'LOCAL_DEST'
        $null = Get-IntSetting $settings 'BORDERLESS_POLL_MS' 100 50 2000
        $null = Get-IntSetting $settings 'BORDERLESS_DELAY_SECONDS' 20 0 300
        $null = Get-IntSetting $settings 'BORDERLESS_LOCK_MS' 8 5 100
        $testMode = if ($settings.ContainsKey('BORDERLESS_MODE')) { ([string]$settings['BORDERLESS_MODE']).Trim().ToLowerInvariant() } else { 'manual' }
        if ($testMode -notin @('manual', 'once', 'lock')) { throw 'BORDERLESS_MODE debe ser manual, once o lock.' }
        Add-Type -AssemblyName System.Windows.Forms
        $testForm = New-Object System.Windows.Forms.Form
        try {
            $testForm.Text = 'LET IT DIE borderless self-test'
            $testForm.Width = 640
            $testForm.Height = 360
            $testForm.Opacity = 0
            $testForm.ShowInTaskbar = $true
            $testForm.Show()
            [System.Windows.Forms.Application]::DoEvents()
            [BorderlessNative]::PrepareBorderless($testForm.Handle)
            Start-Sleep -Milliseconds 120
            $result = [BorderlessNative]::EnsureBorderless($testForm.Handle, $false)
            [System.Windows.Forms.Application]::DoEvents()
            $bounds = [BorderlessNative]::GetBounds($testForm.Handle)
            $expected = '0,0 - {0}x{1}' -f [BorderlessNative]::GetPrimaryWidth(), [BorderlessNative]::GetPrimaryHeight()
            if ($result -lt 0 -or $bounds -ne $expected) {
                throw "La prueba borderless de una sola aplicacion fallo ($bounds; esperado $expected)."
            }
        } finally {
            $testForm.Close()
            $testForm.Dispose()
        }
        Write-Status -Level 'OK' -Message 'SELF-TEST OK: configuracion y borderless manual cargaron correctamente.'
        exit 0
    }

    $gameExe = Get-RequiredSetting $settings 'GAME_EXE'
    if ($BackupOnly) {
        if (@(Get-GameProcesses $gameExe).Count -gt 0) {
            throw 'Cierra LET IT DIE antes de ejecutar la prueba de backup.'
        }
    } else {
        Start-AndMonitorGame -Settings $settings
        $waitSeconds = Get-IntSetting $settings 'FLUSH_WAIT_SECONDS' 15 0 300
        if ($waitSeconds -gt 0) {
            Write-Status -Message "Esperando $waitSeconds segundos para que el guardado termine de escribirse..."
            Start-Sleep -Seconds $waitSeconds
        }
    }

    Invoke-Backups -Settings $settings
    Write-Status -Level 'OK' -Message 'PROCESO DE BACKUP TERMINADO.'
    if ($script:DriveWarning) { exit 2 }
    exit 0
} catch {
    Write-Status -Level 'ERROR' -Message ("ERROR: " + $_.Exception.Message)
    Write-Status -Level 'ERROR' -Message ("Consulta el registro: " + $script:LogPath)
    exit 1
} finally {
    if ($mutexAcquired -and $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($mutex) { $mutex.Dispose() }
}
