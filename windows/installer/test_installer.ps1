# Tests GPad's installer the way people will use it, as CI does after
# building it: refuses a folder that holds other files, installs for this
# account, starts GPad from there, won't install or uninstall while GPad is
# open, finishes a self-update there the way GPad does, installs over that,
# and uninstalls, keeping the notes.
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
  # A folder that holds someone else's files: uninstalling would delete
  # their DLLs along with GPad's.
  $taken = Join-Path $env:TEMP 'not-for-gpad'
  New-Item -Force (Join-Path $taken 'theirs.dll') | Out-Null
  $code = Install 'taken-folder' "/DIR=`"$taken`""
  Check ($code -ne 0 -and -not (Test-Path (Join-Path $taken 'gpad.exe'))) `
    "won't install into a folder that holds other files (exit code $code)"

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
  $code = Install 'while-open'
  Check ($code -ne 0) "won't install while GPad is open (exit code $code)"
  Invoke-Exe (Join-Path $app 'unins000.exe') $quiet 120 | Out-Null
  Check ((Test-Path (Join-Path $app 'gpad.exe')) -and (Test-Path $key)) `
    "won't uninstall while GPad is open"
  Stop-GPad $gpad

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
