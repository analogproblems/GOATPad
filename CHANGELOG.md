# Changelog

Each release's notes on GitHub come from its section here.

## Unreleased

- **A Windows installer.** `GPad-<version>-windows-x64-setup.exe` installs
  GPad for you alone, with no admin rights, adds it to the Start menu (and,
  if you like, the desktop), and lists it in **Settings → Apps** for
  uninstalling. GPad keeps itself up to date there, and uninstalling keeps
  your notes. The portable zip is still there for running GPad without
  installing it.

## 0.1.0

The first release of GPad, for Windows and Linux.

- **Notes that keep themselves.** Everything is saved as you type, and your
  tabs come back when you open GPad again. Closing a tab keeps the note,
  and a deleted note waits in the trash for 30 days.
- **Three kinds of note.** Rich (formatted, kept as Markdown), Code (syntax
  highlighted) or Plain, picked from what you first paste and easy to
  change. Pasting from a web page or Word keeps the formatting.
- **Folders that are tab groups**, and **Ctrl+P** to search every note.
- **Themes**: Warm, Classic and Slate, each light or dark, with
  colorblind-safe and high-contrast code colors.
- **End-to-end encrypted sync** through Google Drive, or through any folder
  that Dropbox, OneDrive, Nextcloud or Syncthing keeps in step. Notes are
  encrypted on your computer with a passphrase only you know, and a
  recovery key in case you forget it. You can change both.
- **Sync from the tray**: with it on, closing the window keeps GPad syncing
  until you quit from the tray icon.
- **Downloads**: a portable Windows zip that needs no installer or admin
  rights, a .deb for Debian and Ubuntu, and an AppImage for other Linux
  systems.
- **Updates itself** from GitHub, installing only releases signed with
  GPad's key. The .deb tells you about new versions instead.
