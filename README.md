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
formatting. Encrypted sync works through any folder that Dropbox, OneDrive,
Nextcloud or Syncthing keeps in step; Google Drive is next.

| Step | What it delivers | State |
| --- | --- | --- |
| 1. Foundations | Flutter app for Windows and Linux, CI, design note, editor lab | Done |
| 2. Local notepad | Autosave, session restore, folders and tab groups, search, saved settings, formatted paste | Done |
| 3. Encrypted sync | End-to-end encryption, sync-folder and Google Drive backends | In progress (sync folder done) |
| 4. Release | GitHub Releases, Windows installer, Flatpak | Planned (.deb and AppImage already built by CI) |

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
  only you know, before they reach your sync folder (and, soon, Google
  Drive). There is no GPad server. Edits on two computers at once are
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
8. Click **Sync is off** at the bottom of the sidebar and choose a folder
   that Dropbox, OneDrive, Nextcloud or Syncthing syncs. Pick a passphrase
   and save the recovery key. On your other computer, choose the same
   folder and type the same passphrase: your notes from both appear on
   both, and edits show up on the other one a few seconds later.

## Where your notes are

GPad keeps everything in one SQLite file, `notes.db`:

- **Linux:** `~/.local/share/gpad/` (or `$XDG_DATA_HOME/gpad/`)
- **Windows:** `%LOCALAPPDATA%\GPad\`

Set `GPAD_DATA_DIR` to use another folder, for example to run a portable
copy from a USB stick. Only one GPad can have the file open at a time; a
second window tells you GPad is already open instead of risking your edits.

With sync on, the encrypted copies live in a `GPad` folder inside the sync
folder you chose. GPad remembers your passphrase in the system keychain
(GNOME Keyring or KWallet on Linux, Credential Manager on Windows) if you
let it, and asks for it each time it starts otherwise.

## Download a test build

Builds from CI are attached to each run under **Actions → CI → Artifacts**.
GitHub wraps each one in a zip, so unzip it first.

- **Windows:** `gpad-windows-x64`. Unzip and run `gpad.exe`. No installer or
  admin rights needed.
- **Debian or Ubuntu:** `gpad-linux-deb`. Install with
  `sudo apt install ./gpad_0.1.0_amd64.deb`, then open GPad from the app menu
  or run `gpad`.
- **Any Linux (AppImage):** `gpad-linux-appimage`. Make it executable with
  `chmod +x GPad-0.1.0-x86_64.AppImage` and run it. If it says FUSE is
  missing, install `fuse3` or start it with `--appimage-extract-and-run`.

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

## License

[MIT](LICENSE)
