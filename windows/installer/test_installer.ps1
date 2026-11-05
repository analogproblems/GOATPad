# Tests GPad's installer the way people will use it, as CI does after
# building it: refuses a folder that holds other files, installs for this
# account, starts GPad from there, won't install or uninstall while GPad is
# open, finishes a self-update there the way GPad does, installs over that,
# uninstalls, keeping the notes, and installs into an empty folder.
#
#   windows/installer/test_installer.ps1 -Setup dist\GPad-0.1.1-windows-x64-setup.exe `
#     -Build build\windows\x64\runner\Release -Version 0.1.1
#
# It installs GPad for this account and starts it: run it on a throwaway
# machine, like CI's, never on one with notes of your own.
param(
  [Parameter(Mandatory)] [string] $Setup,
  [Parameter(Mandatory)] [string] $Build,
  [Parameter(Mandatory)] [string] $Version
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Setup = (Resolve-Path $Setup).Path
$Build = (Resolve-Path $Build).Path
$app = Join-Path $env:LOCALAPPDATA 'Programs\GPad'
$notes = Join-Path $env:LOCALAPPDATA 'GPad'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{897E6F70-EBD0-4396-8FA0-41AD9320D1E2}_is1'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'GPad.lnk'
$logs = Join-Path $env:TEMP 'gpad-installer-logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$quiet = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'

# The mutexes GPad holds while it runs, which Setup and Uninstall look for.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GPadMutex {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr OpenMutexW(uint access, bool inherit, string name);
  [DllImport("kernel32.dll")]
  static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")]
  static extern IntPtr LocalFree(IntPtr memory);
  [DllImport("advapi32.dll")]
  static extern uint GetSecurityInfo(IntPtr handle, int type, uint what,
    IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
  static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
    IntPtr descriptor, uint revision, uint what, out IntPtr text, IntPtr length);

  const uint Synchronize = 0x00100000, ReadControl = 0x00020000;
  const uint DaclInformation = 4;

  // Mutex name's DACL as SDDL, or null if there is no such mutex.
  public static string Dacl(string name) {
    IntPtr mutex = OpenMutexW(Synchronize | ReadControl, false, name);
    if (mutex == IntPtr.Zero) return null;
    try {
      IntPtr descriptor, text;
      if (GetSecurityInfo(mutex, 6 /* kernel object */, DaclInformation,
          IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor) != 0) {
        return "";
      }
      try {
        if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor, 1, DaclInformation, out text, IntPtr.Zero)) {
          return "";
        }
        string sddl = Marshal.PtrToStringUni(text);
        LocalFree(text);
        return sddl;
      } finally {
        LocalFree(descriptor);
      }
    } finally {
      CloseHandle(mutex);
    }
  }
}
'@

function Check([bool] $ok, [string] $what) {
  if (-not $ok) { throw "FAIL: $what" }
  Write-Host "ok: $what"
}

# Runs $file with $arguments and returns its exit code, giving up after
# $seconds.
function Invoke-Exe([string] $file, [string] $arguments, [int] $seconds = 300) {
  $process = [Diagnostics.Process]::Start($file, $arguments)
  if (-not $process.WaitForExit($seconds * 1000)) {
    $process.Kill($true)
    throw "$file $arguments didn't finish in $seconds seconds"
  }
  return $process.ExitCode
}

