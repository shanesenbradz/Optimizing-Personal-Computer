<#
================================================================================
  OPC V7  |  Optimal Performance Cleaner  |  by Bradley Williams
  One app that bundles OptiCore v2, OPC V6 and the RDP Toolkit.

  Runs on Windows 10 / 11 with what Windows already ships:
  Windows PowerShell 5.1 + .NET Framework 4.8 (WPF). Nothing to install.
  Also runs under PowerShell 7 on Windows.

  Start it with OPC-V7.exe, Run-OPC-V7.cmd, or:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\OPC-V7.ps1
  It asks for administrator rights by itself.

  License: Perpetual Free License. Free to use, share and distribute.
================================================================================
#>
param([switch]$NoElevate)

$ErrorActionPreference = 'Stop'
$AppVersion = '7.0.0'

# ------------------------------------------------------------------------------
#  Elevation + STA
# ------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$NeedSta = [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'

if ((-not $IsAdmin -and -not $NoElevate) -or $NeedSta) {
    $hostExe = (Get-Process -Id $PID).Path
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $PSCommandPath + '"'
    try {
        if ($IsAdmin -or $NoElevate) { Start-Process -FilePath $hostExe -ArgumentList $argLine | Out-Null }
        else { Start-Process -FilePath $hostExe -ArgumentList $argLine -Verb RunAs | Out-Null }
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show('OPC V7 needs administrator rights to optimize Windows. Please accept the UAC prompt to continue.', 'OPC V7', 'OK', 'Warning')
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# From here on, UI event handlers must never throw (an exception would take down the window)
$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------------------
#  Native helpers (memory, CPU, window tweaks)
# ------------------------------------------------------------------------------
$NativeSrc = @'
using System;
using System.Runtime.InteropServices;
namespace OPC {
  public static class Native {
    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("ntdll.dll")] static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool wasEnabled);
    // SystemMemoryListInformation = 80. Commands: 2 = empty working sets, 4 = purge standby list.
    // Needs SeProfileSingleProcessPrivilege (13), which must be switched on first.
    public static int MemCommand(int command) {
      bool was; RtlAdjustPrivilege(13, true, false, out was);
      int v = command; return NtSetSystemInformation(80, ref v, 4);
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MEMSTAT { public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
      public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMSTAT m);
    public static ulong[] Mem() {
      MEMSTAT m = new MEMSTAT(); m.dwLength = (uint)Marshal.SizeOf(typeof(MEMSTAT)); GlobalMemoryStatusEx(ref m);
      return new ulong[] { m.ullTotalPhys, m.ullAvailPhys, m.dwMemoryLoad };
    }
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    static long pIdle, pKernel, pUser;
    public static double Cpu() {
      long i, k, u; GetSystemTimes(out i, out k, out u);
      long di = i - pIdle, dk = k - pKernel, du = u - pUser; pIdle = i; pKernel = k; pUser = u;
      long total = dk + du; if (total <= 0) return 0;
      double v = (total - di) * 100.0 / total; return v < 0 ? 0 : (v > 100 ? 100 : v);
    }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
  }
}
'@
if (-not ('OPC.Native' -as [type])) { Add-Type -TypeDefinition $NativeSrc }

# Hide the PowerShell console and give the app its own taskbar identity
try { $cw = [OPC.Native]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][OPC.Native]::ShowWindow($cw, 0) } } catch {}
try { [void][OPC.Native]::SetCurrentProcessExplicitAppUserModelID('BradleyWilliams.OPC.V7') } catch {}

# ------------------------------------------------------------------------------
#  Paths + settings
# ------------------------------------------------------------------------------
$DataDir      = Join-Path $env:LOCALAPPDATA 'OPCV7'
$LogDir       = Join-Path $DataDir 'logs'
$SettingsPath = Join-Path $DataDir 'settings.json'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Load-Settings {
    $s = @{ Recent = @(); Selected = @(); LastRun = ''; LastSummary = ''; RdpFull = $true; RdpMulti = $false; RdpAdmin = $false }
    if (Test-Path $SettingsPath) {
        try {
            $j = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch {}
    }
    $s.Recent = @($s.Recent | Where-Object { $_ })
    $s.Selected = @($s.Selected | Where-Object { $_ })
    return $s
}
function Save-Settings {
    try { $script:Settings | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsPath -Encoding UTF8 } catch {}
}
$Settings = Load-Settings

# ------------------------------------------------------------------------------
#  Task catalog
#  Risk: Safe | Moderate | Advanced      Flags: Slow, Reboot
# ------------------------------------------------------------------------------
$Groups = @('Cleanup', 'Repair & Health', 'Memory & Power', 'Services & Apps', 'System Tweaks', 'Network', 'Privacy & Updates', 'Reports')

function T([string]$Id, [string]$Group, [string]$Name, [string]$Desc, [string]$Risk, [string[]]$Flags, [scriptblock]$Code) {
    [pscustomobject]@{ Id = $Id; Group = $Group; Name = $Name; Desc = $Desc; Risk = $Risk; Flags = @($Flags | Where-Object { $_ }); Code = $Code }
}

$Catalog = @(
# ---------------------------------------------------------------- Cleanup
T 'restore' 'Cleanup' 'Create a restore point' 'Turns on System Protection for the system drive if needed and saves a restore point first, so every change below can be rolled back.' 'Safe' @() {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
    try { $null = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName Enable -Arguments @{ Drive = "$env:SystemDrive\" } -ErrorAction Stop }
    catch { Skip "Could not switch on System Protection: $($_.Exception.Message)" }
    Sub 'Creating restore point...'
    try {
        $r = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = 'OPC V7 - before optimization'; RestorePointType = [uint32]12; EventType = [uint32]100 } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) { Ok 'Restore point created' }
        else { Warn "Restore point not created (code $($r.ReturnValue)). System Protection may be blocked by policy." }
    } catch { Warn "Restore point failed: $($_.Exception.Message)" }
}
T 'temp' 'Cleanup' 'Temporary files' 'Empties your TEMP folder and C:\Windows\Temp. Files that are in use are skipped.' 'Safe' @() {
    Clear-Folder $env:TEMP 'User temp'
    Clear-Folder (Join-Path $env:SystemRoot 'Temp') 'Windows temp'
}
T 'wer' 'Cleanup' 'Error reports, CBS logs and shader cache' 'Removes queued Windows Error Reporting files, CBS setup logs, Downloaded Program Files and the DirectX shader cache.' 'Safe' @() {
    Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" 'Error report queue'
    Clear-Folder "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" 'Error report archive'
    Clear-Folder "$env:SystemRoot\Logs\CBS" 'CBS logs'
    Clear-Folder "$env:SystemRoot\Downloaded Program Files" 'Downloaded Program Files'
    Clear-Folder "$env:LOCALAPPDATA\D3DSCache" 'DirectX shader cache'
}
T 'delivopt' 'Cleanup' 'Delivery Optimization cache' 'Clears the peer-to-peer update cache Windows keeps to share updates with other PCs.' 'Safe' @() {
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Ok 'Delivery Optimization cache cleared' }
    catch { Clear-Folder "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" 'Delivery Optimization cache' }
}
T 'wucache' 'Cleanup' 'Windows Update downloads' 'Stops the update services, clears already-installed update downloads, then starts them again. Update history is kept.' 'Safe' @() {
    foreach ($s in 'wuauserv', 'bits', 'dosvc') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download" 'Windows Update downloads'
    foreach ($s in 'bits', 'wuauserv', 'dosvc') { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Ok 'Update services running again'
}
T 'browsers' 'Cleanup' 'Browser caches' 'Clears the disk cache of Chrome, Edge, Brave (all profiles) and Firefox. Logins, history and cookies are not touched. Close browsers first for the best result.' 'Safe' @() {
    $chromium = @(
        @('Chrome', "$env:LOCALAPPDATA\Google\Chrome\User Data"),
        @('Edge',   "$env:LOCALAPPDATA\Microsoft\Edge\User Data"),
        @('Brave',  "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data")
    )
    foreach ($b in $chromium) {
        if (-not (Test-Path -LiteralPath $b[1])) { Skip "$($b[0]) not installed"; continue }
        $total = 0.0
        $profiles = Get-ChildItem -LiteralPath $b[1] -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
        foreach ($p in $profiles) {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
                $path = Join-Path $p.FullName $sub
                if (Test-Path -LiteralPath $path) { Clear-Folder $path "$($b[0]) cache" -Silent; $total += $sync.LastFreed }
            }
        }
        Ok ('{0}: freed {1}' -f $b[0], (Fmt-Size $total))
    }
    $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ff) {
        $total = 0.0
        foreach ($p in (Get-ChildItem -LiteralPath $ff -Directory -Force -ErrorAction SilentlyContinue)) {
            $path = Join-Path $p.FullName 'cache2'
            if (Test-Path -LiteralPath $path) { Clear-Folder $path 'Firefox cache' -Silent; $total += $sync.LastFreed }
        }
        Ok ('Firefox: freed {0}' -f (Fmt-Size $total))
    } else { Skip 'Firefox not installed' }
}
T 'wsreset' 'Cleanup' 'Microsoft Store cache' 'Runs wsreset with a 20 second limit (the V6 Store hang fix). The Store may open when it finishes.' 'Safe' @() {
    Sub 'Waiting for wsreset (20s max)'
    $p = Start-Process -FilePath 'wsreset.exe' -WindowStyle Hidden -PassThru
    if ($p.WaitForExit(20000)) { Ok 'Microsoft Store cache reset' }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Skip 'wsreset hung for 20s and was stopped' }
}
T 'cleanmgr' 'Cleanup' 'Windows Disk Cleanup' 'Runs the built-in Disk Cleanup silently on update leftovers, logs, dumps and temp setup files. Leaves Windows.old, the Recycle Bin, Downloads and Reset-this-PC files alone.' 'Safe' @('Slow') {
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $include = @('Active Setup Temp Folders', 'BranchCache', 'Delivery Optimization Files', 'Device Driver Packages', 'Downloaded Program Files',
        'Internet Cache Files', 'Memory Dump Files', 'Old ChkDsk Files', 'Setup Log Files', 'System error memory dump files',
        'System error minidump files', 'Temporary Files', 'Temporary Setup Files', 'Temporary Sync Files', 'Thumbnail Cache',
        'Update Cleanup', 'Upgrade Discarded Files', 'Windows Defender', 'Windows Error Reporting Files', 'Windows Upgrade Log Files')
    foreach ($k in (Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
        $v = 0; if ($include -contains $k.PSChildName) { $v = 2 }
        $null = New-ItemProperty -LiteralPath $k.PSPath -Name 'StateFlags0099' -Value $v -PropertyType DWord -Force -ErrorAction SilentlyContinue
    }
    Sub 'Disk Cleanup is running (can take several minutes)'
    $p = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:99' -WindowStyle Hidden -PassThru
    if ($p.WaitForExit(1200000)) { Ok 'Disk Cleanup finished' }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Warn 'Disk Cleanup did not finish within 20 minutes and was stopped' }
}
T 'compcleanup' 'Cleanup' 'Component store cleanup (WinSxS)' 'DISM StartComponentCleanup. Reclaims space from superseded updates. Those old updates can no longer be uninstalled afterwards.' 'Moderate' @('Slow') {
    $code = Invoke-Exe 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup /NoRestart'
    if ($code -eq 0) { Ok 'Component store cleaned' } else { Warn "DISM exited with code $code" }
}
T 'recycle' 'Cleanup' 'Empty the Recycle Bin' 'Permanently deletes everything in the Recycle Bin on all drives.' 'Moderate' @() {
    try { Clear-RecycleBin -Force -ErrorAction Stop; Ok 'Recycle Bin emptied' }
    catch { Skip 'Recycle Bin was already empty' }
}
T 'thumbs' 'Cleanup' 'Rebuild thumbnail and icon cache' 'Fixes blank or wrong icons and thumbnails. Your taskbar and desktop disappear for a few seconds while Explorer restarts.' 'Moderate' @() {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    $n = 0
    foreach ($f in (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter '*cache_*.db' -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch {}
    }
    Remove-Item -LiteralPath "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Ok "Removed $n cache file(s). Explorer restarted."
}
T 'fontcache' 'Cleanup' 'Rebuild font cache' 'Fixes garbled or slow-loading fonts. Windows rebuilds the cache on demand.' 'Moderate' @() {
    Stop-Service -Name FontCache -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'FontCache3.0.0.0' -Force -ErrorAction SilentlyContinue
    Clear-Folder "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache" 'Font cache'
    Remove-Item -LiteralPath "$env:SystemRoot\System32\FNTCACHE.DAT" -Force -ErrorAction SilentlyContinue
    Start-Service -Name FontCache -ErrorAction SilentlyContinue
}
T 'prefetch' 'Cleanup' 'Clear Prefetch' 'From V6. Note: Prefetch speeds up app launches, so apps open slower for a few days while Windows relearns. Little real benefit.' 'Advanced' @() {
    Clear-Folder "$env:SystemRoot\Prefetch" 'Prefetch'
}
T 'winold' 'Cleanup' 'Remove Windows.old' 'Deletes the previous Windows installation. Frees a lot of space but you can no longer roll back the last Windows upgrade.' 'Advanced' @('Slow') {
    $w = Join-Path $env:SystemDrive 'Windows.old'
    if (-not (Test-Path -LiteralPath $w)) { Skip 'Windows.old not found'; return }
    $size = Get-FolderBytes $w
    Sub 'Taking ownership of Windows.old'
    $null = Invoke-Exe 'takeown.exe' "/F `"$w`" /R /A /D Y" -Quiet
    $null = Invoke-Exe 'icacls.exe' "`"$w`" /grant *S-1-5-32-544:F /T /C /Q" -Quiet
    Sub 'Deleting Windows.old'
    $null = Invoke-Exe 'cmd.exe' "/c rd /s /q `"$w`"" -Quiet
    if (Test-Path -LiteralPath $w) { Warn 'Part of Windows.old could not be removed. Disk Cleanup > Previous Windows installation(s) can finish it.' }
    else { $sync.Freed += $size; Ok ('Windows.old removed ({0})' -f (Fmt-Size $size)) }
}
T 'eventlogs' 'Cleanup' 'Clear all event logs' 'Backs up System, Application and Security logs to the OPC logs folder, then clears every channel. You lose the troubleshooting and audit trail on this PC.' 'Advanced' @() {
    $bk = Join-Path $sync.LogDir ('eventlogs-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    foreach ($l in 'System', 'Application', 'Security') { & wevtutil.exe epl $l (Join-Path $bk "$l.evtx") 2>$null }
    Ok "Backup saved to $bk"
    $names = @(& wevtutil.exe el); $c = 0; $f = 0; $i = 0
    foreach ($n in $names) {
        $i++; if ($i % 40 -eq 0) { Sub ('Clearing channel {0} of {1}' -f $i, $names.Count) }
        & wevtutil.exe cl "$n" 2>$null
        if ($LASTEXITCODE -eq 0) { $c++ } else { $f++ }
    }
    Ok "Cleared $c channel(s). $f skipped (protected or in use)."
}

# ---------------------------------------------------------------- Repair & Health
T 'dism' 'Repair & Health' 'DISM RestoreHealth' 'Scans and repairs the Windows image using Windows Update as the source. Includes the CheckHealth and ScanHealth passes V6 ran separately.' 'Safe' @('Slow') {
    $code = Invoke-Exe 'dism.exe' '/Online /Cleanup-Image /RestoreHealth'
    if ($code -eq 0) { Ok 'Windows image is healthy' } else { Warn "DISM exited with code $code. Check the log above." }
}
T 'sfc' 'Repair & Health' 'System File Checker' 'sfc /scannow. Finds and replaces corrupted protected system files. Best run after DISM.' 'Safe' @('Slow') {
    $code = Invoke-Exe 'sfc.exe' '/scannow' -Unicode
    if ($code -eq 0) { Ok 'SFC found no integrity violations' } else { Warn "SFC finished with code $code. Details: C:\Windows\Logs\CBS\CBS.log" }
}
T 'smart' 'Repair & Health' 'Disk health report' 'Shows health, media type, size, temperature and wear for every physical disk. Read-only.' 'Safe' @() {
    foreach ($d in (Get-PhysicalDisk | Sort-Object DeviceId)) {
        $r = $null; try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $line = '{0}  |  {1}  |  {2} GB  |  {3}' -f $d.FriendlyName, $d.MediaType, [math]::Round($d.Size / 1GB), $d.HealthStatus
        if ($r -and $r.Temperature) { $line += "  |  $($r.Temperature) C" }
        if ($r -and $null -ne $r.Wear) { $line += "  |  wear $($r.Wear)%" }
        if ("$($d.HealthStatus)" -eq 'Healthy') { Ok $line } else { Warn $line }
    }
}
T 'drives' 'Repair & Health' 'Optimize drives (TRIM / defrag)' 'Lets Windows pick the right action per drive: TRIM for SSDs, defrag for hard disks. A full HDD defrag can take a long time.' 'Safe' @('Slow') {
    $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and @('NTFS', 'ReFS') -contains $_.FileSystemType }
    foreach ($v in $vols) {
        $l = $v.DriveLetter; $media = 'Unknown'
        try {
            $num = (Get-Partition -DriveLetter $l -ErrorAction Stop | Get-Disk).Number
            $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$num" }
            if ($pd) { $media = "$($pd.MediaType)" }
        } catch {}
        Sub "Optimizing drive $($l): ($media)"
        try { Optimize-Volume -DriveLetter $l -ErrorAction Stop; Ok "Drive $($l): optimized ($media)" }
        catch { Warn "Drive $($l): $($_.Exception.Message)" }
    }
}
T 'spooler' 'Repair & Health' 'Flush print queue' 'Stops the Print Spooler, deletes stuck print jobs and starts it again.' 'Safe' @() {
    Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
    $dir = "$env:SystemRoot\System32\spool\PRINTERS"
    $n = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count
    Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service -Name Spooler -ErrorAction SilentlyContinue
    Ok "Print queue flushed ($n file(s))"
}
T 'wureset' 'Repair & Health' 'Reset Windows Update components' 'Renames SoftwareDistribution and catroot2 so Windows rebuilds them. Fixes stuck or failing updates. Update history view is reset.' 'Advanced' @() {
    $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    foreach ($pair in @(@("$env:SystemRoot\SoftwareDistribution", 'SoftwareDistribution.old'), @("$env:SystemRoot\System32\catroot2", 'catroot2.old'))) {
        $src = $pair[0]; $old = Join-Path (Split-Path $src -Parent) $pair[1]
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        try { Rename-Item -LiteralPath $src -NewName $pair[1] -ErrorAction Stop; Ok "Renamed $($src)" }
        catch { Warn "Could not rename $($src): $($_.Exception.Message)" }
    }
    foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Ok 'Windows Update components reset'
}
T 'chkdsk' 'Repair & Health' 'Schedule chkdsk on next restart' 'chkdsk /F /R /X on the system drive. The next boot can take an hour or more on large drives. Do not power off during it.' 'Advanced' @('Reboot') {
    $null = Invoke-Exe 'cmd.exe' "/c echo Y| chkdsk $env:SystemDrive /F /R /X"
    Ok 'chkdsk will run at the next restart'
}

# ---------------------------------------------------------------- Memory & Power
T 'ram' 'Memory & Power' 'Free up RAM' 'Trims process working sets and purges the standby list using the kernel call (fixed from V6, which sent the wrong command and lacked the privilege).' 'Safe' @() {
    $before = ([OPC.Native]::Mem())[1]
    $s1 = [OPC.Native]::MemCommand(2)
    if ($s1 -ne 0) {
        foreach ($p in (Get-Process)) { try { [void][OPC.Native]::EmptyWorkingSet($p.Handle) } catch {} }
        Skip ('Kernel trim unavailable (0x{0:X8}), trimmed each process instead' -f $s1)
    } else { Ok 'Working sets trimmed' }
    $s2 = [OPC.Native]::MemCommand(4)
    if ($s2 -eq 0) { Ok 'Standby list purged' } else { Skip ('Standby purge refused (0x{0:X8})' -f $s2) }
    Start-Sleep -Milliseconds 600
    $after = ([OPC.Native]::Mem())[1]
    Ok ('Available RAM: {0} -> {1}' -f (Fmt-Size $before), (Fmt-Size $after))
}
T 'pagefile' 'Memory & Power' 'System-managed page file' 'Lets Windows size the page file automatically. Applies after a restart.' 'Moderate' @('Reboot') {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { Skip 'Page file is already system-managed'; return }
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
    Ok 'Page file set to system-managed'
}
T 'power' 'Memory & Power' 'Ultimate Performance power plan' 'Activates Ultimate Performance (created once, not duplicated on every run like V6), falls back to High Performance. Turns off disk sleep on AC. Uses more power on laptops.' 'Moderate' @() {
    $ult = 'e9a42b02-d5df-448d-aa00-03f14749eb61'; $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $list = (& powercfg.exe /list) -join "`n"
    $saved = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OPCV7' -ErrorAction SilentlyContinue).UltimateGuid
    $guid = $null
    if ($saved -and $list -match [regex]::Escape($saved)) { $guid = $saved }
    elseif ($list -match $ult) { $guid = $ult }
    else {
        $out = (& powercfg.exe -duplicatescheme $ult 2>&1) -join ' '
        if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $guid = $Matches[1]; Set-Reg 'HKLM:\SOFTWARE\OPCV7' 'UltimateGuid' $guid 'String'
        }
    }
    if ($guid) { & powercfg.exe /setactive $guid | Out-Null; Ok 'Ultimate Performance plan active' }
    elseif ($list -match $high) { & powercfg.exe /setactive $high | Out-Null; Ok 'High Performance plan active' }
    else { Warn 'This PC uses Modern Standby, which hides the performance plans. Kept the current plan.' }
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_DISK DISKIDLE 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    Ok 'Disk sleep on AC power disabled'
}
T 'cpu100' 'Memory & Power' 'Lock CPU at 100% on AC' 'Minimum processor state 100% while plugged in. More heat and fan noise for slightly snappier response.' 'Advanced' @() {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    Ok 'CPU min/max state set to 100% on AC'
}
T 'hibernate' 'Memory & Power' 'Turn off hibernation' 'Deletes hiberfil.sys (often several GB). Also turns off Fast Startup and the Hibernate option.' 'Moderate' @() {
    & powercfg.exe /hibernate off
    Ok 'Hibernation off, hiberfil.sys removed'
}

