#!/bin/sh
# Gets a GitHub release ready from CI's builds. Checks that the tag names
# the version in pubspec.yaml and that CHANGELOG.md has notes for it, then
# puts the downloads and their SHA-256 sums in one folder.
#
#   tool/prepare_release.sh TAG BUILDS OUT NOTES
#
# TAG is the pushed tag, like v0.1.0. BUILDS holds CI's artifacts, one
# folder each: gpad-windows-x64, gpad-linux-deb and gpad-linux-appimage.
# The downloads and SHA256SUMS go in OUT, and the release notes in NOTES.
set -eu

[ $# -eq 4 ] || { echo "usage: $0 TAG BUILDS OUT NOTES" >&2; exit 2; }
tag=$1
builds=$(cd "$2" && pwd)
out=$3
notes=$4
root=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  echo "error: $*" >&2
  exit 1
}

version=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$root/pubspec.yaml")
[ -n "$version" ] || fail "no version in pubspec.yaml"
[ "$tag" = "v$version" ] ||
  fail "tag $tag doesn't match version $version in pubspec.yaml; tag v$version, or change the version first"

# The section under "## <version>", up to the next "## ".
awk -v v="$version" '
  /^## / { if (found) exit; if ($2 == v) { found = 1; next } }
  found
' "$root/CHANGELOG.md" >"$notes"
grep -q '[^[:space:]]' "$notes" || fail "CHANGELOG.md has no notes under \"## $version\""

windows="$builds/gpad-windows-x64"
deb="$builds/gpad-linux-deb/gpad_${version}_amd64.deb"
appimage="$builds/gpad-linux-appimage/GPad-${version}-x86_64.AppImage"
[ -f "$windows/gpad.exe" ] || fail "no gpad.exe in $windows"
[ -f "$deb" ] || fail "no $deb"
[ -f "$appimage" ] || fail "no $appimage"

rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)

# The Windows build unzips to one GPad folder, ready to run.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$windows" "$staging/GPad"
(cd "$staging" && zip -q -r -X "$out/GPad-${version}-windows-x64.zip" GPad)

cp "$deb" "$appimage" "$out/"
chmod +x "$out/GPad-${version}-x86_64.AppImage"
(cd "$out" && sha256sum -- * >SHA256SUMS)

echo "GPad $version is ready in $out:"
ls -l "$out"