function Install([string] $name, [string] $more = '') {
  return Invoke-Exe $Setup "$quiet /LOG=`"$logs\$name.log`" $more"
}

# Waits up to $seconds for $condition to hold, and says whether it did.
function Wait-Until([scriptblock] $condition, [int] $seconds = 60) {
  $until = (Get-Date).AddSeconds($seconds)
  while (-not (& $condition)) {
    if ((Get-Date) -gt $until) { return $false }
    Start-Sleep -Milliseconds 250
  }
  return $true
}

function Start-GPad {
  $gpad = Start-Process (Join-Path $app 'gpad.exe') -PassThru
  Check (Wait-Until { Test-Path (Join-Path $notes 'notes.db') }) 'GPad starts and opens its notes'
  Start-Sleep -Seconds 5
  Check (-not $gpad.HasExited) 'GPad keeps running'
  return $gpad
}

function Stop-GPad($gpad) {
  Stop-Process -Id $gpad.Id
  $gpad.WaitForExit()
}

function Get-Entry([string] $name) {
  return Get-ItemPropertyValue -Path $key -Name $name
}

try {
  # A folder that holds other programs' files, even with a portable GPad
  # among them: installing would replace their data folder, and
  # uninstalling would delete their DLLs along with GPad's.
  $taken = Join-Path $env:TEMP 'not-for-gpad'
  $theirs = 'gpad.exe', 'theirs.dll', 'data\theirs.txt'
  foreach ($file in $theirs) {
    New-Item -ItemType File -Force (Join-Path $taken $file) -Value 'theirs' | Out-Null
  }
  $code = Install 'taken-folder' "/DIR=`"$taken`""
  $kept = @($theirs | Where-Object {
      (Get-Content -Raw (Join-Path $taken $_)) -eq 'theirs' })
  Check ($code -ne 0 -and $kept.Count -eq $theirs.Count -and
    @(Get-ChildItem $taken -Recurse -File).Count -eq $theirs.Count) `
    "won't install into a folder that holds other files, even gpad.exe (exit code $code)"

  $code = Install 'install'
  Check ($code -eq 0) "installs (exit code $code)"
  $built = Get-ChildItem $Build -Recurse -File |
    ForEach-Object { [IO.Path]::GetRelativePath($Build, $_.FullName) }
  $missing = @($built | Where-Object { -not (Test-Path (Join-Path $app $_)) })
  Check ($missing.Count -eq 0) "installs every file of the build in $app (missing: $missing)"
  Check (Test-Path (Join-Path $app 'unins000.exe')) 'installs an uninstaller'
  Check (Test-Path $shortcut) 'adds GPad to the Start menu'
  Check ((Get-Entry 'DisplayName') -eq 'GPad') 'lists GPad among installed apps'
  Check ((Get-Entry 'DisplayVersion') -eq $Version) "with version $Version"
  Check ((Get-Entry 'InstallLocation') -eq "$app\") "installed in $app"

  $gpad = Start-GPad
  Check ($null -ne [GPadMutex]::Dacl('GPad.Running')) 'GPad holds its mutex'
  $global = [GPadMutex]::Dacl('Global\GPad.Running')
  Check ($null -ne $global) 'and one every session sees'
  # Anyone signed in may wait on it, and only its owner may do more.
  Check ($global -match '^D:(\(A;;[^)]*;;;(OW|AU)\)){2}$' -and
    $global -match '\(A;;0x100000;;;AU\)') "which others may only wait on ($global)"
  $code = Install 'while-open'
  Check ($code -ne 0) "won't install while GPad is open (exit code $code)"
  Invoke-Exe (Join-Path $app 'unins000.exe') $quiet 120 | Out-Null
  Check ((Test-Path (Join-Path $app 'gpad.exe')) -and (Test-Path $key)) `
    "won't uninstall while GPad is open"
  Stop-GPad $gpad
  Check ($null -eq [GPadMutex]::Dacl('GPad.Running') -and
    $null -eq [GPadMutex]::Dacl('Global\GPad.Running')) 'GPad lets go of its mutexes as it quits'

  # A self-update, as WindowsFolderInstallation finishes one: the new
  # version, unzipped into .gpad-update, puts its files in place of the
  # installed ones. This one brings a file the installed version lacks.
  $staged = Join-Path $app '.gpad-update\GPad'
  New-Item -ItemType Directory (Split-Path $staged) | Out-Null
  Copy-Item $Build $staged -Recurse
  New-Item (Join-Path $staged 'data\ci-update.txt') -Value 'new' | Out-Null
  Set-ItemProperty -Path $key -Name DisplayVersion -Value '0.0.1'
  $code = Invoke-Exe (Join-Path $staged 'gpad.exe') "--gpad-finish-update `"$app`" 0" 120
  Check ($code -eq 0) "a self-update finishes (exit code $code)"
  Check (Test-Path (Join-Path $app 'data\ci-update.txt')) "the update's files are in place"
  Check (Test-Path (Join-Path $app '.gpad-old\gpad.exe')) 'the old files wait aside'
  Check (-not (Test-Path (Join-Path $app '.gpad-update-failed'))) 'nothing failed'
  Check ((Get-Entry 'DisplayVersion') -eq $Version) 'installed apps show the new version'
  $gpad = Start-GPad
  Check (Wait-Until { -not (Test-Path (Join-Path $app '.gpad-old')) -and
      -not (Test-Path (Join-Path $app '.gpad-update')) }) `
    'the next start tidies up after the update'
  Stop-GPad $gpad

  # Installing over GPad: what an unfinished update left must not come back.
  New-Item -Force (Join-Path $app '.gpad-old\gpad.exe') -Value 'old' | Out-Null
  New-Item (Join-Path $app '.gpad-replacing') | Out-Null
  $code = Install 'reinstall'
  Check ($code -eq 0) "installs over itself (exit code $code)"
  Check (-not (Test-Path (Join-Path $app 'data\ci-update.txt'))) 'replaces the old assets'
  Check (-not (Test-Path (Join-Path $app '.gpad-old')) -and
    -not (Test-Path (Join-Path $app '.gpad-replacing'))) 'clears what an update left'
  Check ((Get-ItemProperty (Join-Path $app 'gpad.exe')).Length -gt 1000) 'keeps gpad.exe'

  # Files a later version brought with a self-update go too.
  New-Item (Join-Path $app 'new_plugin.dll') -Value 'plugin' | Out-Null
  New-Item (Join-Path $app '.gpad-update-failed') -Value 'why' | Out-Null
  Invoke-Exe (Join-Path $app 'unins000.exe') $quiet | Out-Null
  Check (Wait-Until { -not (Test-Path $app) }) "uninstalls, leaving nothing in $app"
  Check (-not (Test-Path $key)) 'leaves installed apps'
  Check (-not (Test-Path $shortcut)) 'leaves the Start menu'
  Check (Test-Path (Join-Path $notes 'notes.db')) "keeps the notes in $notes"

  # An empty folder of the person's choosing will do.
  $chosen = Join-Path $env:TEMP 'empty-for-gpad'
  New-Item -ItemType Directory $chosen | Out-Null
  $code = Install 'chosen-folder' "/DIR=`"$chosen`""
  Check ($code -eq 0 -and (Test-Path (Join-Path $chosen 'gpad.exe'))) `
    "installs into an empty folder (exit code $code)"
  Invoke-Exe (Join-Path $chosen 'unins000.exe') $quiet | Out-Null
  Check (Wait-Until { -not (Test-Path $key) -and
      @(Get-ChildItem $chosen -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0 }) `
    'and uninstalls from there'
} catch {
  Get-ChildItem $logs -Filter *.log | ForEach-Object {
    Write-Host "::group::$($_.Name)"
    Get-Content $_.FullName | Write-Host
    Write-Host '::endgroup::'
  }
  if (Test-Path $app) {
    Get-ChildItem $app -Force -Recurse -Depth 1 | Select-Object -ExpandProperty FullName | Write-Host
  }
  throw
}
