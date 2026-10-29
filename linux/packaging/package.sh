#!/usr/bin/env bash
# Packages the Flutter Linux release bundle as a .deb and an AppImage.
#
# Usage: linux/packaging/package.sh [out_dir]
# Run from the repository root after `flutter build linux --release`.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
packaging="$root/linux/packaging"
bundle="$root/build/linux/x64/release/bundle"
out="$(mkdir -p "${1:-$root/dist}" && cd "${1:-$root/dist}" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# appimagetool and the AppImage runtime are downloaded at pinned versions and
# checked against their SHA-256, so a changed upstream file can't slip into a
# release. (Left alone, appimagetool fetches the latest runtime.)
appimagetool_version=1.9.1
appimagetool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_version=20251108
runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

[[ -x "$bundle/gpad" ]] || {
  echo "No release bundle at $bundle. Run: flutter build linux --release" >&2
  exit 1
}

# 0.1.0+1 in pubspec.yaml -> 0.1.0
version="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$root/pubspec.yaml")"

# fetch <file> <sha256> <url>: download and verify, or stop the build.
fetch() {
  curl -fsSL -o "$1" "$3"
  echo "$2  $1" | sha256sum --check --quiet
}

build_deb() {
  local pkg="$work/deb"
  mkdir -p "$pkg/DEBIAN" "$pkg/opt" "$pkg/usr/bin" \
    "$pkg/usr/share/applications" \
    "$pkg/usr/share/icons/hicolor/256x256/apps" \
    "$pkg/usr/share/icons/hicolor/scalable/apps"

  cp -r "$bundle" "$pkg/opt/gpad"
  ln -s /opt/gpad/gpad "$pkg/usr/bin/gpad"
  install -m 644 "$packaging/gpad.desktop" "$pkg/usr/share/applications/gpad.desktop"
  install -m 644 "$packaging/gpad.png" "$pkg/usr/share/icons/hicolor/256x256/apps/gpad.png"
  install -m 644 "$packaging/gpad.svg" "$pkg/usr/share/icons/hicolor/scalable/apps/gpad.svg"

  local size
  size="$(du -sk "$pkg" | cut -f1)"
  cat > "$pkg/DEBIAN/control" <<CONTROL
Package: gpad
Version: $version
Architecture: amd64
Maintainer: GOATPad contributors <https://github.com/analogproblems/GOATPad>
Installed-Size: $size
Depends: libgtk-3-0t64 | libgtk-3-0, libegl1, libgles2, libepoxy0, libstdc++6, libc6 (>= 2.34)
Recommends: libsecret-1-0
Section: editors
Priority: optional
Homepage: https://github.com/analogproblems/GOATPad
Description: Notepad that keeps everything you paste
 GPad is a fast, Sublime-style notepad. Each note picks Rich, Code or Plain
 mode from what you paste, and closing a tab never throws a note away.
CONTROL

  dpkg-deb --root-owner-group --build "$pkg" "$out/gpad_${version}_amd64.deb"
}

build_appimage() {
  local appdir="$work/GPad.AppDir"
  mkdir -p "$appdir"
  cp -r "$bundle" "$appdir/gpad"
  cp "$packaging/gpad.desktop" "$packaging/gpad.png" "$appdir/"
  ln -s gpad.png "$appdir/.DirIcon"
  cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/gpad/gpad" "$@"
APPRUN
  chmod +x "$appdir/AppRun"

  local tool="$work/appimagetool" runtime="$work/runtime-x86_64"
  fetch "$tool" "$appimagetool_sha256" \
    "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_version/appimagetool-x86_64.AppImage"
  fetch "$runtime" "$runtime_sha256" \
    "https://github.com/AppImage/type2-runtime/releases/download/$runtime_version/runtime-x86_64"
  chmod +x "$tool"

  # Extract-and-run avoids needing FUSE on the build machine.
  ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream \
    --runtime-file "$runtime" "$appdir" "$out/GPad-${version}-x86_64.AppImage"
}

build_deb
build_appimage
ls -l "$out"
