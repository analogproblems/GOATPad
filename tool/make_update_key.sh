#!/bin/sh
# Makes the key pair that signs GPad's releases, which GPad checks before
# it updates itself. Run it once, on a computer you trust:
#
#   tool/make_update_key.sh
#
# It writes the private key to gpad-update-signing-key.pem, here, and the
# public key to tool/update_public_key.pem. Then:
#
# 1. Add the private key as the repository secret GPAD_UPDATE_SIGNING_KEY
#    (Settings > Secrets and variables > Actions > New repository secret),
#    pasting the whole file, BEGIN and END lines included.
# 2. Keep the file somewhere safe and private, like a password manager, and
#    delete it here. Anyone with it can sign updates that GPad installs.
# 3. Commit tool/update_public_key.pem. Builds made from then on update
#    only to releases signed with this key.
set -eu

private=gpad-update-signing-key.pem
public="$(dirname "$0")/update_public_key.pem"
[ ! -e "$private" ] || { echo "error: $private already exists" >&2; exit 1; }

umask 077
openssl genpkey -algorithm ed25519 -out "$private"
umask 022
openssl pkey -in "$private" -pubout -out "$public"
echo "Private key: $private (add it as GPAD_UPDATE_SIGNING_KEY, then keep it safe)"
echo "Public key: $public (commit it)"
