#!/bin/bash
# Creates a stable, local, self-signed code-signing identity named
# "AerospaceSwipe Local Signing" in your login keychain.
#
# Why: `make bundle`/`make sign` ad-hoc sign by default (no Apple Developer
# account required), but ad-hoc signatures are derived from the binary's
# contents, so every rebuild gets a *different* signature. macOS ties your
# Accessibility permission grant to that signature, so every rebuild
# (including a plain `brew upgrade aerospace-swipe`) silently breaks it: the
# permission prompt reappears but the app stops showing up in System
# Settings > Privacy & Security > Accessibility until you run
# `tccutil reset Accessibility com.example.swipe` and re-grant.
#
# Running this script once creates a certificate-backed identity instead.
# Its designated requirement is keyed to the certificate (stable across
# rebuilds), not the binary contents, so the same Accessibility grant keeps
# working across every future rebuild/upgrade. The makefile automatically
# picks up this identity if present (falls back to ad-hoc signing otherwise,
# e.g. on CI, where this script hasn't been run).

set -e

CERT_NAME="AerospaceSwipe Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "identity '$CERT_NAME' already exists, nothing to do"
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/codesign.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = $CERT_NAME

[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

echo "generating self-signed certificate..."
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/codesign.key" -out "$WORKDIR/codesign.crt" \
    -days 3650 -nodes -config "$WORKDIR/codesign.cnf"

openssl pkcs12 -export -out "$WORKDIR/codesign.p12" \
    -inkey "$WORKDIR/codesign.key" -in "$WORKDIR/codesign.crt" -passout pass:temppass

echo "importing into login keychain..."
security import "$WORKDIR/codesign.p12" -k "$KEYCHAIN" -P temppass -T /usr/bin/codesign -T /usr/bin/security

echo "trusting it for code signing only..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORKDIR/codesign.crt"

security find-identity -v -p codesigning

echo
echo "done. rebuild (make bundle / brew reinstall aerospace-swipe), then run:"
echo "  tccutil reset Accessibility com.example.swipe"
echo "and re-grant Accessibility once more — it will persist across every rebuild after that."