# ---------------------------------------------------------------- Services & Apps
T 'killapps' 'Services & Apps' 'Close background apps' 'The OptiCore v2 sweep: closes OneDrive, Phone Link, Skype, Cortana, Game Bar and Widgets for this session. They come back on next sign-in.' 'Safe' @() {
    foreach ($n in 'OneDrive', 'PhoneExperienceHost', 'YourPhone', 'SkypeApp', 'Cortana', 'GameBar', 'Widgets') {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; Ok "Closed $n" } else { Skip "$n not running" }
    }
}
T 'svc-telemetry' 'Services & Apps' 'Telemetry and legacy services' 'Disables DiagTrack, WAP Push, Maps, Retail Demo, Fax, WMP sharing, Remote Registry and Link Tracking. The OptiCore v2 list plus V6 additions.' 'Moderate' @() {
    Disable-Svc @('DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo', 'Fax', 'WMPNetworkSvc', 'RemoteRegistry', 'TrkWks')
}
T 'svc-xbox' 'Services & Apps' 'Xbox services' 'Disables Xbox Live auth, game saves, networking and accessory services. Breaks the Xbox app, Game Pass and controller pairing.' 'Moderate' @() {
    Disable-Svc @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc')
}
T 'bgapps' 'Services & Apps' 'Stop background apps' 'Blocks Store apps from running in the background for this user. Some app notifications may stop.' 'Moderate' @() {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Ok 'Background apps disabled'
}
T 'svc-search' 'Services & Apps' 'Disable Windows Search indexing' 'Stops the indexer. Start menu, File Explorer and Outlook search get much slower and less complete.' 'Advanced' @() {
    Disable-Svc @('WSearch')
}
T 'svc-sysmain' 'Services & Apps' 'Disable SysMain (Superfetch)' 'Can help on low-RAM PCs with hard disks. On SSDs the gain is usually zero.' 'Advanced' @() {
    Disable-Svc @('SysMain')
}
T 'svc-extra' 'Services & Apps' 'Disable location, biometrics and sharing' 'From V6: Geolocation, Windows Biometric and Internet Connection Sharing. Breaks Windows Hello face/fingerprint, location features and Mobile Hotspot.' 'Advanced' @() {
    Disable-Svc @('lfsvc', 'WbioSrvc', 'SharedAccess')
}

# ---------------------------------------------------------------- System Tweaks
T 'ui' 'System Tweaks' 'Visual effects: best performance' 'No menu delay, no animations or shadows, ClearType kept on. Sign out and back in to see all of it.' 'Safe' @() {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'TaskbarAnimations' 0; Set-Reg $adv 'ListviewAlphaSelect' 0; Set-Reg $adv 'ListviewShadow' 0
    Ok 'Visual effects tuned for performance'
}
T 'shutdown' 'System Tweaks' 'Faster shutdown' 'Shorter wait before Windows closes hung apps and services on shutdown. Apps get less time to save, so save your work first.' 'Moderate' @() {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'HungAppTimeout' '1000' 'String'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '2000' 'String'
    Ok 'Shutdown timeouts reduced'
}
T 'ntfs' 'System Tweaks' 'NTFS tweaks' 'Turns off last-access timestamps and 8.3 short names, and gives NTFS more memory for its cache.' 'Moderate' @('Reboot') {
    & fsutil.exe behavior set disablelastaccess 1
    & fsutil.exe behavior set disable8dot3 1
    & fsutil.exe behavior set memoryusage 2
    Ok 'NTFS behavior updated'
}
T 'gpu' 'System Tweaks' 'Hardware-accelerated GPU scheduling' 'Turns on HAGS. Needs a supported GPU and driver. Applies after a restart.' 'Moderate' @('Reboot') {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Ok 'HAGS enabled'
}
T 'bsod' 'System Tweaks' 'Stay on blue screen instead of rebooting' 'Lets you read the stop code. On an unattended or remote PC this means it hangs on the error until someone restarts it.' 'Moderate' @() {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'AutoReboot' 0
    Ok 'Auto-reboot on BSOD disabled'
}
T 'kernel' 'System Tweaks' 'Kernel and boot tweaks' 'Keeps the kernel in RAM, boosts foreground apps (Win32PrioritySeparation 0x26) and sets the boot menu timeout to 5s.' 'Advanced' @('Reboot') {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
    & bcdedit.exe /timeout 5 | Out-Null
    Ok 'Kernel and boot settings applied'
}

