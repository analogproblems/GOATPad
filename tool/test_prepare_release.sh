#!/bin/sh
# Tests tool/prepare_release.sh with stand-in builds, since only a tagged
# release or a dry run gets to run it in CI otherwise:
#
#   tool/test_prepare_release.sh
#
# Each case runs a copy of the script in a scratch folder, with its own
# pubspec.yaml, CHANGELOG.md and throwaway signing key.
set -eu
export LC_ALL=C

script="$(cd "$(dirname "$0")" && pwd)/prepare_release.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# A fresh repository copy for version $1, with notes unless $2 is "none",
# and builds for that version. Each case signs with $signing, the right
# key unless it changes it, and isn't a dry run unless it sets $dry.
setup() {
  signing=$key
  dry=false
  rm -rf "$work/repo" "$work/builds" "$work/out" "$work/notes.md"
  mkdir -p "$work/repo/tool"
  cp "$script" "$work/repo/tool/"
  printf 'name: goatpad\nversion: %s+1\n' "$1" >"$work/repo/pubspec.yaml"
  {
    echo '# Changelog'
    echo
    if [ "${2:-}" != none ]; then
      echo "## $1"
      echo
      echo "- What's new in $1."
      echo
    fi
    echo '## 0.0.1'
    echo
    echo '- Something older.'
  } >"$work/repo/CHANGELOG.md"
  cp "$work/public.pem" "$work/repo/tool/update_public_key.pem"

  mkdir -p "$work/builds/gpad-windows-x64/data" \
    "$work/builds/gpad-linux-deb" "$work/builds/gpad-linux-appimage"
  echo exe >"$work/builds/gpad-windows-x64/gpad.exe"
  echo app >"$work/builds/gpad-windows-x64/data/app.so"
  echo deb >"$work/builds/gpad-linux-deb/gpad_$1_amd64.deb"
  echo appimage >"$work/builds/gpad-linux-appimage/GPad-$1-x86_64.AppImage"
}

# Runs the copy with tag $1, its output in $work/log.
prepare() {
  (cd "$work" && DRY_RUN=$dry GPAD_UPDATE_SIGNING_KEY=$signing \
    repo/tool/prepare_release.sh "$1" builds out notes.md) >"$work/log" 2>&1
}

# Expects prepare to fail for tag $1, saying $2.
refuses() {
  if prepare "$1"; then
    fail "$3: succeeded"
  elif ! grep -q "$2" "$work/log"; then
    fail "$3: didn't say \"$2\": $(cat "$work/log")"
  fi
}

openssl genpkey -algorithm ed25519 -out "$work/private.pem" 2>/dev/null
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem"
openssl genpkey -algorithm ed25519 -out "$work/other.pem" 2>/dev/null
key=$(cat "$work/private.pem")

# A release, signed.
setup 1.2.3
if prepare v1.2.3; then
  out="$work/out"
  expected="GPad-1.2.3-windows-x64.zip GPad-1.2.3-x86_64.AppImage SHA256SUMS gpad-update.json gpad-update.json.sig gpad_1.2.3_amd64.deb"
  [ "$(cd "$out" && echo *)" = "$expected" ] ||
    fail "release holds $(cd "$out" && echo *)"
  [ "$(unzip -Z1 "$out/GPad-1.2.3-windows-x64.zip" | sort | tr '\n' ' ')" = \
    "GPad/ GPad/data/ GPad/data/app.so GPad/gpad.exe " ] ||
    fail "zip holds $(unzip -Z1 "$out/GPad-1.2.3-windows-x64.zip" | tr '\n' ' ')"
  [ -x "$out/GPad-1.2.3-x86_64.AppImage" ] || fail "AppImage isn't executable"
  (cd "$out" && sha256sum --check --quiet SHA256SUMS) || fail "SHA256SUMS"
  grep -q "What's new in 1.2.3" "$work/notes.md" &&
    ! grep -q 'Something older' "$work/notes.md" ||
    fail "notes are $(cat "$work/notes.md")"

  manifest="$out/gpad-update.json"
  for kind in windows-x64-zip:GPad-1.2.3-windows-x64.zip \
    linux-x64-appimage:GPad-1.2.3-x86_64.AppImage \
    linux-x64-deb:gpad_1.2.3_amd64.deb; do
    name=${kind#*:}
    want="$name $(wc -c <"$out/$name" | tr -d ' ') $(sha256sum "$out/$name" | cut -d ' ' -f 1)"
    got=$(jq -r --arg k "${kind%%:*}" \
      '.files[$k] | "\(.name) \(.size) \(.sha256)"' "$manifest")
    [ "$got" = "$want" ] || fail "manifest has $got for ${kind%%:*}"
  done
  [ "$(jq -r '"\(."gpad-update") \(.version)"' "$manifest")" = "1 1.2.3" ] ||
    fail "manifest is $(cat "$manifest")"
  base64 -d "$manifest.sig" >"$work/signature"
  openssl pkeyutl -verify -pubin -inkey "$work/public.pem" -rawin \
    -in "$manifest" -sigfile "$work/signature" >/dev/null ||
    fail "signature doesn't verify"
else
  fail "release: $(cat "$work/log")"
fi

# What stops a release.
setup 1.2.3
refuses v1.2.4 "doesn't match version 1.2.3" "tag mismatch"
setup 1.2.3 none
refuses v1.2.3 'no notes under "## 1.2.3"' \
  "no notes"
setup 1.2.3
rm "$work/builds/gpad-linux-deb/gpad_1.2.3_amd64.deb"
refuses v1.2.3 'gpad_1.2.3_amd64.deb' "no .deb"
setup 1.2.3
rm "$work/builds/gpad-linux-appimage/GPad-1.2.3-x86_64.AppImage"
refuses v1.2.3 'x86_64.AppImage' "no AppImage"
setup 1.2.3
rm "$work/builds/gpad-windows-x64/gpad.exe"
refuses v1.2.3 'no gpad.exe' "no gpad.exe"
setup 1.2.3
signing=
refuses v1.2.3 "GPAD_UPDATE_SIGNING_KEY isn't set" "no signing key"
setup 1.2.3
rm "$work/repo/tool/update_public_key.pem"
refuses v1.2.3 'no tool/update_public_key.pem' \
  "no public key"
setup 1.2.3
signing=$(cat "$work/other.pem")
refuses v1.2.3 "doesn't match tool/update_public_key.pem" "another key"

# A dry run before the key is made goes on, unsigned; with the wrong key,
# it stops as a release would.
setup 1.2.3
dry=true
signing=
if prepare v1.2.3; then
  [ -f "$work/out/gpad-update.json" ] || fail "dry run has no manifest"
  [ ! -e "$work/out/gpad-update.json.sig" ] || fail "dry run is signed"
  grep -q unsigned "$work/log" || fail "dry run doesn't say it's unsigned"
else
  fail "dry run: $(cat "$work/log")"
fi
setup 1.2.3
dry=true
signing=$(cat "$work/other.pem")
refuses v1.2.3 "doesn't match" "dry run with another key"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed" >&2
  exit 1
fi
echo "prepare_release.sh: all cases pass"
