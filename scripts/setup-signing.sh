#!/bin/bash
# Generates a self-signed local code-signing certificate and imports it into
# your login keychain. This is a ONE-TIME setup step, required so macOS
# permission grants (Screen Recording, etc.) survive across rebuilds — an
# ad-hoc signature (`codesign --sign -`) gets a new identity every time you
# recompile, which invalidates every previously-granted permission.
set -euo pipefail

cd "$(dirname "$0")/.."

CERT_NAME="ClaudeTouchBar Local Signing"
DIR="signing"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "==> '$CERT_NAME' already exists and is trusted. Nothing to do."
    exit 0
fi

mkdir -p "$DIR"

echo "==> Generating self-signed certificate"
cat > "$DIR/codesign.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $CERT_NAME

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -nodes -config "$DIR/codesign.cnf" -extensions ext

echo "==> Packaging and importing into your login keychain"
openssl pkcs12 -export -out "$DIR/cert.p12" -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -passout pass:claudetouchbar -legacy
security import "$DIR/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P claudetouchbar -T /usr/bin/codesign

cat << 'EOF'

==> One manual step left (macOS requires GUI confirmation for this):

1. Open Keychain Access
2. Select the "login" keychain, category "My Certificates"
3. Find "ClaudeTouchBar Local Signing", double-click it
4. Expand "Trust", set "Code Signing" to "Always Trust"
5. Close the window and enter your password when prompted

Then run ./scripts/build-app.sh as usual.
EOF