# ---------------------------------------------------------------- Network
T 'dns' 'Network' 'Flush DNS and ARP cache' 'Clears stale name lookups and the ARP table. No disconnect.' 'Safe' @() {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    & ipconfig.exe /flushdns | Out-Null
    & netsh.exe interface ip delete arpcache | Out-Null
    Ok 'DNS and ARP caches flushed'
}
T 'tcp' 'Network' 'TCP tuning' 'Sets receive window auto-tuning to normal and enables Receive Side Scaling. (V6 chimney/NetDMA settings were dropped, Windows 10/11 removed them.)' 'Safe' @() {
    & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
    & netsh.exe int tcp set global rss=enabled | Out-Null
    Ok 'TCP auto-tuning normal, RSS enabled'
}
T 'nicpower' 'Network' 'USB and network adapter power saving off' 'Stops Windows from powering down USB ports and network adapters to save energy. Fixes drop-outs and wake lag. Adapter change applies at next adapter restart.' 'Moderate' @() {
    & powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    Ok 'USB selective suspend off (AC)'
    foreach ($a in (Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        try { Disable-NetAdapterPowerManagement -Name $a.Name -NoRestart -ErrorAction Stop; Ok "Power saving off: $($a.Name)" }
        catch { Skip "$($a.Name): not supported" }
    }
}
T 'netreset' 'Network' 'Reset network stack' 'Winsock, TCP/IP and IPv6 reset. Fixes broken connectivity. Static IP settings may need to be entered again. Restart required.' 'Advanced' @('Reboot') {
    & netsh.exe winsock reset
    & netsh.exe int ip reset
    & netsh.exe int ipv6 reset
    Ok 'Network stack reset'
}
T 'iprenew' 'Network' 'Release and renew IP' 'Drops the network for a few seconds. Do not run this over Remote Desktop, you will be disconnected.' 'Advanced' @() {
    & ipconfig.exe /release | Out-Null
    & ipconfig.exe /renew | Out-Null
    Ok 'IP address renewed'
}
T 'firewall' 'Network' 'Reset Windows Firewall' 'Restores default firewall rules and deletes all custom ones, including the Remote Desktop rule. Re-enable RDP on the Remote Desktop page afterwards.' 'Advanced' @() {
    & netsh.exe advfirewall reset
    Ok 'Firewall reset to defaults'
}

# ---------------------------------------------------------------- Privacy & Updates
T 'telemetry' 'Privacy & Updates' 'Telemetry, ads ID, activity history, Cortana' 'Sets diagnostic data to the minimum, turns off the advertising ID, activity history and Cortana. (V6 skipped some of these silently because the registry keys did not exist yet.)' 'Safe' @() {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Ok 'Privacy settings applied'
    Log 'Home and Pro editions treat telemetry level 0 as Required (level 1).'
}
T 'schtasks' 'Privacy & Updates' 'Telemetry scheduled tasks' 'Disables compatibility appraiser, CEIP, disk diagnostics, feedback and error-report upload tasks. (V6 passed the task path without its trailing slash, so these never actually disabled.)' 'Safe' @() {
    $list = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Maps\MapsUpdateTask',
        '\Microsoft\Windows\Maps\MapsToastTask',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    )
    foreach ($item in $list) {
        $idx = $item.LastIndexOf('\'); $path = $item.Substring(0, $idx + 1); $name = $item.Substring($idx + 1)
        try { $null = Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop; Ok "Disabled: $name" }
        catch { Skip "Not present: $name" }
    }
}
T 'wunoreboot' 'Privacy & Updates' 'No forced update restarts' 'Windows Update will not restart the PC on its own while someone is signed in.' 'Safe' @() {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Ok 'Automatic update restarts blocked while signed in'
}
T 'wupause' 'Privacy & Updates' 'Pause Windows Update for 7 days' 'Sets all the pause keys Settings uses (V6 only set one, which did not pause anything). You miss security fixes for that week.' 'Advanced' @() {
    $k = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $now = (Get-Date).ToUniversalTime(); $end = $now.AddDays(7); $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
    Set-Reg $k 'PauseUpdatesStartTime' $now.ToString($fmt) 'String'
    Set-Reg $k 'PauseUpdatesExpiryTime' $end.ToString($fmt) 'String'
    Set-Reg $k 'PauseFeatureUpdatesStartTime' $now.ToString($fmt) 'String'
    Set-Reg $k 'PauseFeatureUpdatesEndTime' $end.ToString($fmt) 'String'
    Set-Reg $k 'PauseQualityUpdatesStartTime' $now.ToString($fmt) 'String'
    Set-Reg $k 'PauseQualityUpdatesEndTime' $end.ToString($fmt) 'String'
    Ok ('Updates paused until {0:yyyy-MM-dd}' -f $end.ToLocalTime())
}

# ---------------------------------------------------------------- Reports
T 'startup' 'Reports' 'Startup apps report' 'Lists everything that starts with Windows so you can switch off what you do not need in Task Manager > Startup apps. Read-only.' 'Safe' @() {
    $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { Skip 'No startup entries found'; return }
    foreach ($i in ($items | Sort-Object Location, Name)) { Log ('{0}   [{1}]' -f $i.Name, $i.Location) }
    Ok "$($items.Count) startup entries listed"
}
)

$TaskById = @{}; foreach ($t in $Catalog) { $TaskById[$t.Id] = $t }

$Presets = @{
    Quick       = @('temp', 'wer', 'delivopt', 'browsers', 'dns', 'ram', 'smart')
    Recommended = @('restore', 'temp', 'wer', 'delivopt', 'wucache', 'browsers', 'wsreset', 'cleanmgr', 'smart', 'drives', 'ram', 'dns', 'tcp', 'svc-telemetry', 'ui', 'telemetry', 'schtasks', 'wunoreboot', 'startup')
    OptiCore    = @('temp', 'killapps', 'svc-telemetry', 'svc-xbox')
    V6          = @($Catalog | Where-Object { @('killapps', 'compcleanup', 'wucache') -notcontains $_.Id } | ForEach-Object { $_.Id })
    None        = @()
}

# ------------------------------------------------------------------------------
#  Background worker (runs tasks in a separate runspace so the UI stays smooth)
# ------------------------------------------------------------------------------
$WorkerScript = {
    param($sync, $jobs, $title, $summary)
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    if (-not ('OPC.Native' -as [type])) { Add-Type -TypeDefinition $sync.NativeSrc }

    $logFile = $null
    try { $logFile = New-Object IO.StreamWriter($sync.LogPath, $false, (New-Object Text.UTF8Encoding($false))); $logFile.AutoFlush = $true } catch {}

    function Emit([string]$lvl, [string]$msg) {
        $sync.Queue.Enqueue(@($lvl, $msg))
        if ($lvl -eq 'warn' -or $lvl -eq 'err') { $sync.TaskWarn = $true }
        if ($logFile) { $logFile.WriteLine(('{0:HH:mm:ss}  {1,-4}  {2}' -f (Get-Date), $lvl.ToUpper(), $msg)) }
    }
    function Log([string]$m)  { Emit 'info' $m }
    function Ok([string]$m)   { Emit 'ok' $m }
    function Skip([string]$m) { Emit 'skip' $m }
    function Warn([string]$m) { Emit 'warn' $m }
    function Fail([string]$m) { Emit 'err' $m }
    function Sub([string]$m)  { $sync.Sub = $m }

    function Fmt-Size([double]$b) {
        if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
        if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
        if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
        return '{0:N0} B' -f $b
    }
    function Get-FolderBytes([string]$p) {
        try { $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum; if ($s) { return [double]$s } } catch {}
        return 0.0
    }
    function Clear-Folder([string]$Path, [string]$Label, [switch]$Silent) {
        $sync.LastFreed = 0.0
        if ([string]::IsNullOrWhiteSpace($Path)) { if (-not $Silent) { Skip "$Label location unknown" }; return }
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $blocked = @($env:SystemRoot, "$env:SystemRoot\System32", $env:USERPROFILE, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
        if ($full.Length -le 3 -or ($blocked -contains $full)) { Warn "Refused to clear protected folder $full"; return }
        if (-not (Test-Path -LiteralPath $full)) { if (-not $Silent) { Skip "$Label not found" }; return }
        $before = Get-FolderBytes $full
        Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after = Get-FolderBytes $full
        $freed = [math]::Max(0, $before - $after)
        $sync.LastFreed = $freed; $sync.Freed += $freed
        if (-not $Silent) { Ok ('{0}: freed {1}' -f $Label, (Fmt-Size $freed)) }
    }
    function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force -ErrorAction Stop }
            $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop
        } catch { Warn "Registry $Path\$Name failed: $($_.Exception.Message)" }
    }
    function Disable-Svc([string[]]$Names) {
        foreach ($n in $Names) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if (-not $s) { Skip "$n is not on this PC"; continue }
            if ($s.Status -ne 'Stopped') { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
            Set-Service -Name $n -StartupType Disabled -ErrorAction SilentlyContinue
            $mode = (Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue).StartMode
            if ($mode -ne 'Disabled') { $null = & sc.exe config $n start= disabled; $mode = (Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue).StartMode }
            if ($mode -eq 'Disabled') { Ok "Disabled $n ($($s.DisplayName))" } else { Warn "$n is protected by Windows and was left as is" }
        }
    }
    function Out-ExeLine([string]$l, [bool]$quiet) {
        $l = $l.Replace([string][char]0, '').Trim()
        if (-not $l) { return }
        if ($l -match '^\[[=\s-]*\d' -or $l -match '\d{1,3}(\.\d+)?\s*%') { $sync.Sub = $l; return }
        if (-not $quiet) { Log $l }
    }
    function Invoke-Exe([string]$File, [string]$Arguments, [switch]$Unicode, [switch]$Quiet) {
        $si = New-Object Diagnostics.ProcessStartInfo
        $si.FileName = $File; $si.Arguments = $Arguments
        $si.UseShellExecute = $false; $si.CreateNoWindow = $true
        $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
        if ($Unicode) { $si.StandardOutputEncoding = [Text.Encoding]::Unicode }
        else { try { $si.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch {} }
        $p = New-Object Diagnostics.Process
        $p.StartInfo = $si
        try { [void]$p.Start() } catch { Fail "Could not start $($File): $($_.Exception.Message)"; return -1 }
        $sync.Proc = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        $buf = New-Object char[] 2048
        $pending = ''
        while (($n = $p.StandardOutput.Read($buf, 0, $buf.Length)) -gt 0) {
            $pending += [string]::new($buf, 0, $n)
            $parts = $pending -split "[`r`n]"
            $pending = $parts[-1]
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { Out-ExeLine $parts[$i] $Quiet.IsPresent }
        }
        if ($pending) { Out-ExeLine $pending $Quiet.IsPresent }
        $p.WaitForExit()
        $err = ''; try { $err = $errTask.Result } catch {}
        if ($err -and -not $Quiet) { foreach ($l in ($err -split "`r?`n")) { if ($l.Trim()) { Skip $l.Trim() } } }
        $sync.Proc = $null
        return $p.ExitCode
    }

    $sync.Freed = 0.0
    $start = Get-Date
    Emit 'head' ('{0}  -  {1} step(s)' -f $title, @($jobs).Count)
    $i = 0
    foreach ($job in $jobs) {
        if ($sync.Cancel) { Warn 'Stopped. The remaining steps were skipped.'; break }
        $i++
        $sync.Index = $i; $sync.Current = $job.Name; $sync.Sub = ''; $sync.TaskWarn = $false
        $sync.Status[$job.Id] = 'run'
        Emit 'head' ('[{0}/{1}]  {2}' -f $i, @($jobs).Count, $job.Name)
        $errShown = 0
        try {
            $sb = [scriptblock]::Create($job.Code)
            & $sb 2>&1 | ForEach-Object {
                if ($_ -is [Management.Automation.ErrorRecord]) {
                    $errShown++
                    if ($errShown -le 3) { Skip $_.Exception.Message }
                } elseif ($null -ne $_) {
                    $txt = ("$_").Trim()
                    if ($txt) { Out-ExeLine $txt $false }
                }
            }
            if ($errShown -gt 3) { Skip "...and $($errShown - 3) more minor error(s)" }
            if ($sync.TaskWarn) { $sync.Status[$job.Id] = 'warn' } else { $sync.Status[$job.Id] = 'ok' }
            if ($job.Reboot) { $sync.NeedsReboot = $true }
        } catch {
            Fail $_.Exception.Message
            $sync.Status[$job.Id] = 'err'
        }
        $sync.Sub = ''
    }

    if ($summary) {
        Emit 'head' 'Summary'
        foreach ($d in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
            Log ('{0}  {1} free of {2}' -f $d.Name, (Fmt-Size $d.AvailableFreeSpace), (Fmt-Size $d.TotalSize))
        }
        $dur = (Get-Date) - $start
        $sync.Summary = ('Finished in {0:hh\:mm\:ss}. Space freed: {1}.' -f $dur, (Fmt-Size $sync.Freed))
        Ok $sync.Summary
        if ($sync.NeedsReboot) { Warn 'Restart Windows to finish applying some changes.' }
    }
    if ($logFile) { $logFile.Close() }
    $sync.Done = $true
}

