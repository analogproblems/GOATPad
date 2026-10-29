#!/bin/sh
# Gets a GitHub release ready from CI's builds. Checks that the tag names
# the version in pubspec.yaml and that CHANGELOG.md has notes for it, then
# puts in one folder the downloads, the manifest GPad's self-updates read
# (gpad-update.json) with its signature, and everything's SHA-256 sums.
#
#   GPAD_UPDATE_SIGNING_KEY=... tool/prepare_release.sh TAG BUILDS OUT NOTES
#
# TAG is the pushed tag, like v0.1.0. BUILDS holds CI's artifacts, one
# folder each: gpad-windows-x64, gpad-linux-deb and gpad-linux-appimage.
# The release's files go in OUT, and its notes in NOTES. The signing key is
# the private key tool/make_update_key.sh made, as PEM text; it must match
# tool/update_public_key.pem, which GPad builds check updates with.
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

# What GPad's self-updates take from a release: its version, and each
# download's size and SHA-256.
entry() {
  printf '"%s":{"name":"%s","size":%s,"sha256":"%s"}' "$1" "$(basename "$2")" \
    "$(wc -c <"$2" | tr -d ' ')" "$(sha256sum "$2" | cut -d ' ' -f 1)"
}
manifest="$out/gpad-update.json"
{
  printf '{"gpad-update":1,"version":"%s","files":{' "$version"
  entry windows-x64-zip "$out/GPad-${version}-windows-x64.zip"
  printf ','
  entry linux-x64-appimage "$out/GPad-${version}-x86_64.AppImage"
  printf ','
  entry linux-x64-deb "$out/gpad_${version}_amd64.deb"
  printf '}}'
} >"$manifest"

# Signed, or GPad won't install it. Checked against the public key builds
# carry, so a release never goes out that they would refuse. A dry run
# (DRY_RUN=true) before the key is made goes on unsigned.
public="$root/tool/update_public_key.pem"
if [ "${DRY_RUN:-false}" = true ] &&
  { [ ! -f "$public" ] || [ -z "${GPAD_UPDATE_SIGNING_KEY:-}" ]; }; then
  echo "warning: no signing key yet, so gpad-update.json is unsigned" >&2
else
  [ -f "$public" ] || fail "no tool/update_public_key.pem; see docs/releasing.md"
  [ -n "${GPAD_UPDATE_SIGNING_KEY:-}" ] ||
    fail "GPAD_UPDATE_SIGNING_KEY isn't set; see docs/releasing.md"
  printf '%s\n' "$GPAD_UPDATE_SIGNING_KEY" >"$staging/key.pem"
  openssl pkeyutl -sign -inkey "$staging/key.pem" -rawin -in "$manifest" \
    -out "$staging/signature"
  openssl pkeyutl -verify -pubin -inkey "$public" -rawin -in "$manifest" \
    -sigfile "$staging/signature" >/dev/null ||
    fail "GPAD_UPDATE_SIGNING_KEY doesn't match tool/update_public_key.pem"
  base64 -w 0 "$staging/signature" >"$manifest.sig"
fi

(cd "$out" && sha256sum -- * >SHA256SUMS)

echo "GPad $version is ready in $out:"
ls -l "$out"
