; GPad's Windows installer, for Inno Setup 7 (https://jrsoftware.org/isinfo.php).
; CI builds it from the release build, after the Visual C++ runtime is put
; next to gpad.exe (see .github/workflows/ci.yml):
;
;   ISCC /DAppVersion=0.1.1 /DBuildDir=<folder with gpad.exe> /O<output folder> gpad.iss
;
; It installs for the person running it, in %LOCALAPPDATA%\Programs\GPad, so
; it needs no admin rights, and GPad can update itself there the way the
; portable zip does: see WindowsFolderInstallation in
; lib/src/update/installation.dart. Notes live elsewhere, in
; %LOCALAPPDATA%\GPad, and uninstalling never touches them.
;
; IT can install for every account with /ALLUSERS, in Program Files. GPad
; can't write there, so it tells people about new versions instead.

#ifndef AppVersion
  #error Pass the version: ISCC /DAppVersion=0.1.1
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change it: it is how Windows and a newer installer recognise GPad,
; and GPad finds its own entry in installed apps by it (installedAppKey in
; lib/src/update/installation.dart, which a test checks).
AppId={{897E6F70-EBD0-4396-8FA0-41AD9320D1E2}
AppName=GPad
AppVersion={#AppVersion}
AppPublisher=analogproblems
AppPublisherURL=https://github.com/analogproblems/GOATPad
AppSupportURL=https://github.com/analogproblems/GOATPad/issues
AppUpdatesURL=https://github.com/analogproblems/GOATPad/releases
VersionInfoVersion={#AppVersion}
VersionInfoDescription=GPad installer
; Without the version, which self-updates would leave out of date; GPad
; updates the version Windows shows instead.
UninstallDisplayName=GPad
UninstallDisplayIcon={app}\gpad.exe
SetupIconFile=..\runner\resources\app_icon.ico

PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
DefaultDirName={autopf}\GPad
DisableProgramGroupPage=yes
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; GPad holds these mutexes while it runs (windows/runner/main.cpp): one in
; its own session, and one every session sees, so an administrator's Setup or
; Uninstall for an /ALLUSERS install sees GPad open in another person's
; session too. They wait for GPad to be closed, rather than closing it.
AppMutex=GPad.Running,Global\GPad.Running
CloseApplications=no

WizardStyle=modern dynamic windows11
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes
OutputBaseFilename=GPad-{#AppVersion}-windows-x64-setup
OutputDir=..\..\dist

[Messages]
SetupAppRunningError=GPad is open.%n%nQuit it (from its tray icon too, if it has one), then click OK to go on, or Cancel to stop.
UninstallAppRunningError=GPad is open.%n%nQuit it (from its tray icon too, if it has one), then click OK to go on, or Cancel to stop.

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; This puts a whole version in place, so whatever a self-update left behind
; (see WindowsFolderInstallation) has nothing left to do, and the next
; update must not put old files back over these.
Type: filesandordirs; Name: "{app}\.gpad-update"
Type: filesandordirs; Name: "{app}\.gpad-old"
Type: files; Name: "{app}\.gpad-*"
; An older version's assets, which this one may not have.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\GPad"; Filename: "{app}\gpad.exe"
Name: "{autodesktop}\GPad"; Filename: "{app}\gpad.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\gpad.exe"; Description: "{cm:LaunchProgram,GPad}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Self-updates replace GPad's files without the installer, and a later
; version can bring files this installer never knew about. The folder holds
; nothing but GPad (see IsFolderForGPad below).
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: filesandordirs; Name: "{app}\.gpad-update"
Type: filesandordirs; Name: "{app}\.gpad-old"
Type: files; Name: "{app}\.gpad-*"

[Code]
const
  // Where this installer lists GPad among installed apps, as AppId names it.
  EntryKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{897E6F70-EBD0-4396-8FA0-41AD9320D1E2}_is1';

// Whether GPad may go in Dir: a new or empty folder, or the one this
// installer put GPad in before, which was new or empty then. Installing
// replaces its data folder, and uninstalling deletes every DLL in it, so it
// must hold nothing but GPad. A folder with gpad.exe in it isn't enough: a
// portable GPad may share its folder with other programs.
function IsFolderForGPad(Dir: String): Boolean;
var
  Installed: String;
  FindRec: TFindRec;
begin
  Result := True;
  if not DirExists(Dir) then
    Exit;
  if RegQueryStringValue(HKA, EntryKey, 'Inno Setup: App Path', Installed) and
     (CompareText(AddBackslash(Installed), AddBackslash(Dir)) = 0) then
    Exit;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
          Result := False;
      until not Result or not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function FolderTakenMessage(Dir: String): String;
begin
  Result := Dir + ' already holds other files, which uninstalling GPad ' +
    'could delete, so GPad won''t install there. Pick a new or empty folder.';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not IsFolderForGPad(WizardDirValue) then
  begin
    MsgBox(FolderTakenMessage(WizardDirValue), mbError, MB_OK);
    Result := False;
  end;
end;

// Runs whether or not Setup shows its pages, so a folder given with /DIR
// is checked too.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not IsFolderForGPad(ExpandConstant('{app}')) then
    Result := FolderTakenMessage(ExpandConstant('{app}'));
end;