# ------------------------------------------------------------------------------
#  UI (XAML)
# ------------------------------------------------------------------------------
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OPC V7" Width="1200" Height="780" MinWidth="1000" MinHeight="660"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0A0A0B" Foreground="#F4F4F5" FontSize="13"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True"
        BorderBrush="#26262B" BorderThickness="1">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#0A0A0B"/>
    <SolidColorBrush x:Key="PanelBrush" Color="#0F0F11"/>
    <SolidColorBrush x:Key="CardBrush" Color="#141417"/>
    <SolidColorBrush x:Key="CardHoverBrush" Color="#1A1A1E"/>
    <SolidColorBrush x:Key="LineBrush" Color="#26262B"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F4F4F5"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#A1A1AA"/>
    <SolidColorBrush x:Key="FaintBrush" Color="#63636B"/>
    <SolidColorBrush x:Key="SafeBrush" Color="#34D399"/>
    <SolidColorBrush x:Key="ModBrush" Color="#FBBF24"/>
    <SolidColorBrush x:Key="AdvBrush" Color="#F87171"/>
    <FontFamily x:Key="IconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas</FontFamily>
    <FontFamily x:Key="BrandFont">Arial Black</FontFamily>

    <!-- Scrollbars -->
    <Style TargetType="Thumb" x:Key="ScrollThumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="th" CornerRadius="3" Background="#34343B" Margin="2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="th" Property="Background" Value="#55555E"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="th" Property="Background" Value="#71717A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1C1C21"/>
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="BorderBrush" Value="#34343B"/>
      <Setter Property="Padding" Value="10,6"/>
    </Style>

    <!-- Buttons -->
    <Style x:Key="BaseButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Tag" Value="#1C1C21"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#1C1C21"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#F4F4F5"/>
      <Setter Property="Foreground" Value="#0A0A0B"/>
      <Setter Property="Padding" Value="20,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#D4D4D8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#141417"/>
      <Setter Property="BorderBrush" Value="#2E2E34"/>
    </Style>
    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Foreground" Value="#A1A1AA"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style x:Key="ChipButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#141417"/>
      <Setter Property="BorderBrush" Value="#2E2E34"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style x:Key="CaptionButton" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="Foreground" Value="#A1A1AA"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1F1F24"/>
                <Setter Property="Foreground" Value="#F4F4F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CloseButton" TargetType="Button" BasedOn="{StaticResource CaptionButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E81123"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TileButton" TargetType="Button">
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#141417" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="16,14">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1A1A1E"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#45454D"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Navigation -->
    <Style x:Key="NavButton" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#A1A1AA"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="Transparent" CornerRadius="8">
              <Grid>
                <Border x:Name="bar" Width="3" Height="18" CornerRadius="2" Background="#F4F4F5" HorizontalAlignment="Left" Visibility="Hidden"/>
                <StackPanel Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
                  <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource IconFont}" FontSize="16" Width="22" VerticalAlignment="Center"/>
                  <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#16161A"/>
                <Setter Property="Foreground" Value="#E4E4E7"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1C1C21"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#F4F4F5"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Task row: the whole card is the toggle -->
    <Style x:Key="TaskRow" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="card" Background="#141417" BorderBrush="#26262B" BorderThickness="1" CornerRadius="10" Padding="16,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="track" Width="38" Height="22" CornerRadius="11" Background="#202025" BorderBrush="#3A3A42" BorderThickness="1" VerticalAlignment="Center" Margin="0,0,16,0">
                  <Ellipse x:Name="knob" Width="14" Height="14" Fill="#8A8A93" HorizontalAlignment="Left" Margin="3,0,3,0"/>
                </Border>
                <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="card" Property="Background" Value="#19191D"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#F4F4F5"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#F4F4F5"/>
                <Setter TargetName="knob" Property="Fill" Value="#0A0A0B"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="card" Property="BorderBrush" Value="#4A4A52"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Small switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E4E4E7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="track" Width="34" Height="20" CornerRadius="10" Background="#202025" BorderBrush="#3A3A42" BorderThickness="1" VerticalAlignment="Center" Margin="0,0,12,0">
                <Ellipse x:Name="knob" Width="12" Height="12" Fill="#8A8A93" HorizontalAlignment="Left" Margin="3,0,3,0"/>
              </Border>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#F4F4F5"/>
                <Setter TargetName="track" Property="BorderBrush" Value="#F4F4F5"/>
                <Setter TargetName="knob" Property="Fill" Value="#0A0A0B"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#0F0F11"/>
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="BorderBrush" Value="#2E2E34"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="CaretBrush" Value="#F4F4F5"/>
      <Setter Property="SelectionBrush" Value="#60A5FA"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#45454D"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#F4F4F5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Thin" TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Foreground" Value="#F4F4F5"/>
      <Setter Property="Background" Value="#26262B"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="2"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="2" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#141417"/>
      <Setter Property="BorderBrush" Value="#26262B"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#63636B"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#F4F4F5"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="#A1A1AA"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#F4F4F5"/>
    </Style>
    <Style x:Key="LogItem" TargetType="ListBoxItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <ContentPresenter Margin="0,1"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid">
    <Grid.RowDefinitions>
      <RowDefinition Height="46"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="224"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Title bar -->
    <Border Grid.ColumnSpan="2" Background="#0A0A0B" BorderBrush="#1C1C21" BorderThickness="0,0,0,1">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
          <Border Width="28" Height="28" Background="#000000" BorderBrush="#F4F4F5" BorderThickness="2">
            <TextBlock Text="OPC" FontFamily="{StaticResource BrandFont}" FontSize="8.5" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="OPC V7" FontWeight="Bold" FontSize="13.5" Margin="12,0,0,0" VerticalAlignment="Center"/>
          <TextBlock Text="Optimal Performance Cleaner" Foreground="#63636B" FontSize="12.5" Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnMin" Style="{StaticResource CaptionButton}" Content="&#xE921;" ToolTip="Minimize"/>
          <Button x:Name="BtnMax" Style="{StaticResource CaptionButton}" Content="&#xE922;" ToolTip="Maximize"/>
          <Button x:Name="BtnClose" Style="{StaticResource CloseButton}" Content="&#xE8BB;" ToolTip="Close"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Sidebar -->
    <Border Grid.Row="1" Background="#0A0A0B" BorderBrush="#1C1C21" BorderThickness="0,0,1,0">
      <DockPanel Margin="0,14,0,14">
        <StackPanel DockPanel.Dock="Bottom" Margin="22,0,18,0">
          <Border x:Name="AdminPill" Background="#1234D399" BorderBrush="#4034D399" BorderThickness="1" CornerRadius="6" Padding="8,4" HorizontalAlignment="Left">
            <TextBlock x:Name="AdminText" Text="Administrator" FontSize="11" FontWeight="SemiBold" Foreground="#34D399"/>
          </Border>
          <TextBlock x:Name="VersionText" Text="Version 7.0.0" Foreground="#63636B" FontSize="11.5" Margin="0,10,0,0"/>
          <TextBlock Text="by Bradley Williams" Foreground="#63636B" FontSize="11.5" Margin="0,2,0,0"/>
        </StackPanel>
        <StackPanel>
          <TextBlock Text="MENU" Style="{StaticResource Label}" Margin="26,4,0,8"/>
          <RadioButton x:Name="NavOverview" Style="{StaticResource NavButton}" Tag="&#xE80F;" Content="Overview" IsChecked="True"/>
          <RadioButton x:Name="NavOptimizer" Style="{StaticResource NavButton}" Tag="&#xE945;" Content="Optimizer"/>
          <RadioButton x:Name="NavRdp" Style="{StaticResource NavButton}" Tag="&#xE7F4;" Content="Remote Desktop"/>
          <RadioButton x:Name="NavAbout" Style="{StaticResource NavButton}" Tag="&#xE946;" Content="About"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Pages -->
    <Grid Grid.Row="1" Grid.Column="1" Background="#0C0C0E">

      <!-- OVERVIEW -->
      <ScrollViewer x:Name="PageOverview" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="36,30,36,32" MaxWidth="1200">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Width="118" Height="118" Background="#000000" BorderBrush="#F4F4F5" BorderThickness="3" Padding="4">
              <Border BorderBrush="#F4F4F5" BorderThickness="1.5">
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="OPC" FontFamily="{StaticResource BrandFont}" FontSize="31" Foreground="#FFFFFF" HorizontalAlignment="Center"/>
                  <Border Height="3" Background="#FFFFFF" Margin="12,1,12,3"/>
                  <TextBlock Text="V7" FontFamily="{StaticResource BrandFont}" FontSize="24" Foreground="#FFFFFF" HorizontalAlignment="Center"/>
                  <Border Height="3" Background="#FFFFFF" Margin="12,3,12,0"/>
                </StackPanel>
              </Border>
            </Border>
            <StackPanel Grid.Column="1" Margin="26,4,0,0" VerticalAlignment="Center">
              <TextBlock Text="O P T I M A L    P E R F O R M A N C E" Style="{StaticResource Label}" FontSize="11.5"/>
              <TextBlock x:Name="GreetText" Text="Your PC at a glance" FontSize="30" FontWeight="Bold" Margin="0,6,0,0"/>
              <TextBlock x:Name="SysLine" Text="" Style="{StaticResource Sub}" Margin="0,6,0,0"/>
              <TextBlock x:Name="LastRunText" Text="" Foreground="#63636B" FontSize="12.5" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>

          <UniformGrid Columns="4" Margin="-6,26,-6,0">
            <Border Style="{StaticResource Card}" Margin="6">
              <StackPanel>
                <TextBlock Text="CPU" Style="{StaticResource Label}"/>
                <TextBlock x:Name="CpuValue" Text="--" FontSize="28" FontWeight="Bold" Margin="0,8,0,0"/>
                <TextBlock x:Name="CpuSub" Text="" Foreground="#63636B" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,2,0,12"/>
                <ProgressBar x:Name="CpuBar" Style="{StaticResource Thin}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6">
              <StackPanel>
                <TextBlock Text="MEMORY IN USE" Style="{StaticResource Label}"/>
                <TextBlock x:Name="MemValue" Text="--" FontSize="28" FontWeight="Bold" Margin="0,8,0,0"/>
                <TextBlock x:Name="MemSub" Text="" Foreground="#63636B" FontSize="12" Margin="0,2,0,12"/>
                <ProgressBar x:Name="MemBar" Style="{StaticResource Thin}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6">
              <StackPanel>
                <TextBlock Text="SYSTEM DRIVE FREE" Style="{StaticResource Label}"/>
                <TextBlock x:Name="DiskValue" Text="--" FontSize="28" FontWeight="Bold" Margin="0,8,0,0"/>
                <TextBlock x:Name="DiskSub" Text="" Foreground="#63636B" FontSize="12" Margin="0,2,0,12"/>
                <ProgressBar x:Name="DiskBar" Style="{StaticResource Thin}"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="6">
              <StackPanel>
                <TextBlock Text="UPTIME" Style="{StaticResource Label}"/>
                <TextBlock x:Name="UpValue" Text="--" FontSize="28" FontWeight="Bold" Margin="0,8,0,0"/>
                <TextBlock x:Name="UpSub" Text="" Foreground="#63636B" FontSize="12" Margin="0,2,0,12"/>
                <ProgressBar Style="{StaticResource Thin}" Value="0" Background="Transparent"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <Grid Margin="0,16,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="3*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Quick actions" Style="{StaticResource CardTitle}"/>
                <TextBlock Text="One click. Everything is logged and shown in the console below." Foreground="#63636B" FontSize="12.5" Margin="0,4,0,14"/>
                <UniformGrid Columns="2">
                  <Button x:Name="TileQuick" Style="{StaticResource TileButton}" Margin="0,0,6,10">
                    <StackPanel>
                      <TextBlock Text="&#xE945;" FontFamily="{StaticResource IconFont}" FontSize="18"/>
                      <TextBlock Text="Quick clean" FontWeight="SemiBold" FontSize="14" Margin="0,10,0,0"/>
                      <TextBlock Text="Safe steps only. Under a minute. Runs right away." Foreground="#A1A1AA" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="TileRecommended" Style="{StaticResource TileButton}" Margin="6,0,0,10">
                    <StackPanel>
                      <TextBlock Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="18"/>
                      <TextBlock Text="Recommended tune-up" FontWeight="SemiBold" FontSize="14" Margin="0,10,0,0"/>
                      <TextBlock Text="Restore point, deep clean, repairs and privacy. Review then run." Foreground="#A1A1AA" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="TileV6" Style="{StaticResource TileButton}" Margin="0,0,6,0">
                    <StackPanel>
                      <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource IconFont}" FontSize="18"/>
                      <TextBlock Text="Full OPC V6 run" FontWeight="SemiBold" FontSize="14" Margin="0,10,0,0"/>
                      <TextBlock Text="Every V6 section, fixed and with a restore point. Review then run." Foreground="#A1A1AA" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="TileRestore" Style="{StaticResource TileButton}" Margin="6,0,0,0">
                    <StackPanel>
                      <TextBlock Text="&#xE777;" FontFamily="{StaticResource IconFont}" FontSize="18"/>
                      <TextBlock Text="System Restore" FontWeight="SemiBold" FontSize="14" Margin="0,10,0,0"/>
                      <TextBlock Text="Undo changes by going back to an earlier restore point." Foreground="#A1A1AA" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                  </Button>
                </UniformGrid>
              </StackPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Drives" Style="{StaticResource CardTitle}"/>
                <StackPanel x:Name="DrivesPanel" Margin="0,14,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
        </StackPanel>
      </ScrollViewer>

      <!-- OPTIMIZER -->
      <Grid x:Name="PageOptimizer" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Margin="36,30,36,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="Optimizer" Style="{StaticResource H1}"/>
            <TextBlock Text="Pick a preset or switch steps on one by one. Steps run top to bottom." Style="{StaticResource Sub}" Margin="0,4,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="SelCount" Text="0 selected" Foreground="#A1A1AA" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <Button x:Name="BtnRun" Style="{StaticResource PrimaryButton}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE768;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="Run selected" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="36,20,36,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <WrapPanel>
            <Button x:Name="PresetQuick" Style="{StaticResource ChipButton}" Content="Quick clean" Margin="0,0,8,6"/>
            <Button x:Name="PresetRecommended" Style="{StaticResource ChipButton}" Content="Recommended" Margin="0,0,8,6"/>
            <Button x:Name="PresetOptiCore" Style="{StaticResource ChipButton}" Content="OptiCore v2 classic" Margin="0,0,8,6"/>
            <Button x:Name="PresetV6" Style="{StaticResource ChipButton}" Content="Full OPC V6" Margin="0,0,8,6"/>
            <Button x:Name="PresetNone" Style="{StaticResource ChipButton}" Content="Clear" Margin="0,0,8,6"/>
          </WrapPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse Width="8" Height="8" Fill="#34D399" VerticalAlignment="Center"/>
            <TextBlock Text="Safe" Foreground="#A1A1AA" FontSize="12" Margin="6,0,14,0" VerticalAlignment="Center"/>
            <Ellipse Width="8" Height="8" Fill="#FBBF24" VerticalAlignment="Center"/>
            <TextBlock Text="Moderate" Foreground="#A1A1AA" FontSize="12" Margin="6,0,14,0" VerticalAlignment="Center"/>
            <Ellipse Width="8" Height="8" Fill="#F87171" VerticalAlignment="Center"/>
            <TextBlock Text="Advanced" Foreground="#A1A1AA" FontSize="12" Margin="6,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="TaskPanel" Margin="36,4,30,28"/>
        </ScrollViewer>
      </Grid>

      <!-- REMOTE DESKTOP -->
      <ScrollViewer x:Name="PageRdp" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="36,30,36,32">
          <TextBlock Text="Remote Desktop" Style="{StaticResource H1}"/>
          <TextBlock Text="The RDP Toolkit, both sides in one place. Host this PC, or connect to another one." Style="{StaticResource Sub}" Margin="0,4,0,0"/>
          <Grid Margin="0,22,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <Grid>
                  <StackPanel>
                    <TextBlock Text="THIS PC (SERVER)" Style="{StaticResource Label}"/>
                    <TextBlock Text="Let others connect here" Style="{StaticResource CardTitle}" Margin="0,6,0,0"/>
                  </StackPanel>
                  <Button x:Name="BtnRdpRefresh" Style="{StaticResource GhostButton}" HorizontalAlignment="Right" VerticalAlignment="Top" ToolTip="Refresh status">
                    <TextBlock Text="&#xE72C;" FontFamily="{StaticResource IconFont}" FontSize="14"/>
                  </Button>
                </Grid>
                <Border x:Name="RdpHomeWarn" Visibility="Collapsed" Background="#14F87171" BorderBrush="#40F87171" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,14,0,0">
                  <TextBlock Text="This is a Windows Home edition. Home can connect to other PCs but cannot host Remote Desktop. Upgrade to Pro, or use a remote support tool instead." TextWrapping="Wrap" Foreground="#FCA5A5" FontSize="12.5"/>
                </Border>
                <Grid Margin="0,16,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="30"/>
                    <RowDefinition Height="30"/>
                    <RowDefinition Height="30"/>
                    <RowDefinition Height="30"/>
                    <RowDefinition Height="30"/>
                  </Grid.RowDefinitions>
                  <Ellipse x:Name="DotRdp" Width="8" Height="8" Fill="#63636B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock x:Name="TxtRdp" Grid.Column="1" Text="Remote Desktop: checking..." VerticalAlignment="Center"/>
                  <Ellipse x:Name="DotNla" Grid.Row="1" Width="8" Height="8" Fill="#63636B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock x:Name="TxtNla" Grid.Row="1" Grid.Column="1" Text="Network Level Authentication" VerticalAlignment="Center"/>
                  <Ellipse x:Name="DotFw" Grid.Row="2" Width="8" Height="8" Fill="#63636B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock x:Name="TxtFw" Grid.Row="2" Grid.Column="1" Text="Firewall rule" VerticalAlignment="Center"/>
                  <Ellipse x:Name="DotSvc" Grid.Row="3" Width="8" Height="8" Fill="#63636B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock x:Name="TxtSvc" Grid.Row="3" Grid.Column="1" Text="Remote Desktop service" VerticalAlignment="Center"/>
                  <Ellipse Grid.Row="4" Width="8" Height="8" Fill="#63636B" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <TextBlock x:Name="TxtPort" Grid.Row="4" Grid.Column="1" Text="Port" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock Text="ADDRESSES TO CONNECT TO" Style="{StaticResource Label}" Margin="0,16,0,6"/>
                <TextBox x:Name="TxtIps" Style="{StaticResource Input}" IsReadOnly="True" FontFamily="{StaticResource MonoFont}" FontSize="12.5" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="40"/>
                <WrapPanel Margin="0,16,0,0">
                  <Button x:Name="BtnRdpEnable" Style="{StaticResource PrimaryButton}" Content="Enable Remote Desktop" Margin="0,0,8,8"/>
                  <Button x:Name="BtnRdpDisable" Style="{StaticResource SecondaryButton}" Content="Disable" Margin="0,0,8,8"/>
                  <Button x:Name="BtnRdpSettings" Style="{StaticResource SecondaryButton}" Content="System settings" Margin="0,0,8,8"/>
                </WrapPanel>
                <TextBlock Text="Enable turns on RDP, Network Level Authentication and the firewall rule in one go. The account you sign in with must have a password." Foreground="#63636B" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="ANOTHER PC (CLIENT)" Style="{StaticResource Label}"/>
                <TextBlock Text="Connect to a remote PC" Style="{StaticResource CardTitle}" Margin="0,6,0,16"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="90"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="IP ADDRESS OR HOSTNAME" Style="{StaticResource Label}" Margin="0,0,0,6"/>
                    <TextBox x:Name="TxtHost" Style="{StaticResource Input}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="PORT" Style="{StaticResource Label}" Margin="0,0,0,6"/>
                    <TextBox x:Name="TxtPortIn" Style="{StaticResource Input}" Text="3389"/>
                  </StackPanel>
                </Grid>
                <WrapPanel x:Name="RecentPanel" Margin="0,10,0,0"/>
                <StackPanel Margin="0,12,0,0">
                  <CheckBox x:Name="ChkFull" Style="{StaticResource Switch}" Content="Full screen"/>
                  <CheckBox x:Name="ChkMulti" Style="{StaticResource Switch}" Content="Use all my monitors"/>
                  <CheckBox x:Name="ChkAdmin" Style="{StaticResource Switch}" Content="Admin session (/admin)"/>
                </StackPanel>
                <WrapPanel Margin="0,8,0,0">
                  <Button x:Name="BtnConnect" Style="{StaticResource PrimaryButton}" Margin="0,0,8,8">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE7F4;" FontFamily="{StaticResource IconFont}" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/>
                      <TextBlock Text="Connect" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="BtnTestPort" Style="{StaticResource SecondaryButton}" Content="Test port" Margin="0,0,8,8"/>
                </WrapPanel>
                <TextBlock x:Name="ClientMsg" Text="" FontSize="12.5" Foreground="#A1A1AA" TextWrapping="Wrap" Margin="0,2,0,0"/>
                <Border Background="#0F0F11" BorderBrush="#26262B" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,16,0,0">
                  <StackPanel>
                    <TextBlock Text="Connecting over the internet" FontWeight="SemiBold" FontSize="12.5"/>
                    <TextBlock TextWrapping="Wrap" Foreground="#A1A1AA" FontSize="12" Margin="0,4,0,0"
                               Text="Use a VPN (or something like Tailscale) and connect to the private address. Port forwarding 3389 straight to the internet gets brute-forced within hours. If you must forward, keep NLA on, use a long password and a non-default external port."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
          </Grid>
        </StackPanel>
      </ScrollViewer>

      <!-- ABOUT -->
      <ScrollViewer x:Name="PageAbout" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="36,30,36,32" MaxWidth="860" HorizontalAlignment="Left">
          <TextBlock Text="About OPC V7" Style="{StaticResource H1}"/>
          <TextBlock Text="Three tools, one app. Built on what Windows already ships, so there is nothing to install." Style="{StaticResource Sub}" Margin="0,4,0,20"/>
          <Border Style="{StaticResource Card}" Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="What is inside" Style="{StaticResource CardTitle}"/>
              <TextBlock TextWrapping="Wrap" Foreground="#A1A1AA" Margin="0,8,0,0" LineHeight="20">
                <Run Text="OptiCore v2" FontWeight="SemiBold" Foreground="#F4F4F5"/><Run Text="  background app sweep, temp cleanup and the safe service list. Preset: OptiCore v2 classic."/>
                <LineBreak/>
                <Run Text="OPC V6" FontWeight="SemiBold" Foreground="#F4F4F5"/><Run Text="  all 20 sections, split into individual steps you can switch on and off. Preset: Full OPC V6."/>
                <LineBreak/>
                <Run Text="RDP Toolkit" FontWeight="SemiBold" Foreground="#F4F4F5"/><Run Text="  server and client side on the Remote Desktop page."/>
              </TextBlock>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="Fixed while porting V6" Style="{StaticResource CardTitle}"/>
              <TextBlock TextWrapping="Wrap" Foreground="#A1A1AA" Margin="0,8,0,0" LineHeight="20"
                         Text="Real restore point before changes (the V6 readme promised one, the script never made it). Standby memory purge now uses the right command and privilege. Telemetry scheduled tasks actually disable. Windows Update pause sets every key Settings uses. Ultimate Performance is created once instead of on every run. Registry tweaks create missing keys instead of failing silently. Execution policy is no longer changed machine-wide. Firewall reset, IP release, Windows.old removal and event log clearing are opt-in Advanced steps instead of always-on."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}" Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="Logs and data" Style="{StaticResource CardTitle}"/>
              <TextBlock x:Name="AboutPaths" TextWrapping="Wrap" Foreground="#A1A1AA" Margin="0,8,0,12" FontFamily="{StaticResource MonoFont}" FontSize="12"/>
              <WrapPanel>
                <Button x:Name="BtnAboutLogs" Style="{StaticResource SecondaryButton}" Content="Open logs folder" Margin="0,0,8,0"/>
                <Button x:Name="BtnAboutRestore" Style="{StaticResource SecondaryButton}" Content="Open System Restore"/>
              </WrapPanel>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="License" Style="{StaticResource CardTitle}"/>
              <TextBlock TextWrapping="Wrap" Foreground="#A1A1AA" Margin="0,8,0,0" LineHeight="20"
                         Text="Perpetual Free License. Free to use, share and distribute, forever. Provided as is, without warranty. Copyright (c) Bradley Williams."/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <!-- Console -->
    <Border Grid.Row="2" Grid.ColumnSpan="2" Background="#0A0A0B" BorderBrush="#1C1C21" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="52"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Margin="20,0,12,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Ellipse x:Name="RunDot" Width="8" Height="8" Fill="#34D399" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <TextBlock x:Name="RunTitle" Text="Ready" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="RunSub" Text="Nothing running" Foreground="#63636B" FontSize="12" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <ProgressBar x:Name="RunProgress" Grid.Column="2" Style="{StaticResource Thin}" Width="220" VerticalAlignment="Center" Margin="16,0,16,0"/>
          <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnStop" Style="{StaticResource SecondaryButton}" Content="Stop" Padding="14,6" Margin="0,0,8,0" Visibility="Collapsed"/>
            <Button x:Name="BtnCopyLog" Style="{StaticResource GhostButton}" ToolTip="Copy log">
              <TextBlock Text="&#xE8C8;" FontFamily="{StaticResource IconFont}" FontSize="14"/>
            </Button>
            <Button x:Name="BtnOpenLogs" Style="{StaticResource GhostButton}" ToolTip="Open logs folder">
              <TextBlock Text="&#xE838;" FontFamily="{StaticResource IconFont}" FontSize="14"/>
            </Button>
            <Button x:Name="BtnConsole" Style="{StaticResource GhostButton}" ToolTip="Show or hide console">
              <TextBlock x:Name="ConsoleGlyph" Text="&#xE70E;" FontFamily="{StaticResource IconFont}" FontSize="14"/>
            </Button>
          </StackPanel>
        </Grid>
        <Border x:Name="LogHost" Grid.Row="1" Height="230" Visibility="Collapsed" Background="#08080A" BorderBrush="#1C1C21" BorderThickness="0,1,0,0">
          <ListBox x:Name="LogList" Background="Transparent" BorderThickness="0" Padding="16,8,8,8"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"
                   ItemContainerStyle="{StaticResource LogItem}">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="70"/>
                    <ColumnDefinition Width="20"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="{Binding Time}" Foreground="#4A4A52" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                  <TextBlock Grid.Column="1" Text="{Binding Glyph}" Foreground="{Binding Brush}" FontSize="12"/>
                  <TextBlock Grid.Column="2" Text="{Binding Text}" Foreground="{Binding Brush}" FontWeight="{Binding Weight}" FontFamily="Cascadia Mono, Consolas" FontSize="12" TextWrapping="Wrap"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </Border>
      </Grid>
    </Border>

    <!-- Dialog overlay -->
    <Grid x:Name="DlgOverlay" Grid.Row="1" Grid.RowSpan="2" Grid.ColumnSpan="2" Background="#B3000000" Visibility="Collapsed" Panel.ZIndex="50">
      <Border Width="480" Background="#141417" BorderBrush="#34343B" BorderThickness="1" CornerRadius="14" Padding="26,24" HorizontalAlignment="Center" VerticalAlignment="Center">
        <StackPanel>
          <TextBlock x:Name="DlgTitle" Text="" FontSize="18" FontWeight="Bold"/>
          <TextBlock x:Name="DlgBody" Text="" Foreground="#A1A1AA" TextWrapping="Wrap" Margin="0,10,0,22" LineHeight="20"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgSecondary" Style="{StaticResource SecondaryButton}" Content="Cancel" Margin="0,0,8,0"/>
            <Button x:Name="DlgPrimary" Style="{StaticResource PrimaryButton}" Content="OK"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ------------------------------------------------------------------------------
