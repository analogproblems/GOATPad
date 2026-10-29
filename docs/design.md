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
| Pasted HTML | [html](https://pub.dev/packages/html), and [quill_native_bridge](https://pub.dev/packages/quill_native_bridge) on Windows | Reads formatting copied from a browser, Word or Google Docs. See "Rich notes and Markdown". |

### Rich editor choice

**flutter_quill**, picked over fleather in the step 1 editor lab for its
nicer UI. It is also the most used and most actively released. Quill stores
its own Delta format, so Markdown is converted on the way in and out (see
"Rich notes and Markdown" below).

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

1. Parses as JSON, or is an XML document: Code.
2. The clipboard also held HTML with formatting (headings, lists, quotes,
   emphasis, links, images or tables), as text copied from a web page, Word,
   Google Docs or LibreOffice does: Rich, holding that formatting as
   Markdown. HTML that only colors code, as VS Code and many web pages put
   on the clipboard, doesn't count, so copied code still becomes Code.
3. Two or more kinds of Markdown syntax (headings, lists, links, fences,
   bold, quotes, tasks): Rich.
4. `highlightAuto` over ~20 common languages scores at least 3 and the text
   does not read as prose: Code in that language. Diff only counts when
   there is a hunk or file header (`@@`, `---`, `+++`), because
   highlight.js scores any list of `- ` lines as a diff.
5. One kind of Markdown syntax, and Markdown is the best language guess:
   Rich. That catches a short list with a title line above it.
6. Otherwise: Plain.

Language detection scans only the first 8,000 characters, and exact JSON
parsing is skipped above 1 MB in favor of checking how the text opens and
closes, so a huge paste stays instant.
The mode shows in the status bar and one click changes it.

`suggestName` (`lib/src/notes/name_suggester.dart`) fills an editable title
field with no popup: the first line for prose and Markdown, a leading comment
for code, or "SQL snippet 14:03" as a fallback.

Naming, organizing and search sit behind small functions so a local AI model
can take them over later without a rewrite.

## Rich notes and Markdown

`RichMarkdown` (`lib/src/notes/rich_markdown.dart`) converts between a Rich
note's Markdown and the Delta Quill edits.

- **Reading** uses markdown_quill's parser, taught three things it didn't
  do: images keep their alt text and title, GitHub-style tables are kept
  whole (shown as a read-only table; switching the note to Plain edits the
  Markdown), and `####` to `######` headings stay headings.
- **Writing** is GPad's own, because markdown_quill's writer escaped nearly
  all punctuation (`saved as you go\.`), dropped alt text and tables, lost
  code block languages, and wrote a paragraph straight after a quote, which
  Markdown then reads as part of the quote. The writer:
  - escapes a character only where it would otherwise be read as Markdown
    (`# ` at the start of a line, `*` and `_` that could open emphasis, `[`,
    a backtick, `&amp;`-style entities), so `snake_case`, `C#`, `x < y` and
    `2 * 3` stay as typed;
  - separates blocks with a blank line, and keeps list items, quote lines
    and code lines together;
  - writes a link whose text is its own address as the bare address;
  - moves spaces out of bold and italic (`**word **` doesn't parse), and
    where a marker would touch punctuation in a way Markdown can't read
    (`**Note:**Next`), moves that punctuation out of the bold. Lines where a
    marker touches punctuation are parsed back as a check, and if one still
    reads differently it is written without emphasis: formatting can be
    lost that way, never text;
  - writes a table or rule as a paragraph of its own even when Quill has
    let a heading, list, quote or code format onto its line, so only that
    format is lost, never the table.
- Formatting Markdown has no syntax for (underline, colors, fonts) is not
  kept. The welcome note and 3,000 random lines of punctuation are tested to
  read back as the same text.

### Pasting from a web page or Word

Flutter's clipboard API only reads plain text. GPad reads the clipboard's
HTML itself: on Linux through a small GTK method channel in the runner
(`linux/runner/clipboard_html.cc`, `text/html`, UTF-8 or UTF-16), on Windows
through quill_native_bridge's `CF_HTML` reader, which flutter_quill already
depends on.

`markdownFromHtml` (`lib/src/notes/html_markdown.dart`) turns that HTML into
Markdown:

- Headings, paragraphs, lists (nested, and task lists), quotes, code blocks
  (with their language when the page names it), rules, links, images, bold,
  italic, strikethrough and inline code. Bold and italic come from tags or
  from inline styles, which is how Google Docs marks them (it also wraps
  everything in a `<b>` styled as not bold).
- Word writes lists as paragraphs styled `mso-list`; those become lists,
  and the bullet characters Word adds are dropped.
- A table of short cells becomes a Markdown table, as from a spreadsheet.
  Its caption goes just above it. A cell spanning several columns or rows
  keeps its text in the first and leaves the rest empty, so the other
  cells stay in their columns. A table used for layout, with paragraphs or
  other tables in its cells, as in most emails, is read as the paragraphs
  it holds.
- Tables adding up to more than 5,000 cells, counting the empty ones that
  spans leave, make the whole paste plain text. Spans can turn a small copy
  into millions of cells, and a table that big is easier to work with as
  the tab-separated text spreadsheets also copy.
- Hidden elements, scripts, styles, forms and tracking pixels are dropped.
  Links keep only `http`, `https`, `mailto`, `ftp` and `tel` addresses, and
  images only web addresses, so no `javascript:` link or local file comes
  along. Images are shown as their alt text and address and never fetched.
- HTML with nothing Markdown can say (only colors and fonts, or only a code
  block) returns null, and the paste goes in as plain text. Clipboard HTML
  over 4 MB is ignored the same way.

Where HTML is used:

- **Ctrl+Shift+V** and the first paste into a new note make a Rich note of
  it (see the mode order above).
- Pasting into a Rich note converts it the same way, so what shows is
  exactly what is saved.
- Pasting into Code and Plain notes, and any later paste into a note that
  isn't Rich, uses the plain text.

## Tabs, closing and deleting

- Open tabs are part of synced state, so a note opened at work shows as a tab
  at home.
- Closing a tab never deletes. The note stays in its folder marked closed and
  reopens with a click.
- Deleting is a separate, deliberate action that moves the note to a trash
  kept for 30 days. Sync spreads deletes to every machine, so the trash is the
  safety net.
- Tab groups always mirror folders. There are no ad hoc groups in v1.

## Folders and tab groups

- Folders nest. The sidebar shows them as a tree, folders first and then
  notes, each sorted by name, with closed notes marked "Closed".
- Every folder with open notes is a tab group. The strip shows the groups in
  sidebar order, each starting with a label carrying the folder's name, and
  tabs that aren't in a folder come last.
- Each folder gets a color from the Okabe-Ito palette, picked from its id so
  it never changes. The label, the line under its tabs and its sidebar icon
  share that color. The name is always shown too, so nothing depends on
  telling colors apart. Colors are lightened on dark themes.
- Clicking a label folds the group's tabs away and shows how many it holds.
  The selected tab always stays visible, and Ctrl+Tab skips folded tabs.
- New notes (Ctrl+N, paste as new note) go in the same folder as the tab
  you are on. "New note here" on a folder's menu puts one in that folder.
- Notes move by dragging them onto a folder, onto a group label, or onto the
  NOTES heading (for the top level), or with "Move to folder…" on their
  menu. Folders move by dragging, and never into themselves.
- New folders are named in place. Enter or clicking away keeps the name;
  Escape keeps the old one.
- Deleting a folder never deletes notes. Everything in it, trashed notes
  included, moves up to the folder it was in, and GPad asks first unless the
  folder is empty.

## Search

Ctrl+P (or Ctrl+Shift+F, or the magnifier in the sidebar) opens a search box
over the editor that searches every note as you type: open, closed and
trashed. Each result shows its title and the text around the match, with
the matches in bold on a tint, and the note's folder and whether it is
closed or in the trash. Up and Down pick a result, Enter opens it (a
trashed note is restored), and Escape closes the box. With nothing typed it
lists the notes edited most recently, so it doubles as a quick switcher.

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
  trash, theme) is saved straight away, the selected tab with the next save,
  and GPad saves again whenever the window loses focus or closes. Nothing
  ever asks "save?".
- **Crash-safe.** The database uses SQLite's write-ahead log with
  `synchronous = FULL`, so every finished save is on disk before GPad moves
  on. A crash or power cut can cost at most the last few hundred
  milliseconds of typing, never a finished save and never the file. Each
  save is one transaction, so it lands whole or not at all.
- **If saving fails** (a full disk, a failing drive), the changes stay in
  memory, a warning stays at the top of the window until a save works, and
  GPad tries again every 5 seconds without waiting for more typing. "Try
  again" retries at once. Closing the window while saves are failing asks
  first, with "Keep GPad open" as the default.
- **One window at a time.** GPad keeps the file locked while it runs. A
  second GPad shows "GPad is already open" instead of loading the notes and
  overwriting edits made in the first window. A crashed GPad releases the
  lock.
- **Schema.** `notes` (random 128-bit id, folder, title, body, mode,
  language, status open/closed/trashed, tab order, timestamps), `folders`
  (random id, parent, name, whether it is expanded in the sidebar and folded
  in the tab strip), `settings` (theme, selected tab, sync settings) and
  `sync_records` (what sync has uploaded; see Sync). The version lives
  in `PRAGMA user_version` (4 since sync); older databases are upgraded
  in place and a database from a newer GPad is refused rather than changed.
  Random ids mean notes and folders made on two machines never clash once
  sync arrives. A note or folder whose folder is missing loads at the top
  level, so nothing can go missing from the sidebar.
- **Trash.** Trashed notes are kept for 30 days and deleted the next time
  GPad starts after that. "Delete forever" and "Empty trash" ask first.
- **Search.** An FTS5 index over titles and text, using the trigram
  tokenizer so any part of a word matches, in any language and in code,
  ignoring case and accents. Triggers keep it in step with `notes`, and
  upgrading an older database builds it once. Every word of a query must
  match. Words shorter than three characters, which trigrams can't index,
  are matched by a plain scan that folds case and accents the same way as
  the index (`foldForSearch` in `lib/src/store/search_fold.dart`, which a
  test checks against SQLite letter by letter). Kept notes come before
  trashed ones, then notes whose title matches, then the rest by BM25.
  That order is applied before the 50-result limit, so trashed notes can't
  crowd a kept one out.

## Sync (step 3)

Sync goes through a small `SyncBackend` interface (list, read, write and
delete files, plus an optional change stream), so the engine above it
doesn't care where the files live. Step 3 ships it in three parts:

1. **Sync folder (built).** Encrypted files in any folder that a tool like
   Dropbox, OneDrive, Nextcloud or Syncthing keeps in step, or on a network
   drive. GPad writes into a `GPad` folder inside the one you choose (or
   straight into it if it already holds a vault or is called `GPad`).
2. **Google Drive, direct.** Linux has no official Drive desktop app, so
   GPad will talk to the Drive API itself. It asks only for the `drive.file`
   scope, which lets it see files it created and nothing else. Full Drive
   access is a restricted scope that needs a paid Google security assessment
   for public apps. Release builds will get GPad's OAuth client ID from CI
   secrets, and anyone will be able to use their own.
3. **Later in step 3:** changing the passphrase, making a new recovery key,
   and syncing from the tray while the window is closed.

### What syncs

Notes (title, text, mode, language, open, closed or trashed, tab order,
folder, timestamps) and folders (name, parent, timestamps). Which tab is
selected, whether a folder is expanded, the theme and the window stay on
each computer. So does the welcome note until you edit it, so each machine
doesn't collect a copy of everyone's.

### Files

```
GPad/
  gpad-vault.json        public header: vault id, Argon2id salt and
                         settings, and the wrapped note key
  records/<id>.gpad      one encrypted file per note or folder
```

- **One file per note or folder,** named by its random id, so titles never
  leak through file names and two machines editing different notes never
  touch the same file. Writes go to a temporary file that is then renamed,
  so a sync tool never uploads half a file. Setting a folder up takes a
  lock file first (an exclusive create), so of two computers setting up
  one shared folder at once, only one can win; a lock left behind by a
  GPad that stopped mid-setup can be taken over after 10 minutes.
- **A record** is JSON inside the encryption: kind, id, a version vector,
  the device that saved it and its name, when, and the data (or nothing,
  for a delete, which is kept so other machines learn about it).
- **Version vectors** (a count per device) tell GPad whether the copy in
  the folder is the same as what it last saw, older, newer, or changed on
  two machines at once. Clocks are only used to break ties between fields.

### How a round works

Each round lists the folder, skips files whose size and modification time
are unchanged since last time, and opens the rest:

- **Newer, and nothing changed here:** taken as it is.
- **Newer, and changed here too, or changed on two machines at once:** a
  three-way merge against the last version both sides had. Fields are
  merged one by one: a field changed on one side takes that side, and a
  field changed on both takes the newer change. When both machines changed
  the text, the text here stays and the other machine's text becomes a new
  note, "Title (conflict from Home PC)". GPad never picks a winner for text
  silently. An edit beats a delete, so a note edited on one machine while
  it was deleted forever on another comes back.
- **Older than what this machine has, or missing:** uploaded again, so a
  rolled-back or deleted file is put right by any machine that knows better.
- **Copies made by the sync tool** (Dropbox's "conflicted copy", Syncthing's
  `.sync-conflict-`) are merged in like any other version, then deleted:
  first renamed to a copy name of GPad's own, then deleted only if it is
  still the version that was read. A copy that changed, or one GPad
  stopped before deleting, is read again next round.
- **A file that can't be opened** (damaged, changed by something else, or
  saved by a newer GPad) is left alone and reported in the sync dialog. It
  is tried again only once it changes. Changes here to that note wait
  rather than replace a version this GPad can't read.

