# GOATPad

The greatest notepad of all time: a fast, warm, Sublime-style notepad that
keeps everything you paste and syncs it between your computers, end-to-end
encrypted, through storage you already have.

Paste something on your Windows work machine, close the window, and find it
waiting in a tab on your Linux machine at home.

![The editor lab: a pasted SQL query detected as Code and named from its comment](docs/images/editor-lab.png)

## Status

Early. This is the **step 1 editor lab**: tabs, smart note modes, inline
naming, and two rich-text editors side by side so we can pick one by feel.
Nothing is saved yet.

| Step | What it delivers | State |
| --- | --- | --- |
| 1. Foundations | Flutter app for Windows and Linux, CI, design note, editor lab | In progress |
| 2. Local notepad | Autosave, session restore, folders and tab groups, search, themes | Next |
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
  Google Drive or your sync folder. There is no GOATPad server.

## Try the editor lab

1. Flip **Rich editor** in the status bar between Quill and Fleather.
2. Press Ctrl+N and paste code, JSON, an email or a Markdown list. Watch the
   mode and the suggested name change.
3. Close a tab with Ctrl+W and reopen it from the sidebar.

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