#  Build window
# ------------------------------------------------------------------------------
try {
    $reader = New-Object System.Xml.XmlNodeReader $Xaml
    $Window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    $msg = $_.Exception.Message; if ($_.Exception.InnerException) { $msg += "`n" + $_.Exception.InnerException.Message }
    try { $msg | Set-Content -Path (Join-Path $DataDir 'startup-error.txt') } catch {}
    [void][Windows.MessageBox]::Show("OPC V7 could not start the interface.`n`n$msg", 'OPC V7', 'OK', 'Error')
    exit 1
}

$ui = @{}
foreach ($node in $Xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $n = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($n) { $el = $Window.FindName($n); if ($el) { $ui[$n] = $el } }
}

function New-Brush([string]$hex) { $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($hex); $b.Freeze(); return $b }
$Br = @{
    Text = New-Brush '#F4F4F5'; Muted = New-Brush '#A1A1AA'; Faint = New-Brush '#63636B'
    Safe = New-Brush '#34D399'; Mod = New-Brush '#FBBF24'; Adv = New-Brush '#F87171'; Info = New-Brush '#60A5FA'
    Head = New-Brush '#FFFFFF'
}
$IconFont = New-Object Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
$TextFont = New-Object Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
function Glyph([int]$code) { return [string][char]$code }