Then everything changed here goes up. A table in `notes.db`
(`sync_records`), kept current by triggers, counts each note's and folder's
changes, so a change made while a round is uploading is never mistaken for
uploaded, and changes waiting when GPad quits are still waiting when it
starts. Notes merged in a round are saved in the same transaction as what
sync then knows about them; if that fails, the merge is undone in the
window too, and the next round merges again. A file's tag (its size and
modification time) is taken before it is renamed into place, so a file
another computer writes there a moment later is still read.

A note whose folder hasn't arrived yet shows at the top level and moves into
the folder once it does. A folder loop (two machines moving folders into each
other at once) is broken at the same folder on every machine.

### Timing

Changes go up 3 seconds after typing stops, or after 20 seconds of
non-stop typing. GPad also syncs when the sync folder changes, every minute,
when the window comes back into focus, and once more before it quits (giving
up after 5 seconds, since the changes are kept for next time). Turning
sync off, or setting it up again, stops a round under way once the file it
is reading or writing is done, before it uses the key or records anything.

Before each round, GPad checks that `gpad-vault.json` is still there and is
the same vault. If the folder is missing (a USB drive that isn't plugged in,
a sync tool that hasn't started), sync shows a problem and writes nothing,
rather than starting a new vault or reading the empty folder as "everything
was deleted".

## Encryption (step 3)

- Everything is encrypted on the device before it is written to the sync
  folder. The folder, and whoever stores it, only ever holds ciphertext.
- [libsodium](https://doc.libsodium.org/) 1.0.22, through the
  [sodium](https://pub.dev/packages/sodium) package, which builds it from
  its signed source release with the app; no homemade crypto.
- **A random 256-bit note key** encrypts every record with
  XChaCha20-Poly1305. Each file has a fresh random nonce, and the vault id
  and record id are bound in as associated data, so a file can't be passed
  off as another note or moved between vaults. Contents are padded (Padmé,
  at least 256 bytes), so file sizes only hint at how long a note is.
- **The passphrase** (at least 10 characters) goes through Argon2id
  (libsodium's "moderate": 3 passes over 256 MiB, run off the UI thread)
  to a key that wraps the note key. Changing the passphrase rewraps one key
  instead of re-encrypting every note.
- **A recovery key,** 160 random bits shown once at setup as 32 characters
  (Crockford base32, so 0/O and 1/I/L can't be mixed up), also wraps the note
  key. GPad offers to copy it or save it to a file, and the setup dialog
  stays open until you tick that it is saved. Lose both the passphrase and the recovery key
  and the notes are unrecoverable. That is the point.
- **Remembering the passphrase** keeps the note key (not the passphrase) in
  the system keychain: Secret Service (GNOME Keyring, KWallet) on Linux,
  Credential Manager on Windows, through their own C APIs. Without a
  keychain, or if you untick "Remember", GPad asks for the passphrase each
  time it starts and keeps your notes local until you type it.

## Threat model

GPad protects against:

- The storage provider, or anyone who gets into that account, reading notes.
- Someone with the synced files tampering with them undetected (authenticated
  encryption rejects modified files).
- Losing work to a crash, a closed window or an accidental tab close.

GPad does not protect against:

- Malware or another user with access to an unlocked machine running GPad.
- Someone who knows the passphrase or holds the recovery key.
- Someone with the synced files learning how many notes and folders there
  are, roughly how long they are, and when they change.
- Someone with write access to the synced files deleting them or putting
  back older copies. Machines that have seen newer versions put them right,
  but a computer joining for the first time could see the older copy until
  one of them syncs.
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
