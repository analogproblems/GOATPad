# Releasing GPad

CI builds every release from a version tag on `main` and drafts it on
GitHub. Nothing is public until a maintainer publishes the draft.

## Cutting a release

1. In a pull request, set the new version in `pubspec.yaml` (for example
   `version: 0.2.0+2`: the part before `+` is the version, the part after
   is the build number, one higher each release) and add a `## 0.2.0`
   section to [CHANGELOG.md](../CHANGELOG.md) saying what changed, for the
   people who use GPad.
2. Merge it once CI passes and it's reviewed.
3. Tag the merged commit on `main` and push the tag:

   ```sh
   git switch main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

4. CI builds and tests everything again, starts both Linux packages on
   each supported distribution, and then drafts the release **GPad 0.2.0**
   with the CHANGELOG section as its notes. It stops with an error if the
   tag doesn't match `pubspec.yaml`, has no CHANGELOG section, or isn't on
   `main`.
5. Open the draft under **Releases**, check the notes and downloads, and
   click **Publish release**.

Until the draft is published, a release can be built again: delete the
draft, delete the tag (`git push --delete origin v0.2.0` and
`git tag -d v0.2.0`), then tag and push again. Once a release is public,
fix mistakes with a new version instead.

## What a release holds

| File | For |
| --- | --- |
| `GPad-<version>-windows-x64.zip` | Windows 10 and 11. Unzip anywhere and run `GPad\gpad.exe`; no installer or admin rights needed. |
| `gpad_<version>_amd64.deb` | Debian 12, Ubuntu 22.04 and newer: `sudo apt install ./gpad_<version>_amd64.deb` |
| `GPad-<version>-x86_64.AppImage` | Any other 64-bit Linux, like Fedora: make it executable and run it. |
| `SHA256SUMS` | The SHA-256 of each download. |

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
gh attestation verify GPad-<version>-x86_64.AppImage --repo analogproblems/GOATPad
```