# Window icon from embedded PNG
$LogoB64 = 'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAAJ90lEQVR42u1caUhUXxQ/My6pldu4YKYmNob2qWxKKkUSk0qLShILWmiT0mijwoiINFo+CBWEELSRWEGSBhIq5pLLuFuZW2BaLs24m47avPP/8i/mzX3OvDeOY1P3wAU9755z77u/uefdc889VwQACJTmjMR0CCgA/zRZav6DSK2RKUgkEtEZQE0QJdIETTdNKM2cpjPvdAb8qTOAfpiN/8E1CABqjoxvdqgJoqsgShQACgAlCgAFgJKlMZU5ODjAtm3bICwsDIKCgsDV1RUkEglMTExAX18fdHZ2QlFREeTm5kJhYSEvnVVVVRAUFKS3HsMwMDQ0BN3d3VBZWQmvXr2CrKwsUKvVvPvv5+cH0dHREBoaCoGBgSCRSMDR0RFUKhUMDg5CS0sLVFZWQmZmJlRUVBhvufqraJImT7MOV7Gzs8Pk5GQcHBxEvlRdXY2bN2/Wq7uqqgoNpebmZgwODtbbhq+vL6anp+PPnz956y4rK8M1a9bo1Ks9jtpj+3+ZGQB+fn7Y0NBg8CDdvHkTLSwsZgUARMTx8XEMDQ2dVn9ERAT29fUZpHtqagqPHj06IwBEoBGS1PTcfnm/iDitJ+zh4QFVVVWwaNEiTi/w8+fP0NPTA7a2trBkyRKQSCScetLS0iA+Pp6XCWIYBrKzs4l6tra2EBAQAF5eXsSzrq4ukEqlMDY2xuLLZDIoKSkBa2trQkatVkNLSwsolUpwcnICb29vsLe353zPmJgYePnyJeczzXGcbmfBoBkgFouxtLSU8xd39epV9PDwIOqHhIRgUVER56/pwIEDvGaASqXSOSMjIyNRoVAQ+uPj41n1FixYgF++fCHqKZVKTExMREdHR6L/mzZtwry8PELm+/fv6ODgYFoTFBsbS3RkaGgI161bp3OAxGIx3r9/n5Dt7e1FW1vbGQMAALhz505Cf2ZmJqvO6dOniTpfv35FqVSqV39KSgohe/LkSdMCUFNTQ3Ri3759ejsPAGhlZYXV1dWEfGJiolEAsLa2xsnJSZZcfX09q057ezvRfkREBK/+i0QiLCgowNzcXExKSsLg4GDO79isAeDp6cm54hCJRLxeAABwy5YthI7c3FyjAAAAxIe1tbX19zN/f3+ibblczrvvfAsfAAxyxMLCwgheRkaGoNhBTk4ODAwMsHjr1q3j/CAKpfnz54ODgwOL9+3bt99/r1+/npDJzMw0H09YKpUSPLlcLkgHwzBQWVlJrGQWL14845eKjY0FCwsLFu/Tp0+///b19SVkampqzAcAruVkd3e3YD1dXV0Ez8XFZUYvFBUVBampqQT/0aNHv/92cnIinvf29prPVsSCBQsI3o8fPwTr4ZJZuHChThkrKyvIyMgg+DY2NrB8+XJYunQp8Sw/Px/Ky8tZJkqbxsfHzQeAoaEhgsflpOgjLhl9QIrFYoiNjeXdRmdnJ8TFxbF4w8PDvH5Uf6wJ6uvrI3g+Pj6C9Xh6ehrFlOn60MtkMlAoFHr7z9WXPxaAjx8/Ery1a9cK0mFhYUHsco6MjEBHR4fBAXCFQgF1dXVw7949CAkJgc2bN3Pa9qamJoK3evXqOduSFuwHSCQSZBiGVb+7uxutrKx4r5Gjo6P1eqsz8QN0FXd3d04/RoiOU6dOYW5uLu7Zs4fTg591T7igoIB4iXPnzvHqvKWlJecu565du0wCAABgRUUF0f7u3bt5yUokEtZ+09DQEF67ds20AERGRhIvMDExgVFRUXr3gtLS0gjZtrY2tLS0NBkAMTExRB8GBgZw1apVemMf+fn5hOzZs2dNHw94/fo15x55amoqenl5EQO/fv16fPv2LeduaGRkpFF2Q/kWsViMJSUlRD9GR0fx0qVL6ObmRuz/REZG4vv37wmZpqYmTjM06wA4OjpiW1vbtAGL1tZWLC4uRrlcjkqlctp6ly9f5h2QMRYAAICLFi3Cnp4ezj4xDIPNzc1YXFyMZWVl2N/fz1lvZGQEV65cOXcRMQ8PDywvLzcooqRWq/HChQuCQpLGBAAAUCqVYmNjo0H9VyqVOqNtJgEAAHDevHl48eJFnb9ybSouLkaZTCY4JmxsAAAAFy5ciDdu3MDh4WFefWcYBl+8eIGLFy+e8W7ojEKSXN7k1q1bITw8HGQyGbi6uoKzszMwDAP9/f3Q3NwM7969g8zMTN6bX9ohyYmJCbCxsZmV9bizszPrVIeLiws4OTmBWq2G/v5+aGxshKKiInj+/Dm0tLTw8k30hSSNCgAl4QDQg1lAT8ZRACiB+R5NpClMM8sgojOAmiBqguZs+lGiM4ACQAGg9O8AcPfuXUBEVrly5YogHXK5nNARHh4OAADXr18nngkpCQkJfzcADx8+JHgxMTG85b29vUEmk4H2sZOCggI6A4DnzuaHDx9YvMDAQAgICOAlv3PnToL3+PFjYBiGJunxpUePHsGtW7eIgU1OTjYIAM0jhz09PZxHZqajwMBA1jJapVKBWRxLgRkeCZmammK1VVdXp1fOw8MD1Wo1S66kpMTgfhw8eJClq729HefPn2/y4+kmBwAAMDs7m4gyLV26VKfM8ePHCZlDhw4Z1L6vry8R/dq0adOc5AfMCQBcKUTnz5/XKaN9DmlsbAzt7e0Fty0SibCwsJClKyMjw+jv+EcDYG1tTcSPKysrp63v6upK5PA+ffrUoLYTEhKIs0Du7u7/FgAAgHfu3CFmgY+PD2fdw4cPG5zPpVl8fHxwdHSUpUdXnu9fDUBQUBAxqGfOnOGs++bNG1a9jo4OFIvFgtvUPkhWX1+vM0n8rwYAAIgM+9LSUqKOk5MTkfGYkpIiuK3t27cTgG/YsGHW3s0sANDO1WUYBj09PVl19u/fTwycv7+/4G+O9gm+goKCWR18swDAzc2N8AlOnDihc8nKNUv0Fa5vyGz/+s0CAADArKwsVruFhYW/n9nb26NKpWI9P3LkiOBDuM3NzSwdtbW1sz74ZgPAjh07iPOiv5aFcXFxxNqf604Gobb/2LFjFADQuLZA+3KNXx5ueno6i5+enj5jr3tycpK4iOOfBgAA8Pbt20SqklgsJpy1jRs3CtLr6OiIExMTLB15eXkmGXyzAmDFihXErSshISHETSZC1/579+7ldavJXALwR4Qka2troaGhATTzh5OSklh1njx5InjfnytzUzNh+0+hOZ8B8H/WoS5atmyZYJ3aV+owDGP0Lee/wgT92nDT9ng1L8gzROf4+DixhWGqwTcrEwQAoFAoICcnh3csWR/Z2dkRiRza1+PQYyla9ODBA4KnUqng2bNngnVx3YjCdUfEXBPNkKEZMkAPZlGiAAA9nk4zZGiGDDVBlGiGDJ0BlCgAFABKFAAKACUKAF2GUm937gGg63xqgv7NGUDNDp0BFABKYNqYMCU6AygAlExL/wGTe88g9LOKTAAAAABJRU5ErkJggg=='
try {
    $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String($LogoB64))
    $bmp = New-Object Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit(); $bmp.StreamSource = $ms; $bmp.CacheOption = 'OnLoad'; $bmp.EndInit(); $bmp.Freeze()
    $Window.Icon = $bmp
} catch {}

# ------------------------------------------------------------------------------
#  Window chrome behaviour
# ------------------------------------------------------------------------------
$Window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($Window)).Handle
        $v = 2; [void][OPC.Native]::DwmSetWindowAttribute($hwnd, 33, [ref]$v, 4)   # Windows 11 rounded corners
    } catch {}
})
$ui.BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ if ($Window.WindowState -eq 'Maximized') { $Window.WindowState = 'Normal' } else { $Window.WindowState = 'Maximized' } })
$ui.BtnClose.Add_Click({ $Window.Close() })
$Window.Add_StateChanged({
    if ($Window.WindowState -eq 'Maximized') { $ui.RootGrid.Margin = New-Object Windows.Thickness(7); $ui.BtnMax.Content = Glyph 0xE923 }
    else { $ui.RootGrid.Margin = New-Object Windows.Thickness(0); $ui.BtnMax.Content = Glyph 0xE922 }
})

# ------------------------------------------------------------------------------
#  Navigation
# ------------------------------------------------------------------------------
$Pages = @{ NavOverview = 'PageOverview'; NavOptimizer = 'PageOptimizer'; NavRdp = 'PageRdp'; NavAbout = 'PageAbout' }
function Show-Page([string]$nav) {
    foreach ($k in $Pages.Keys) {
        if ($k -eq $nav) { $ui[$Pages[$k]].Visibility = 'Visible' } else { $ui[$Pages[$k]].Visibility = 'Collapsed' }
    }
    if ($nav -eq 'NavRdp' -and -not $script:RdpLoaded) { $script:RdpLoaded = $true; Update-RdpState }
}
foreach ($k in $Pages.Keys) {
    $ui[$k].Add_Checked({ param($s, $e) Show-Page $s.Name })
}
function Go([string]$nav) { $ui[$nav].IsChecked = $true }

# ------------------------------------------------------------------------------
#  Dialog
# ------------------------------------------------------------------------------
$script:DlgAction = $null
function Show-Dialog([string]$Title, [string]$Body, [string]$Primary, [string]$Secondary, [scriptblock]$OnPrimary) {
    $ui.DlgTitle.Text = $Title; $ui.DlgBody.Text = $Body; $ui.DlgPrimary.Content = $Primary
    if ($Secondary) { $ui.DlgSecondary.Content = $Secondary; $ui.DlgSecondary.Visibility = 'Visible' } else { $ui.DlgSecondary.Visibility = 'Collapsed' }
    $script:DlgAction = $OnPrimary
    $ui.DlgOverlay.Visibility = 'Visible'
}
$ui.DlgPrimary.Add_Click({ $ui.DlgOverlay.Visibility = 'Collapsed'; $a = $script:DlgAction; $script:DlgAction = $null; if ($a) { & $a } })
$ui.DlgSecondary.Add_Click({ $ui.DlgOverlay.Visibility = 'Collapsed'; $script:DlgAction = $null })

# ------------------------------------------------------------------------------
#  Console
# ------------------------------------------------------------------------------
$LogItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.LogList.ItemsSource = $LogItems
$LevelStyle = @{
    info = @($Br.Muted, '');                 ok   = @($Br.Safe, (Glyph 0x2713))
    skip = @($Br.Faint, (Glyph 0x2013));     warn = @($Br.Mod, '!')
    err  = @($Br.Adv, (Glyph 0x2715));      head = @($Br.Head, (Glyph 0x25A0))
}
function Add-LogLine([string]$lvl, [string]$text) {
    $st = $LevelStyle[$lvl]; if (-not $st) { $st = $LevelStyle.info }
    $w = [Windows.FontWeights]::Normal; if ($lvl -eq 'head') { $w = [Windows.FontWeights]::SemiBold }
    $LogItems.Add([pscustomobject]@{ Time = (Get-Date).ToString('HH:mm:ss'); Glyph = $st[1]; Text = $text; Brush = $st[0]; Weight = $w })
    while ($LogItems.Count -gt 4000) { $LogItems.RemoveAt(0) }
}
function Set-Console([bool]$open) {
    if ($open) { $ui.LogHost.Visibility = 'Visible'; $ui.ConsoleGlyph.Text = Glyph 0xE70D }
    else { $ui.LogHost.Visibility = 'Collapsed'; $ui.ConsoleGlyph.Text = Glyph 0xE70E }
}
$ui.BtnConsole.Add_Click({ Set-Console ($ui.LogHost.Visibility -ne 'Visible') })
$ui.BtnOpenLogs.Add_Click({ Start-Process explorer.exe $LogDir })
$ui.BtnAboutLogs.Add_Click({ Start-Process explorer.exe $LogDir })
$ui.BtnCopyLog.Add_Click({
    $txt = ($LogItems | ForEach-Object { '{0}  {1} {2}' -f $_.Time, $_.Glyph, $_.Text }) -join "`r`n"
    if ($txt) { [Windows.Clipboard]::SetText($txt); $ui.RunSub.Text = 'Log copied to clipboard' }
})

# ------------------------------------------------------------------------------
#  Task list
# ------------------------------------------------------------------------------
$Rows = @{}
$RiskBrush = @{ Safe = $Br.Safe; Moderate = $Br.Mod; Advanced = $Br.Adv }

function New-Badge([string]$text, $brush) {
    $c = $brush.Color
    $bd = New-Object Windows.Controls.Border
    $bd.CornerRadius = New-Object Windows.CornerRadius(5)
    $bd.Padding = New-Object Windows.Thickness(7, 2, 7, 3)
    $bd.Margin = New-Object Windows.Thickness(6, 0, 0, 0)
    $bd.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(28, $c.R, $c.G, $c.B))
    $bd.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(70, $c.R, $c.G, $c.B))
    $bd.BorderThickness = New-Object Windows.Thickness(1)
    $bd.VerticalAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text.ToUpper(); $tb.FontSize = 10; $tb.FontWeight = [Windows.FontWeights]::SemiBold; $tb.Foreground = $brush
    $bd.Child = $tb
    return $bd
}

function Update-SelCount {
    $sel = @($Catalog | Where-Object { $Rows[$_.Id].Check.IsChecked })
    $adv = @($sel | Where-Object { $_.Risk -eq 'Advanced' }).Count
    $txt = "$($sel.Count) selected"
    if ($adv) { $txt += "  /  $adv advanced" }
    $ui.SelCount.Text = $txt
    $ui.BtnRun.IsEnabled = ($sel.Count -gt 0 -and -not $script:Running)
}

