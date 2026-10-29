# GPad

GPad (built in this GOATPad repository: the greatest notepad of all time) is a
fast, Sublime-style notepad that keeps everything you paste and syncs it
between your computers, end-to-end encrypted, through storage you already
have.

Paste something on your Windows work machine, close the window, and find it
waiting in a tab on your Linux machine at home.

![A pasted SQL query detected as Code and named from its comment](docs/images/editor-lab.png)

## Status

Early. The local notepad is done: notes are saved as you type, your tabs
come back when you reopen GPad, folders double as tab groups, Ctrl+P
searches everything, and pasting from a web page or Word keeps the
formatting. Encrypted sync works through Google Drive, or through any folder
that Dropbox, OneDrive, Nextcloud or Syncthing keeps in step.

| Step | What it delivers | State |
| --- | --- | --- |
| 1. Foundations | Flutter app for Windows and Linux, CI, design note, editor lab | Done |
| 2. Local notepad | Autosave, session restore, folders and tab groups, search, saved settings, formatted paste | Done |
| 3. Encrypted sync | End-to-end encryption, sync-folder and Google Drive backends | In progress (all built: sync folder, Google Drive, passphrase changes, tray sync; a real two-computer Google Drive check is next) |
| 4. Release | Security review, GitHub Releases, self-updates, Windows installer, Flatpak | In progress (security review done; CI already builds the Windows zip, .deb and AppImage) |

See [docs/design.md](docs/design.md) for how it is meant to work and why.

## What makes it different

- **Smart modes.** Each note is Rich (Markdown underneath), Code (syntax
  highlighted) or Plain, picked automatically from what you first paste and
  changeable with one click.
- **Paste keeps its formatting.** Copy from a web page, Word or Google Docs
  and the headings, lists, links and tables arrive as a Rich note, stored as
  clean Markdown.
- **Nothing lost.** No save prompts. Closing a tab keeps the note, marked
  closed, so tabs stay tidy without throwing anything away.
- **Folders are tab groups.** Open notes are grouped in the tab strip by the
  folder they are in, and a click folds a group away.
- **Private sync.** Notes are encrypted on your device, with a passphrase
  only you know, before they reach Google Drive or your sync folder. There
  is no GPad server. Edits on two computers at once are
  merged, and when both changed the same text you get both versions.
- **Your look.** Warm, Classic or Slate themes, each in light and dark, and
  code colors you can switch to a colorblind-safe or high-contrast scheme.

## Try it

1. Press Ctrl+N and paste code, JSON, an email or a Markdown list. Watch the
   mode and the suggested name change.
2. Close GPad without saving, then open it again. Your tabs, and what you
   typed, are still there.
3. Close a tab with Ctrl+W and reopen it from the sidebar. Right-click a note
   to move it to the trash, where it stays for 30 days.
4. Make a folder with the button next to NOTES and drag a note onto it. Its
   tab joins the folder's group; click the group's label to fold it away.
5. Press Ctrl+P and type part of any word. Closed and trashed notes turn up
   too.
6. Copy part of a web page and press Ctrl+Shift+V. The formatting comes with
   it; switch the note to Plain to see the Markdown underneath.
7. Open **Appearance** (the palette button) to try the themes and code
   colors. GPad remembers your choice.
8. Click **Sync is off** at the bottom of the sidebar. Choose **Google
   Drive** and sign in in your browser, or choose **A sync folder** and pick
   a folder that Dropbox, OneDrive, Nextcloud or Syncthing syncs. Pick a
   passphrase and save the recovery key. On your other computer, sign in to
   the same Google account (or choose the same folder) and type the same
   passphrase: your notes from both appear on both. Edits show up on the
   other computer within a minute through Drive, or a few seconds through a
   folder.

## Where your notes are

GPad keeps everything in one SQLite file, `notes.db`:

