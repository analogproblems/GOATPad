# GPad

GPad (built in this GOATPad repository: the greatest notepad of all time) is a
fast, Sublime-style notepad that keeps everything you paste and syncs it
between your computers, end-to-end encrypted, through storage you already
have.

Paste something on your Windows work machine, close the window, and find it
waiting in a tab on your Linux machine at home.

![The editor lab: a pasted SQL query detected as Code and named from its comment](docs/images/editor-lab.png)

## Status

Early. This is the **step 1 editor lab**: tabs, smart note modes and inline
naming, with Quill as the rich-text editor (picked over Fleather in the lab).
Nothing is saved yet.

| Step | What it delivers | State |
| --- | --- | --- |
| 1. Foundations | Flutter app for Windows and Linux, CI, design note, editor lab | In progress |
| 2. Local notepad | Autosave, session restore, folders and tab groups, search, saved settings | Next |
| 3. Encrypted sync | Google Drive and sync-folder backends, end-to-end encryption | Planned |
| 4. Release | Packaging and GitHub Releases | Planned |

See [docs/design.md](docs/design.md) for how it is meant to work and why.

## What makes it different

- **Smart modes.** Each note is Rich (Markdown underneath), Code (syntax
  highlighted) or Plain, picked automatically from what you first paste and
  changeable with one click.
- **Nothing lost.** No save prompts. Closing a tab keeps the note, marked
  closed, so tabs stay tidy without throwing anything away.
- **Private sync.** Notes are encrypted on your device before they reach
  Google Drive or your sync folder. There is no GPad server.
- **Your look.** Warm, Classic or Slate themes, each in light and dark, and
  code colors you can switch to a colorblind-safe or high-contrast scheme.

## Try the editor lab

1. Switch the welcome note to **Code** in the status bar to see its Markdown,
   then back to **Rich**.
2. Press Ctrl+N and paste code, JSON, an email or a Markdown list. Watch the
   mode and the suggested name change.
3. Close a tab with Ctrl+W and reopen it from the sidebar.
4. Open **Appearance** (the palette button) to try the themes and code
   colors.

Windows and Linux builds from CI are attached to each run under
**Actions → CI → Artifacts**.

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or
later.

On Linux, also install the desktop build tools:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev
```

Then:

```sh
flutter pub get
flutter test
flutter run -d linux     # or: flutter run -d windows
```

## License

[MIT](LICENSE)