foreach ($g in $Groups) {
    $items = @($Catalog | Where-Object { $_.Group -eq $g })
    if ($items.Count -eq 0) { continue }

    $hdr = New-Object Windows.Controls.Grid
    $hdr.Margin = New-Object Windows.Thickness(2, 18, 0, 10)
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(1, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
    $hdr.ColumnDefinitions.Add($c1); $hdr.ColumnDefinitions.Add($c2)
    $ht = New-Object Windows.Controls.TextBlock
    $ht.Text = $g.ToUpper(); $ht.FontSize = 11.5; $ht.FontWeight = [Windows.FontWeights]::Bold; $ht.Foreground = $Br.Faint; $ht.VerticalAlignment = 'Center'
    $hdr.Children.Add($ht) | Out-Null
    $hb = New-Object Windows.Controls.Button
    $hb.Style = $Window.FindResource('GhostButton'); $hb.Content = 'Toggle all'; $hb.Tag = $g; $hb.FontSize = 12
    [Windows.Controls.Grid]::SetColumn($hb, 1)
    $hb.Add_Click({
        param($s, $e)
        $ids = @($Catalog | Where-Object { $_.Group -eq $s.Tag } | ForEach-Object { $_.Id })
        $allOn = @($ids | Where-Object { -not $Rows[$_].Check.IsChecked }).Count -eq 0
        foreach ($id in $ids) { $Rows[$id].Check.IsChecked = (-not $allOn) }
    })
    $hdr.Children.Add($hb) | Out-Null
    $ui.TaskPanel.Children.Add($hdr) | Out-Null

    foreach ($t in $items) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Style = $Window.FindResource('TaskRow'); $cb.Tag = $t.Id

        $grid = New-Object Windows.Controls.Grid
        $a = New-Object Windows.Controls.ColumnDefinition; $a.Width = New-Object Windows.GridLength(1, 'Star')
        $b = New-Object Windows.Controls.ColumnDefinition; $b.Width = [Windows.GridLength]::Auto
        $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = New-Object Windows.GridLength(34)
        $grid.ColumnDefinitions.Add($a); $grid.ColumnDefinitions.Add($b); $grid.ColumnDefinitions.Add($c)

        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = New-Object Windows.Thickness(0, 0, 12, 0)
        $title = New-Object Windows.Controls.TextBlock
        $title.Text = $t.Name; $title.FontSize = 14; $title.FontWeight = [Windows.FontWeights]::SemiBold; $title.Foreground = $Br.Text
        $desc = New-Object Windows.Controls.TextBlock
        $desc.Text = $t.Desc; $desc.FontSize = 12.5; $desc.Foreground = $Br.Muted; $desc.TextWrapping = 'Wrap'
        $desc.Margin = New-Object Windows.Thickness(0, 3, 0, 0)
        $sp.Children.Add($title) | Out-Null; $sp.Children.Add($desc) | Out-Null
        $grid.Children.Add($sp) | Out-Null

        $badges = New-Object Windows.Controls.StackPanel
        $badges.Orientation = 'Horizontal'; $badges.VerticalAlignment = 'Center'
        if ($t.Flags -contains 'Slow') { $badges.Children.Add((New-Badge 'Slow' $Br.Info)) | Out-Null }
        if ($t.Flags -contains 'Reboot') { $badges.Children.Add((New-Badge 'Restart' $Br.Muted)) | Out-Null }
        $badges.Children.Add((New-Badge $t.Risk $RiskBrush[$t.Risk])) | Out-Null
        [Windows.Controls.Grid]::SetColumn($badges, 1)
        $grid.Children.Add($badges) | Out-Null

        $st = New-Object Windows.Controls.TextBlock
        $st.HorizontalAlignment = 'Right'; $st.VerticalAlignment = 'Center'; $st.FontSize = 15
        [Windows.Controls.Grid]::SetColumn($st, 2)
        $grid.Children.Add($st) | Out-Null

        $cb.Content = $grid
        $cb.Add_Checked({ Update-SelCount })
        $cb.Add_Unchecked({ Update-SelCount })
        $ui.TaskPanel.Children.Add($cb) | Out-Null
        $Rows[$t.Id] = @{ Check = $cb; Status = $st }
    }
}

function Set-RowStatus([string]$id, [string]$state) {
    $r = $Rows[$id]; if (-not $r) { return }
    $tb = $r.Status
    switch ($state) {
        'pending' { $tb.FontFamily = $TextFont; $tb.Text = Glyph 0x2022; $tb.Foreground = $Br.Faint }
        'run'     { $tb.FontFamily = $IconFont; $tb.Text = Glyph 0xE895; $tb.Foreground = $Br.Info }
        'ok'      { $tb.FontFamily = $IconFont; $tb.Text = Glyph 0xE73E; $tb.Foreground = $Br.Safe }
        'warn'    { $tb.FontFamily = $IconFont; $tb.Text = Glyph 0xE7BA; $tb.Foreground = $Br.Mod }
        'err'     { $tb.FontFamily = $IconFont; $tb.Text = Glyph 0xEA39; $tb.Foreground = $Br.Adv }
        default   { $tb.Text = '' }
    }
}

function Apply-Preset([string]$name) {
    $ids = $Presets[$name]
    foreach ($t in $Catalog) { $Rows[$t.Id].Check.IsChecked = ($ids -contains $t.Id) }
    Update-SelCount
}
$ui.PresetQuick.Add_Click({ Apply-Preset 'Quick' })
$ui.PresetRecommended.Add_Click({ Apply-Preset 'Recommended' })
$ui.PresetOptiCore.Add_Click({ Apply-Preset 'OptiCore' })
$ui.PresetV6.Add_Click({ Apply-Preset 'V6' })
$ui.PresetNone.Add_Click({ Apply-Preset 'None' })

if ($Settings.Selected.Count -gt 0) { foreach ($id in $Settings.Selected) { if ($Rows[$id]) { $Rows[$id].Check.IsChecked = $true } } }
else { Apply-Preset 'Recommended' }
Update-SelCount

# ------------------------------------------------------------------------------
#  Run engine
# ------------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{})
$sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Status = [hashtable]::Synchronized(@{})
$sync.NativeSrc = $NativeSrc
$sync.LogDir = $LogDir
$script:Running = $false
$script:Job = $null
$script:AfterRun = $null

function Start-Run([object[]]$tasks, [string]$title, [bool]$summary, [scriptblock]$after) {
    if ($script:Running) { return }
    $script:Running = $true
    $script:AfterRun = $after
    $sync.Cancel = $false; $sync.Done = $false; $sync.Index = 0; $sync.Total = @($tasks).Count
    $sync.Current = ''; $sync.Sub = ''; $sync.Summary = ''; $sync.NeedsReboot = $false; $sync.Proc = $null; $sync.Freed = 0.0
    $sync.Status.Clear()
    $sync.LogPath = Join-Path $LogDir ('run-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

    foreach ($r in $Rows.Values) { $r.Status.Text = '' }
    foreach ($t in $tasks) { Set-RowStatus $t.Id 'pending' }

    $jobs = @(foreach ($t in $tasks) { @{ Id = $t.Id; Name = $t.Name; Code = $t.Code.ToString(); Reboot = ($t.Flags -contains 'Reboot') } })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerScript.ToString()).AddArgument($sync).AddArgument($jobs).AddArgument($title).AddArgument($summary)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Start = Get-Date }

    $ui.RunDot.Fill = $Br.Info
    $ui.RunTitle.Text = $title; $ui.RunSub.Text = 'Starting...'; $ui.RunProgress.Value = 0
    $ui.BtnStop.Content = 'Stop'; $ui.BtnStop.Visibility = 'Visible'
    $ui.BtnRun.IsEnabled = $false; $ui.TileQuick.IsEnabled = $false
    foreach ($r in $Rows.Values) { $r.Check.IsEnabled = $false }
    Set-Console $true
}

function Finish-Run {
    $script:Running = $false
    try { [void]$script:Job.PS.EndInvoke($script:Job.Handle) } catch { Add-LogLine 'err' $_.Exception.Message }
    foreach ($e in $script:Job.PS.Streams.Error) { Add-LogLine 'err' ("Worker: " + $e.Exception.Message) }
    try { $script:Job.PS.Dispose(); $script:Job.RS.Dispose() } catch {}

    $ui.RunProgress.Value = 100
    $ui.BtnStop.Visibility = 'Collapsed'
    $ui.TileQuick.IsEnabled = $true
    foreach ($r in $Rows.Values) { $r.Check.IsEnabled = $true }
    Update-SelCount

    $stopped = $sync.Cancel
    if ($stopped) { $ui.RunDot.Fill = $Br.Mod; $ui.RunTitle.Text = 'Stopped' }
    else { $ui.RunDot.Fill = $Br.Safe; $ui.RunTitle.Text = 'Done' }
    if ($sync.Summary) { $ui.RunSub.Text = $sync.Summary } else { $ui.RunSub.Text = 'Log saved to ' + $sync.LogPath }

    if ($sync.Summary) {
        $script:Settings.LastRun = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $script:Settings.LastSummary = $sync.Summary
        Save-Settings
        Update-Overview
    }
    if ($script:AfterRun) { & $script:AfterRun }
    if ($sync.NeedsReboot -and -not $stopped) {
        Show-Dialog 'Restart recommended' 'Some of the changes only take effect after Windows restarts. Save your work in other apps before restarting.' 'Restart now' 'Later' { Restart-Computer -Force }
    }
}

$ui.BtnStop.Add_Click({
    if (-not $script:Running) { return }
    if (-not $sync.Cancel) {
        $sync.Cancel = $true
        $ui.RunSub.Text = 'Stopping after the current step...'
        $ui.BtnStop.Content = 'Force stop'
    } else {
        $p = $sync.Proc
        if ($p) { try { if (-not $p.HasExited) { $p.Kill(); Add-LogLine 'warn' 'Current tool was force-stopped' } } catch {} }
    }
})

$ui.BtnRun.Add_Click({
    $sel = @($Catalog | Where-Object { $Rows[$_.Id].Check.IsChecked })
    if ($sel.Count -eq 0) { return }
    $script:PendingSel = $sel
    $adv = @($sel | Where-Object { $_.Risk -eq 'Advanced' })
    $slow = @($sel | Where-Object { $_.Flags -contains 'Slow' })
    $body = "$($sel.Count) step(s) will run, top to bottom."
    if ($adv.Count) {
        $body += "`n`nAdvanced steps in this run:`n" + (($adv | ForEach-Object { '   ' + $_.Name }) -join "`n")
        if (-not ($sel | Where-Object { $_.Id -eq 'restore' })) { $body += "`n`nNo restore point is selected. Turning on 'Create a restore point' is strongly recommended." }
    }
    if ($slow.Count) { $body += "`n`nIncludes slow steps (" + (($slow | ForEach-Object { $_.Name }) -join ', ') + '). Plan on 10 to 40 minutes.' }
    Show-Dialog 'Ready to run' $body 'Run now' 'Cancel' { Start-Run $script:PendingSel 'Optimizer' $true $null }
})

