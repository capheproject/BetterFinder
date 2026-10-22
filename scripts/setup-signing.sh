#!/bin/zsh
# Creates a local, self-signed code-signing identity for BetterFinder in its own keychain.
#
# Why: macOS remembers privacy permissions (Desktop, Documents, Downloads, Full Disk Access)
# per code-signing identity. Ad-hoc signatures change on every build, so each reinstall looked
# like a new app and permissions were asked for again. A stable certificate keeps them.
#
# The identity lives in ~/Library/Keychains/BetterFinderSigning.keychain-db. Your login keychain,
# keychain search list and certificate trust settings are left alone. Safe to run more than once.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/BetterFinderSigning.keychain-db"
KEYCHAIN_PASSWORD="betterfinder-local-signing"
IDENTITY="BetterFinder Local Signing"
OPENSSL=/usr/bin/openssl   # LibreSSL writes PKCS#12 files that `security import` understands

if [[ -f "$KEYCHAIN" ]] && security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity “$IDENTITY” already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
$OPENSSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
  -out "$WORK/identity.p12" -passout pass:"$KEYCHAIN_PASSWORD" 2>/dev/null

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a keychain prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created signing identity “$IDENTITY” in $KEYCHAIN"
