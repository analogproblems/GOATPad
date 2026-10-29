#!/bin/sh
# Checks that GPad's Linux packages install and start on a fresh distribution.
# CI runs it as root in a clean container for each distribution we support.
#
# Usage: linux/packaging/smoke_test.sh <dir holding the .deb and/or .AppImage>
#
# A package passes if the app is still running on a virtual display when
# `timeout` stops it. A missing library or symbol makes it exit at once.
set -eu

dir="$1"
failed=0

if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq xvfb xauth >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q gtk3 mesa-libEGL libglvnd-gles xorg-x11-server-Xvfb xorg-x11-xauth >/dev/null
else
  echo "No apt-get or dnf here, so nothing to test with." >&2
  exit 1
fi

launch() {
  name="$1"
  shift
  status=0
  xvfb-run -a timeout 10 "$@" >/tmp/gpad-smoke.log 2>&1 || status=$?
  if [ "$status" -eq 124 ]; then
    echo "PASS $name started"
  else
    echo "FAIL $name exited with status $status:"
    cat /tmp/gpad-smoke.log
    failed=1
  fi
}

tested=0
for deb in "$dir"/*.deb; do
  [ -e "$deb" ] || continue
  command -v apt-get >/dev/null || break
  tested=1
  # apt pulls in GTK and the rest from the package's Depends.
  apt-get install -y -qq "$(cd "$(dirname "$deb")" && pwd)/$(basename "$deb")" >/dev/null
  launch "$(basename "$deb")" gpad
done

# Containers have no FUSE, so let the AppImage unpack itself.
export APPIMAGE_EXTRACT_AND_RUN=1
for appimage in "$dir"/*.AppImage; do
  [ -e "$appimage" ] || continue
  tested=1
  chmod +x "$appimage"
  launch "$(basename "$appimage")" "$appimage"
done

if [ "$tested" -eq 0 ]; then
  echo "No packages found in $dir" >&2
  exit 1
fi
exit "$failed"