# ------------------------------------------------------------------------------
#  Overview
# ------------------------------------------------------------------------------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$Build = [int]$cv.CurrentBuild
$OsName = $cv.ProductName
if ($Build -ge 22000) { $OsName = $OsName -replace 'Windows 10', 'Windows 11' }
$CpuName = ''
try { $CpuName = ((Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString -replace '\s+', ' ').Trim() } catch {}
$BootTime = $null
try { $BootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch { $BootTime = Get-Date }
$TotalRam = ([OPC.Native]::Mem())[0]

$ui.SysLine.Text = '{0}  {1}  (build {2}.{3})   /   {4}   /   {5:N0} GB RAM' -f $OsName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, $env:COMPUTERNAME, ($TotalRam / 1GB)
$ui.CpuSub.Text = $CpuName
$ui.VersionText.Text = "Version $AppVersion"
$ui.AboutPaths.Text = "Logs:      $LogDir`nSettings:  $SettingsPath"
$hour = (Get-Date).Hour
$ui.GreetText.Text = $(if ($hour -lt 12) { 'Good morning' } elseif ($hour -lt 18) { 'Good afternoon' } else { 'Good evening' }) + ", $env:USERNAME"
if (-not $IsAdmin) {
    $ui.AdminText.Text = 'Limited mode (not admin)'; $ui.AdminText.Foreground = $Br.Mod
    $ui.AdminPill.Background = New-Brush '#14FBBF24'; $ui.AdminPill.BorderBrush = New-Brush '#40FBBF24'
}

function Update-Overview {
    if ($Settings.LastRun) { $ui.LastRunText.Text = "Last optimizer run: $($Settings.LastRun).  $($Settings.LastSummary)" }
    else { $ui.LastRunText.Text = 'No optimizer runs yet. Start with Quick clean or the Recommended tune-up.' }

    $ui.DrivesPanel.Children.Clear()
    foreach ($d in ([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $used = $d.TotalSize - $d.AvailableFreeSpace
        $pct = 0; if ($d.TotalSize -gt 0) { $pct = [math]::Round($used * 100.0 / $d.TotalSize) }
        $row = New-Object Windows.Controls.StackPanel
        $row.Margin = New-Object Windows.Thickness(0, 0, 0, 14)
        $g = New-Object Windows.Controls.Grid
        $l = New-Object Windows.Controls.TextBlock
        $label = $d.Name.TrimEnd('\'); if ($d.VolumeLabel) { $label += '  ' + $d.VolumeLabel }
        $l.Text = $label; $l.FontWeight = [Windows.FontWeights]::SemiBold; $l.Foreground = $Br.Text
        $r = New-Object Windows.Controls.TextBlock
        $r.Text = '{0:N0} GB free of {1:N0} GB' -f ($d.AvailableFreeSpace / 1GB), ($d.TotalSize / 1GB)
        $r.Foreground = $Br.Faint; $r.FontSize = 12; $r.HorizontalAlignment = 'Right'
        $g.Children.Add($l) | Out-Null; $g.Children.Add($r) | Out-Null
        $pb = New-Object Windows.Controls.ProgressBar
        $pb.Style = $Window.FindResource('Thin'); $pb.Value = $pct; $pb.Margin = New-Object Windows.Thickness(0, 8, 0, 0)
        if ($pct -ge 90) { $pb.Foreground = $Br.Adv } elseif ($pct -ge 75) { $pb.Foreground = $Br.Mod }
        $row.Children.Add($g) | Out-Null; $row.Children.Add($pb) | Out-Null
        $ui.DrivesPanel.Children.Add($row) | Out-Null
    }
}

function Update-Stats {
    $cpu = [OPC.Native]::Cpu()
    $ui.CpuValue.Text = '{0:N0}%' -f $cpu; $ui.CpuBar.Value = $cpu
    $m = [OPC.Native]::Mem()
    $usedGb = ([double]$m[0] - [double]$m[1]) / 1GB
    $ui.MemValue.Text = '{0:N1} GB' -f $usedGb
    $ui.MemSub.Text = 'of {0:N1} GB  ({1}%)' -f ([double]$m[0] / 1GB), $m[2]
    $ui.MemBar.Value = [double]$m[2]
    try {
        $d = New-Object IO.DriveInfo($env:SystemDrive)
        $ui.DiskValue.Text = '{0:N0} GB' -f ($d.AvailableFreeSpace / 1GB)
        $usedPct = ($d.TotalSize - $d.AvailableFreeSpace) * 100.0 / $d.TotalSize
        $ui.DiskSub.Text = '{0} of {1:N0} GB  ({2:N0}% used)' -f $env:SystemDrive, ($d.TotalSize / 1GB), $usedPct
        $ui.DiskBar.Value = $usedPct
    } catch {}
    $up = (Get-Date) - $BootTime
    $ui.UpValue.Text = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
    $ui.UpSub.Text = 'since ' + $BootTime.ToString('ddd dd MMM, HH:mm')
}

$ui.TileQuick.Add_Click({
    Apply-Preset 'Quick'
    Start-Run @($Catalog | Where-Object { $Presets.Quick -contains $_.Id }) 'Quick clean' $true $null
})
$ui.TileRecommended.Add_Click({ Apply-Preset 'Recommended'; Go 'NavOptimizer' })
$ui.TileV6.Add_Click({ Apply-Preset 'V6'; Go 'NavOptimizer' })
$ui.TileRestore.Add_Click({ Start-Process rstrui.exe })
$ui.BtnAboutRestore.Add_Click({ Start-Process rstrui.exe })

# ------------------------------------------------------------------------------
#  Remote Desktop
# ------------------------------------------------------------------------------
$RdpFwGroup = '@FirewallAPI.dll,-28752'   # "Remote Desktop" rule group, works in any Windows language

function Set-Dot($dot, [bool]$on) { if ($on) { $dot.Fill = $Br.Safe } else { $dot.Fill = $Br.Adv } }

function Update-RdpState {
    $ts  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    $tcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
    $on = ($ts.fDenyTSConnections -eq 0)
    $nla = ($tcp.UserAuthentication -eq 1)
    $port = $tcp.PortNumber; if (-not $port) { $port = 3389 }
    $fw = $false
    try { $fw = @(Get-NetFirewallRule -Group $RdpFwGroup -ErrorAction Stop | Where-Object { "$($_.Enabled)" -eq 'True' }).Count -gt 0 } catch {}
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue

    Set-Dot $ui.DotRdp $on;  $ui.TxtRdp.Text = 'Remote Desktop: ' + $(if ($on) { 'On' } else { 'Off' })
    Set-Dot $ui.DotNla $nla; $ui.TxtNla.Text = 'Network Level Authentication: ' + $(if ($nla) { 'On' } else { 'Off' })
    Set-Dot $ui.DotFw $fw;   $ui.TxtFw.Text = 'Firewall rule: ' + $(if ($fw) { 'Allowed' } else { 'Blocked' })
    $svcOn = ($svc -and "$($svc.Status)" -eq 'Running')
    Set-Dot $ui.DotSvc $svcOn; $ui.TxtSvc.Text = 'Remote Desktop service: ' + $(if ($svc) { "$($svc.Status)" } else { 'Not found' })
    $ui.TxtPort.Text = "Listening port: $port"

    $isHome = "$($cv.EditionID)" -like 'Core*'
    if ($isHome) { $ui.RdpHomeWarn.Visibility = 'Visible'; $ui.BtnRdpEnable.IsEnabled = $false } else { $ui.RdpHomeWarn.Visibility = 'Collapsed'; $ui.BtnRdpEnable.IsEnabled = $true }

    $lines = @()
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -eq 'InterNetwork' -and -not $ua.Address.ToString().StartsWith('169.254')) {
                $suffix = ''; if ($port -ne 3389) { $suffix = ":$port" }
                $lines += ('{0,-16} {1}' -f ($ua.Address.ToString() + $suffix), $ni.Name)
            }
        }
    }
    $ipText = 'No active network connection'
    if ($lines.Count) { $ipText = $lines -join "`r`n" }
    $ui.TxtIps.Text = "$env:COMPUTERNAME`r`n" + $ipText
}

$ui.BtnRdpRefresh.Add_Click({ Update-RdpState })
$ui.BtnRdpSettings.Add_Click({ Start-Process SystemPropertiesRemote.exe })

$RdpEnableTask = T 'rdp-on' 'RDP' 'Enable Remote Desktop' '' 'Safe' @() {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
    Ok 'Remote Desktop and NLA turned on'
    try { Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop; Ok 'Firewall rule enabled' }
    catch { & netsh.exe advfirewall firewall set rule group="remote desktop" new enable=Yes | Out-Null; Ok 'Firewall rule enabled (netsh)' }
    Set-Service -Name TermService -StartupType Manual -ErrorAction SilentlyContinue
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Ok 'Remote Desktop service started'
}
$RdpDisableTask = T 'rdp-off' 'RDP' 'Disable Remote Desktop' '' 'Safe' @() {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1
    try { Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop; Ok 'Firewall rule disabled' } catch { Skip 'Firewall rule not changed' }
    Ok 'Remote Desktop turned off. Existing sessions stay connected until they sign out.'
}
$ui.BtnRdpEnable.Add_Click({ Start-Run @($RdpEnableTask) 'Remote Desktop' $false { Update-RdpState } })
$ui.BtnRdpDisable.Add_Click({
    Show-Dialog 'Disable Remote Desktop?' 'Nobody will be able to connect to this PC remotely. If you are connected over RDP right now, you keep your current session.' 'Disable' 'Cancel' {
        Start-Run @($RdpDisableTask) 'Remote Desktop' $false { Update-RdpState }
    }
})

$ui.ChkFull.IsChecked = [bool]$Settings.RdpFull
$ui.ChkMulti.IsChecked = [bool]$Settings.RdpMulti
$ui.ChkAdmin.IsChecked = [bool]$Settings.RdpAdmin

function Get-Target {
    $h = $ui.TxtHost.Text.Trim()
    $p = $ui.TxtPortIn.Text.Trim()
    if (-not $h) { $ui.ClientMsg.Foreground = $Br.Mod; $ui.ClientMsg.Text = 'Type the IP address or name of the PC to connect to.'; return $null }
    if ($h -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_]*$') { $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = 'That does not look like an IP address or hostname.'; return $null }
    $pn = 0
    if (-not [int]::TryParse($p, [ref]$pn) -or $pn -lt 1 -or $pn -gt 65535) { $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = 'Port must be a number from 1 to 65535.'; return $null }
    return @{ Host = $h; Port = $pn }
}

function Update-Recent {
    $ui.RecentPanel.Children.Clear()
    $recent = @($Settings.Recent)
    if ($recent.Count -eq 0) { return }
    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = 'RECENT'; $lbl.FontSize = 11; $lbl.FontWeight = [Windows.FontWeights]::SemiBold; $lbl.Foreground = $Br.Faint
    $lbl.VerticalAlignment = 'Center'; $lbl.Margin = New-Object Windows.Thickness(0, 0, 10, 6)
    $ui.RecentPanel.Children.Add($lbl) | Out-Null
    foreach ($r in $recent) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $Window.FindResource('ChipButton'); $b.Content = $r; $b.Tag = $r; $b.FontSize = 12
        $b.Padding = New-Object Windows.Thickness(10, 4, 10, 4); $b.Margin = New-Object Windows.Thickness(0, 0, 6, 6)
        $b.Add_Click({
            param($s, $e)
            $v = [string]$s.Tag
            if ($v -match '^(.+):(\d+)$') { $ui.TxtHost.Text = $Matches[1]; $ui.TxtPortIn.Text = $Matches[2] }
            else { $ui.TxtHost.Text = $v; $ui.TxtPortIn.Text = '3389' }
        })
        $ui.RecentPanel.Children.Add($b) | Out-Null
    }
}

$ui.BtnConnect.Add_Click({
    $t = Get-Target; if (-not $t) { return }
    $target = $t.Host; if ($t.Port -ne 3389) { $target = '{0}:{1}' -f $t.Host, $t.Port }
    $mstscArgs = @("/v:$target")
    if ($ui.ChkFull.IsChecked) { $mstscArgs += '/f' }
    if ($ui.ChkMulti.IsChecked) { $mstscArgs += '/multimon' }
    if ($ui.ChkAdmin.IsChecked) { $mstscArgs += '/admin' }
    try {
        Start-Process -FilePath mstsc.exe -ArgumentList $mstscArgs
        $ui.ClientMsg.Foreground = $Br.Muted
        $ui.ClientMsg.Text = "Opening Remote Desktop Connection to $target. Sign in with an account on that PC."
        $list = @($target) + @($Settings.Recent | Where-Object { $_ -ne $target })
        $script:Settings.Recent = @($list | Select-Object -First 6)
        $script:Settings.RdpFull = [bool]$ui.ChkFull.IsChecked; $script:Settings.RdpMulti = [bool]$ui.ChkMulti.IsChecked; $script:Settings.RdpAdmin = [bool]$ui.ChkAdmin.IsChecked
        Save-Settings; Update-Recent
    } catch { $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = "Could not start mstsc: $($_.Exception.Message)" }
})

$script:Probe = $null
$ProbeTimer = New-Object Windows.Threading.DispatcherTimer
$ProbeTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$ProbeTimer.Add_Tick({
    $p = $script:Probe
    if (-not $p) { $ProbeTimer.Stop(); return }
    $elapsed = ((Get-Date) - $p.Start).TotalSeconds
    if ($p.Task.IsCompleted -or $elapsed -gt 4) {
        $ProbeTimer.Stop()
        $okConn = ($p.Task.IsCompleted -and -not $p.Task.IsFaulted -and $p.Client.Connected)
        if ($okConn) { $ui.ClientMsg.Foreground = $Br.Safe; $ui.ClientMsg.Text = "Port $($p.Port) on $($p.Host) is open. Ready to connect." }
        elseif ($p.Task.IsFaulted) {
            $inner = $p.Task.Exception.InnerException; $why = 'connection refused or blocked'
            if ($inner -and $inner.Message) { $why = $inner.Message }
            $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = "Cannot reach $($p.Host):$($p.Port). $why"
        }
        else { $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = "No answer from $($p.Host):$($p.Port) within 4 seconds. Check the IP, that RDP is enabled there, and the firewall." }
        try { $p.Client.Close() } catch {}
        $script:Probe = $null
        $ui.BtnTestPort.IsEnabled = $true
    }
})
$ui.BtnTestPort.Add_Click({
    $t = Get-Target; if (-not $t) { return }
    try {
        $c = New-Object Net.Sockets.TcpClient
        $script:Probe = @{ Client = $c; Task = $c.ConnectAsync($t.Host, $t.Port); Start = Get-Date; Host = $t.Host; Port = $t.Port }
        $ui.ClientMsg.Foreground = $Br.Muted; $ui.ClientMsg.Text = "Testing $($t.Host):$($t.Port)..."
        $ui.BtnTestPort.IsEnabled = $false
        $ProbeTimer.Start()
    } catch { $ui.ClientMsg.Foreground = $Br.Adv; $ui.ClientMsg.Text = $_.Exception.Message }
})
$ui.TxtHost.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $ui.BtnConnect.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
Update-Recent

# ------------------------------------------------------------------------------
#  Timers
# ------------------------------------------------------------------------------
$UiTimer = New-Object Windows.Threading.DispatcherTimer
$UiTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$UiTimer.Add_Tick({
    try {
        $item = $null; $n = 0
        while ($n -lt 300 -and $sync.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1]; $n++ }
        if ($n -gt 0 -and $LogItems.Count -gt 0) { $ui.LogList.ScrollIntoView($LogItems[$LogItems.Count - 1]) }
        if ($script:Running) {
            foreach ($k in @($sync.Status.Keys)) { Set-RowStatus $k $sync.Status[$k] }
            if ($sync.Total -gt 0) { $ui.RunProgress.Value = [math]::Max(0, ($sync.Index - 1)) * 100.0 / $sync.Total + 2 }
            if ($sync.Current) {
                $ui.RunTitle.Text = '{0}  ({1}/{2})' -f $sync.Current, $sync.Index, $sync.Total
                $el = (Get-Date) - $script:Job.Start
                $sub = $sync.Sub; if (-not $sub) { $sub = 'Working...' }
                if (-not $sync.Cancel) { $ui.RunSub.Text = '{0:mm\:ss} elapsed  /  {1}' -f $el, $sub }
            }
            if ($sync.Done -and $sync.Queue.IsEmpty) {
                foreach ($k in @($sync.Status.Keys)) { Set-RowStatus $k $sync.Status[$k] }
                Finish-Run
            }
        }
    } catch {}
})

$StatsTimer = New-Object Windows.Threading.DispatcherTimer
$StatsTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
$StatsTimer.Add_Tick({ try { if ($ui.PageOverview.Visibility -eq 'Visible' -and $Window.WindowState -ne 'Minimized') { Update-Stats } } catch {} })

# ------------------------------------------------------------------------------
#  Start
# ------------------------------------------------------------------------------
$Window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    try { Add-LogLine 'err' ('UI error: ' + $e.Exception.Message) } catch {}
})
$Window.Add_Loaded({
    [void][OPC.Native]::Cpu()
    Update-Overview
    try { Update-Stats } catch {}
    $UiTimer.Start(); $StatsTimer.Start()
    Add-LogLine 'info' "OPC V7 $AppVersion ready. Logs are saved to $LogDir"
})
$Window.Add_Closing({
    param($s, $e)
    if ($script:Running) {
        $r = [Windows.MessageBox]::Show('A run is still in progress. Close OPC V7 anyway? The current step keeps running in the background until it finishes.', 'OPC V7', 'YesNo', 'Warning')
        if ("$r" -ne 'Yes') { $e.Cancel = $true; return }
        $sync.Cancel = $true
    }
    $script:Settings.Selected = @($Catalog | Where-Object { $Rows[$_.Id].Check.IsChecked } | ForEach-Object { $_.Id })
    Save-Settings
    $UiTimer.Stop(); $StatsTimer.Stop()
})

[void]$Window.ShowDialog()