- **Linux:** `~/.local/share/gpad/` (or `$XDG_DATA_HOME/gpad/`)
- **Windows:** `%LOCALAPPDATA%\GPad\`

Set `GPAD_DATA_DIR` to use another folder, for example to run a portable
copy from a USB stick. Only one GPad can have the file open at a time;
starting GPad again brings the open one to the front instead.

`notes.db` isn't encrypted, so anyone who can use your computer account can
read it. On Linux GPad makes its folder private to your account; on Windows
your local app data folder already is. A folder on a USB stick or another
drive that doesn't keep Linux permissions, like FAT, can't be made private.

With sync on, the encrypted copies live in a `GPad` folder in your Google
Drive, or inside the sync folder you chose. If you let it, GPad keeps the key
that unlocks them (not your passphrase) in the system keychain (GNOME Keyring
or KWallet on Linux, Credential Manager on Windows); otherwise it asks for the
passphrase each time it starts. GPad's Google sign-in goes in the keychain
too; without one, GPad asks you to sign in again after each start.

To keep syncing while the window is closed, tick **Keep syncing in the
tray when the window is closed** in the sync window. Closing the window then
leaves GPad in the system tray, and you quit from the tray icon's menu. On
Linux this needs a desktop with a tray (KDE, Xfce, Cinnamon, MATE, Ubuntu;
plain GNOME needs the AppIndicator extension) and libayatana-appindicator,
which the .deb asks for.

To change your passphrase, or replace a recovery key that may have been
seen, click the sync line in the sidebar and choose **Change passphrase…**
or **New recovery key…**. Your other computers take the change as they
sync. The notes' own key stays the same, so someone who has the old
passphrase and an old copy of your synced files could still open them; if
that worries you, turn sync off on every computer and set it up again in a
new place.

GPad asks Google only for the `drive.file` permission, which lets it see the
files it makes and nothing else in your Drive.

### Your own Google client

Release builds sign in to Google with GPad's own client. A build without it
(one you built yourself, say) asks for yours, and anyone can use their own:

1. In [Google Cloud](https://console.cloud.google.com/projectcreate), create
   a project and
   [turn on the Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com).
2. In [Google Auth Platform](https://console.cloud.google.com/auth/overview),
   click **Get started**: choose **External**, add the
   `https://www.googleapis.com/auth/drive.file` scope under **Data Access**,
   and under **Audience** click **Publish app**. (While an app is in testing,
   Google signs its users out after 7 days.)
3. Under **Clients**, create a **Desktop app** client and copy its ID and
   secret.
4. In GPad, open sync, choose **Google Drive**, click **Use your own Google
   client…** and enter them.

Use the same client on every computer: Google shows each client only the
files it made, so a computer with another client won't find your notes. To
build GPad with your client inside, pass
`--dart-define=GPAD_GOOGLE_CLIENT_ID=… --dart-define=GPAD_GOOGLE_CLIENT_SECRET=…`
to `flutter build` or `flutter run`.

## Download

Get GPad from [Releases](https://github.com/analogproblems/GOATPad/releases):

- **Windows 10 or 11:** `GPad-<version>-windows-x64.zip`. Unzip it anywhere
  and run `gpad.exe` in the `GPad` folder. No installer or admin rights
  needed.
- **Debian 12, Ubuntu 22.04 or newer:** `gpad_<version>_amd64.deb`. Install
  it with `sudo apt install ./gpad_<version>_amd64.deb`, then open GPad from
  the app menu or run `gpad`.
- **Other Linux, like Fedora:** `GPad-<version>-x86_64.AppImage`. Make it
  executable (`chmod +x`) and run it. If it says FUSE is missing, install
  `fuse3` or start it with `--appimage-extract-and-run`.

To check a download, see [docs/releasing.md](docs/releasing.md#checking-a-download).

GPad updates itself. Twice a day it looks for a newer release on GitHub
and checks it is signed with GPad's key. The Windows zip and the AppImage
then install it, and it starts the next time you open GPad (or click
**Restart now**). The .deb can't update itself without admin rights, so
GPad tells you a new version is out instead. Turn the checks off in the
window behind the ⓘ button in the sidebar.

### Test builds

Builds of every change are attached to its CI run under **Actions → CI →
Artifacts**: `gpad-windows-x64` (the Windows folder, unzipped),
`gpad-linux-deb` and `gpad-linux-appimage`. GitHub wraps each one in a zip,
so unzip it first, then use it as above.

The Linux builds run on Ubuntu 22.04, Debian 12 and anything newer, and on
current Fedora. CI installs and starts them on each of those.

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or
later.

On Linux, also install the desktop build tools:

```sh
sudo apt-get install clang cmake make ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev
```

Then:

```sh
flutter pub get
flutter test
flutter run -d linux     # or: flutter run -d windows
```

To build the Linux packages yourself:

```sh
flutter build linux --release
linux/packaging/package.sh   # writes the .deb and AppImage to dist/
```

## Security

To report a security problem, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
