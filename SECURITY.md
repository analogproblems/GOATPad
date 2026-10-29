# Security

## Reporting a problem

Please report security problems privately, not in a public issue. Use
**Report a vulnerability** on this repository's
[Security tab](https://github.com/analogproblems/GOATPad/security), which
sends the report to the maintainers only.

Say what you found, how to make it happen, and which GPad version and
system you saw it on. We'll reply as soon as we can, work on a fix with
you, and credit you in the release notes unless you'd rather not be named.

## Supported versions

GPad is before its first stable release, so fixes go into the latest
release only.

## What GPad protects

- **Synced notes** are encrypted on your computer before they go to Google
  Drive or a sync folder, with XChaCha20-Poly1305 and a key only your
  passphrase or recovery key opens (Argon2id). The storage provider sees
  only ciphertext, and a changed file is refused rather than read.
- **Google Drive access** is limited to the files GPad makes
  (`drive.file`). The sign-in is kept in the system keychain (the Secret
  Service on Linux, the Credential Manager on Windows), never in a plain
  file.
- **Notes on your computer** are not encrypted. On Linux their folder is
  private to your account (unless you moved it to a drive without Linux
  permissions, like a FAT USB stick); on Windows they live in your own
  local app data folder. Anyone who can use your unlocked account can read
  them.
- **Updates** install only if their manifest is signed with GPad's
  release key and each download matches it, size and SHA-256.
- **Nothing is sent anywhere** but your encrypted notes, to the place you
  chose, and requests for GitHub's public release files when GPad checks
  for updates. GPad has no telemetry.

The [threat model](docs/design.md#threat-model) says in more detail what
GPad does and doesn't protect against.

## In scope

- Reading or changing synced notes without the passphrase or recovery key.
- Getting at the Google sign-in or the sync key.
- Running code, or opening another program, through a note, a link, a
  paste or a sync file.
- Making GPad crash or lose notes with a file in the sync folder or Drive.
- Getting GPad to install an update that isn't a signed release, or an
  older one.
- A release download that isn't what this repository's CI built.

## Out of scope

- Someone using your unlocked computer account, or malware running as you.
- Someone who knows your passphrase or has your recovery key.
- Problems in your own Google sign-in client, if you set one up instead of
  GPad's.
