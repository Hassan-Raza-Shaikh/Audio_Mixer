#!/bin/bash
#
# Creates a stable, self-signed code-signing identity for Aura so that macOS
# TCC permissions (Screen Recording, Microphone) persist across rebuilds.
#
# Ad-hoc signing ("-") re-signs the app on every build, which makes macOS treat
# each build as a new app and forget granted permissions. A named self-signed
# identity keeps the signature stable, so you grant permission once.
#
# Safe to run more than once. You may be asked for your login-keychain password
# and, the first time you build, to "Always Allow" codesign to use the key.
#
set -euo pipefail

CERT_NAME="Aura Local Signing"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_XCCONFIG="$ROOT/Local.xcconfig"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> Setting up stable local signing for Aura"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "    Identity '$CERT_NAME' already exists — reusing it."
else
  echo "    Creating self-signed code-signing certificate '$CERT_NAME'..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  # Use the system (LibreSSL) openssl: OpenSSL 3.x on PATH (e.g. Homebrew or
  # conda) writes a PKCS#12 MAC that Apple's Security framework can't import.
  OPENSSL=/usr/bin/openssl
  [ -x "$OPENSSL" ] || OPENSSL=openssl

  cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

  "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1

  # A non-empty passphrase avoids "MAC verification failed" on import.
  P12PASS="aura-local-signing"
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12PASS" -name "$CERT_NAME" >/dev/null 2>&1

  # Import the identity and pre-authorize codesign to use its private key.
  security import "$TMP/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign >/dev/null

  # Try to silence the codesign keychain prompt (needs the login password).
  echo "    (If prompted, enter your login-keychain password to allow codesign.)"
  security set-key-partition-list -S apple-tool:,apple: -k "" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
    || echo "    Skipped partition-list update; codesign will prompt once — click 'Always Allow'."

  echo "    Certificate created."
fi

# Point the build at the stable identity via a git-ignored override.
echo "AURA_CODE_SIGN_IDENTITY = $CERT_NAME" > "$LOCAL_XCCONFIG"
echo "==> Wrote $LOCAL_XCCONFIG (git-ignored)"

echo ""
echo "Next steps:"
echo "  1. xcodegen generate"
echo "  2. Build & run (Xcode ⌘R, or xcodebuild ... build)"
echo "  3. Grant Screen Recording + Microphone to Aura ONCE in System Settings."
echo "     From now on rebuilds keep the same signature, so the grants stick."
