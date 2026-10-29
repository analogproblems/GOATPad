# GPad design note

GPad is a free, open-source notepad that feels like Sublime Text and syncs
between your computers, end-to-end encrypted, through storage you already
have. The core moment: paste something on a Windows work machine, close the
window, and find it waiting in a tab on a Linux machine at home.

The app is called GPad; the repository and Dart package keep the name
GOATPad (`goatpad`).

This note records the decisions behind v1 and the reasons for them. It is
short on purpose; change it when a decision changes.

## Goals

- A fast, clean editor with syntax highlighting, and themes from warm to
  classic to modern, each in light and dark.
- Nothing is ever lost: every keystroke is kept, tabs come back on reopen, and
  nothing asks "save?".
- Each note picks how to show itself (Rich, Code or Plain) from what you paste.
- Folder sidebar, with tab groups that mirror folders.
- Full-text search across all notes.
- Free sync, encrypted before it leaves the device, with no GPad server.
- Windows and Linux in v1. macOS and mobile later.

## Stack

Flutter (Dart) for one codebase across desktop now and mobile later.

| Part | Package | Why |
| --- | --- | --- |
| Code and Plain editing | [re_editor](https://pub.dev/packages/re_editor) | Draws its own text instead of using `TextField`, so large pastes stay fast. Search and replace, folding, line numbers. |
| Syntax highlighting and language detection | [re_highlight](https://pub.dev/packages/re_highlight) | A Dart port of highlight.js: ~190 grammars and `highlightAuto`. |
| Rich editing | [flutter_quill](https://pub.dev/packages/flutter_quill) + [markdown_quill](https://pub.dev/packages/markdown_quill) | Picked by feel in the step 1 editor lab. See below. |

### Rich editor choice

**flutter_quill**, picked over fleather in the step 1 editor lab for its
nicer UI. It is also the most used and most actively released. Quill stores
its own Delta format, so Markdown goes through
[markdown_quill](https://pub.dev/packages/markdown_quill) in both directions.

Known gaps to handle in step 2:

- Quill throws on any embed it has no builder for, and markdown_quill turns
  `![alt](url)` and `---` into embeds. The lab shows rules as dividers and
  images as their address. Remote images are not fetched, so pasting
  Markdown never makes a network request on its own.
- markdown_quill drops image alt text and escapes punctuation on the way
  out (`Done.` becomes `Done\.`). The meaning survives, but the stored
  Markdown gets noisier. Step 2 should either clean up its output or keep the
  Delta next to the Markdown.

Other candidates:

- **fleather**: also Delta-based, with its own Markdown codec. Compared
  side by side in the lab; Quill felt better.
- **appflowy_editor** was the first pick on paper, because it reads and writes
  Markdown natively. Its latest release (6.2.0, December 2025) does not compile
  on Flutter 3.47.8: `DeltaTextInputService` is missing the new
  `TextInputClient.onFocusReceived` member. It is out until a fixed release
  ships.
- **super_editor** is out: no stable release since 0.2.7 in June 2024.
- **flutter_code_editor** is out: it is built on `TextField`, which slows down
  on large files.

## Notes and modes

Every note is plain text underneath. Its mode decides how it is shown and
edited:

| Mode | Text underneath | Editor |
| --- | --- | --- |
| Rich | Markdown | Rich editor |
| Code | Source in one language | re_editor with highlighting |
| Plain | Anything | re_editor, word wrap on |

Keeping text as the source of truth means search, sync, diffing and future
local AI features all work on the same thing, and nothing is locked into a
GPad-only format. Switching a Rich note to Code shows its Markdown.

`ModeDetector` (`lib/src/notes/mode_detector.dart`) picks a mode on the first
paste into a new note:

1. The clipboard carried HTML (pasted from a browser or Word): Rich. Flutter's
   own clipboard API only exposes plain text, so this needs
   [super_clipboard](https://pub.dev/packages/super_clipboard) in step 2.
2. Parses as JSON, or is an XML document: Code.
3. Two or more kinds of Markdown syntax (headings, lists, links, fences,
   bold, quotes, tasks): Rich.
4. `highlightAuto` over ~20 common languages scores at least 3 and the text
   does not read as prose: Code in that language.
5. Otherwise: Plain.

Language detection scans only the first 8,000 characters, and exact JSON
parsing is skipped above 1 MB in favor of checking how the text opens and
closes, so a huge paste stays instant.
The mode shows in the status bar and one click changes it.

`suggestName` (`lib/src/notes/name_suggester.dart`) fills an editable title
field with no popup: the first line for prose and Markdown, a leading comment
for code, or "SQL snippet 14:03" as a fallback.

Naming, organizing and search sit behind small functions so a local AI model
can take them over later without a rewrite.

## Tabs, closing and deleting

- Open tabs are part of synced state, so a note opened at work shows as a tab
  at home.
- Closing a tab never deletes. The note stays in its folder marked closed and
  reopens with a click.
- Deleting is a separate, deliberate action that moves the note to a trash
  kept for 30 days. Sync spreads deletes to every machine, so the trash is the
  safety net.
- Tab groups always mirror folders. There are no ad hoc groups in v1.

## Themes and code colors

The Appearance dialog has three independent choices:

| Choice | Options |
| --- | --- |
| Theme | Warm (paper and ink, amber accent; the default), Classic (plain white or black, like a traditional editor), Slate (cool blue-grey, modern and neutral) |
| Light or dark | System, Light, Dark |
| Code colors | Match theme (Kimbie, VS or GitHub to suit the theme), Colorblind-safe, High contrast (the a11y scheme) |

Colorblind-safe code colors (`lib/src/code_colors.dart`) use Okabe-Ito hues
(blue, bluish green, orange, vermillion, reddish purple), which avoid the
red/green pairs that most color blindness confuses. Each is tuned to keep at
least 4.5:1 contrast on every theme's editor background, which a test checks.
Keywords are bold and comments italic, so token kinds differ by more than
color.

Code colors only apply to Code notes. Rich notes use the theme's text color,
and Quill's color buttons are hidden for now.

The choices are saved with the other settings.

## Local storage (step 2)

- **One SQLite file**, `notes.db`, in the app data folder:
  `$XDG_DATA_HOME/gpad` (usually `~/.local/share/gpad`) on Linux and
  `%LOCALAPPDATA%\GPad` on Windows. Local rather than roaming on Windows, so
  a roaming profile never copies the database around. `GPAD_DATA_DIR` points
  GPad at another folder, for a portable copy or for testing.
- **The same SQLite everywhere.** The
  [sqlite3](https://pub.dev/packages/sqlite3) package bundles one build of
  SQLite (with FTS5) for every platform, checked against SHA-256 hashes
  pinned in the package, instead of using whatever the system has.
- **Saved as you type.** Typing is saved at most 300 ms after a keystroke,
  even while you keep typing. Everything else (new notes, closing tabs,
  trash, theme, the selected tab) is saved straight away, and GPad saves
  again whenever the window loses focus or closes. Nothing ever asks "save?".
- **Crash-safe.** The database uses SQLite's write-ahead log, so a crash or
  power cut can cost at most the last few hundred milliseconds of typing,
  never the file.
- **One window at a time.** GPad keeps the file locked while it runs. A
  second GPad shows "GPad is already open" instead of loading the notes and
  overwriting edits made in the first window. A crashed GPad releases the
  lock.
- **Schema.** `notes` (random 128-bit id, title, body, mode, language,
  status open/closed/trashed, tab order, timestamps) and `settings` (theme,
  selected tab). The version lives in `PRAGMA user_version`; a database from
  a newer GPad is refused rather than changed. Random ids mean notes made on
  two machines never clash once sync arrives.
- **Trash.** Trashed notes are kept for 30 days and deleted the next time
  GPad starts after that. "Delete forever" and "Empty trash" ask first.
- **Still to come in step 2:** folders with matching tab groups, and search
  using SQLite FTS5 over titles and text.

## Sync (step 3)

Sync goes through a small `SyncBackend` interface with two backends in v1:

- **Google Drive, direct.** Linux has no official Drive desktop app, so
  GPad talks to the Drive API itself. It asks only for the `drive.file`
  scope, which lets it see files it created and nothing else. Full Drive
  access is a restricted scope that needs a paid Google security assessment
  for public apps. Advanced users can supply their own Google OAuth client ID.
- **Sync folder.** The same encrypted files written to any local folder, for
  people who already sync with Dropbox, OneDrive, Nextcloud or Syncthing.

Layout in the remote store:

- One encrypted file per note, named by a random ID, so titles never leak
  through file names and two machines editing different notes never clash.
- One small encrypted index holding folders, tab state and per-note versions.

Timing: upload a few seconds after typing stops, not on close, so shutting
down the work machine cannot strand a paste. An optional tray mode keeps
syncing in the background.

Conflicts: when two machines changed the same note since their last sync,
keep both, and name the second "Note (conflict from <machine>)". Never pick a
winner silently.

## Encryption (step 3)

- Everything is encrypted on the device before upload. The storage provider
  only ever holds ciphertext.
- Passphrase to key: Argon2id. Encryption: XChaCha20-Poly1305. Both from
  libsodium (for example through
  [sodium_libs](https://pub.dev/packages/sodium_libs)); no homemade crypto.
- A random data key encrypts notes; the passphrase-derived key wraps the data
  key. Changing the passphrase rewraps one key instead of re-encrypting
  every note.
- A printable recovery key, shown once at setup, also wraps the data key. Lose
  both the passphrase and the recovery key and the notes are unrecoverable.
  That is the point.
- Keys and OAuth tokens live in the OS keychain (Windows Credential Manager or
  DPAPI, Linux Secret Service), never in plain files.

## Threat model

GPad protects against:

- The storage provider, or anyone who gets into that account, reading notes.
- Someone with the synced files tampering with them undetected (authenticated
  encryption rejects modified files).
- Losing work to a crash, a closed window or an accidental tab close.

GPad does not protect against:

- Malware or another user with access to an unlocked machine running GPad.
- Someone who knows the passphrase or holds the recovery key.
- An employer's policy on putting work content in personal cloud storage.
  Check before relying on sync from a work machine.

## Release (step 4)

- Windows: a portable zip that runs without admin rights, then an installer.
  The zip carries the Visual C++ runtime DLLs next to `gpad.exe`, since
  many machines (including the first one we tried) don't have them.
  Unsigned builds show a SmartScreen warning on first run; code signing costs
  money and can come later.
- Linux: a .deb (installs to `/opt/gpad`, with a `gpad` command and a menu
  entry) and an AppImage (one file, runs on most distributions without
  installing). CI builds both with `linux/packaging/package.sh`. The tools
  that build the AppImage are pinned and checked against their SHA-256.
  CI builds them in an Ubuntu 22.04 container: a binary only runs on
  systems at least as new as the one it was built on (built on 24.04, it
  wouldn't start on 22.04 or Debian 12). `linux/packaging/smoke_test.sh`
  then installs and starts both packages in clean Ubuntu 22.04 and 24.04,
  Debian 12 and Fedora containers. Both use the system's GTK 3 and EGL.
  Flatpak can come later.
- GitHub Releases built by CI. No telemetry.

## Later

- Local AI naming, folder and group organizing, and search, run on the
  device (llama.cpp, or an existing Ollama install), so notes never leave it
  unencrypted.
- Experimental: an Obsidian-style mind map of notes, with the links between
  related notes found and kept up to date by the same local model.
- macOS and mobile apps.
- More sync backends, such as WebDAV or S3-compatible storage.
