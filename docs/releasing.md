# Releasing GPad

CI builds every release from a version tag on `main` and drafts it on
GitHub. Nothing is public until a maintainer publishes the draft.

## Once: the signing key

GPad updates itself only to releases signed with its key (see
[Updates](design.md#updates-step-4)), so CI won't make a release without
it. Make the key once, on a computer you trust, with OpenSSL:

```sh
tool/make_update_key.sh
```

It writes the private key to `gpad-update-signing-key.pem`, which git
ignores, and the public key to `tool/update_public_key.pem`. It won't
replace a key that is already there. Then:

1. Add the private key as the repository secret `GPAD_UPDATE_SIGNING_KEY`
   (**Settings → Secrets and variables → Actions → New repository
   secret**), pasting the whole file, `BEGIN` and `END` lines included.
   Copying it straight to the clipboard is safest, since a selection can
   miss a line and a word processor or chat app can change dashes and
   spaces: `clip < gpad-update-signing-key.pem` on Windows (in Git Bash),
   `xclip -selection clipboard < gpad-update-signing-key.pem` or
   `wl-copy < gpad-update-signing-key.pem` on Linux. With the GitHub CLI,
   `gh secret set GPAD_UPDATE_SIGNING_KEY < gpad-update-signing-key.pem`
   sets it with no copying at all.
   If you have more than one key file, the right one is the file for which
   `openssl pkey -in <file> -pubout` prints `tool/update_public_key.pem`.
   A [dry run](#a-dry-run) checks the secret and says what's wrong with it.
2. Keep the file somewhere safe and private, like a password manager, and
   delete it from where you made it. Anyone with it, and the means to
   publish a release here, can sign updates GPad installs. Without it,
   builds already out can't update to the next release on their own.
3. Commit `tool/update_public_key.pem`. Builds from then on carry it, and
   update only to releases signed with its private key.

## Once: the Google sign-in client

Release builds sign in to Google Drive with GPad's own OAuth client, so
people don't have to make one. Create a **Desktop app** client as in
[Your own Google client](../README.md#your-own-google-client), published
to production, and add its ID and secret as the repository secrets
`GPAD_GOOGLE_CLIENT_ID` and `GPAD_GOOGLE_CLIENT_SECRET`. A tagged release
stops with an error without them, and a dry run warns. Google treats a
desktop app's secret as public, so it is no harm that it ships inside
GPad; it is a secret here only to keep it out of the repository and out of
forks' builds.

## Cutting a release

1. In a pull request, set the new version in `pubspec.yaml` (for example
   `version: 0.2.0+2`: the part before `+` is the version, the part after
   is the build number, one higher each release) and in
   `lib/src/version.dart` (a test checks the two match), and turn
   `## Unreleased` in [CHANGELOG.md](../CHANGELOG.md) into `## 0.2.0`
   (or add that section), saying what changed, for the people who use
   GPad.
2. Merge it once CI passes and it's reviewed.
3. Tag the merged commit on `main` and push the tag:

   ```sh
   git switch main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

4. CI builds and tests everything again, starts both Linux packages on
   each supported distribution, signs the update manifest, and then drafts
   the release **GPad 0.2.0** with the CHANGELOG section as its notes. It
   stops with an error if the tag doesn't match `pubspec.yaml`, has no
   CHANGELOG section or isn't on `main`, or if the signing key is missing
   or doesn't match `tool/update_public_key.pem`.
5. Open the draft under **Releases**, check the notes and downloads, and
   click **Publish release**. GPads that update themselves find it within
   twelve hours.

Until the draft is published, a release can be built again: delete the
draft, delete the tag (`git push --delete origin v0.2.0` and
`git tag -d v0.2.0`), then tag and push again. Once a release is public,
fix mistakes with a new version instead.

## A dry run

To try the whole release without making one, run CI by hand on a branch:
**Actions → CI → Run workflow**. It builds and tests everything as for a
release, then puts the release together as the `release-dry-run`
artifact, with the version from `pubspec.yaml`, instead of drafting it.
Before the signing key is set up, a dry run leaves `gpad-update.json`
unsigned and says so; a real release stops instead. Every pull request
also tests `tool/prepare_release.sh` with stand-in builds
(`tool/test_prepare_release.sh`).

## What a release holds

| File | For |
| --- | --- |
| `GPad-<version>-windows-x64-setup.exe` | Windows 10 and 11: the installer. Installs for the person running it, in `%LOCALAPPDATA%\Programs\GPad`, with no admin rights. IT can install for everyone in Program Files with `/ALLUSERS`; GPad can't update itself there, so it says when a new version is out. |
| `GPad-<version>-windows-x64.zip` | Windows 10 and 11, portable. Unzip anywhere and run `GPad\gpad.exe`. GPad installed with the installer updates itself from this too. |
| `gpad_<version>_amd64.deb` | Debian 12, Ubuntu 22.04 and newer: `sudo apt install ./gpad_<version>_amd64.deb` |
| `GPad-<version>-x86_64.AppImage` | Any other 64-bit Linux, like Fedora: make it executable and run it. |
| `gpad-update.json`, `gpad-update.json.sig` | What GPad's self-updates read: the version and each download's size and SHA-256, and CI's signature of it. |
| `SHA256SUMS` | The SHA-256 of each file. |

Release builds include GPad's own Google sign-in client, from the
`GPAD_GOOGLE_CLIENT_ID` and `GPAD_GOOGLE_CLIENT_SECRET` repository secrets,
so Google Drive sync works without setting up a client. They are built
without CI's caches, which any branch can fill.

## Checking a download

Each download's SHA-256 is in `SHA256SUMS`:

```sh
sha256sum --check --ignore-missing SHA256SUMS
```

On Windows, in PowerShell, compare the output of
`Get-FileHash GPad-<version>-windows-x64.zip` with the line in
`SHA256SUMS`.

CI also signs a build attestation for each download, which shows that
this repository's CI built it, from which commit. With the
[GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify GPad-<version>-x86_64.AppImage --repo jasondwhyte/GOATPad
```

GPad 0.1.0 was built before the repository moved here from
`analogproblems/GOATPad`, so its attestations name that repository: check
its downloads with `--repo analogproblems/GOATPad`.
