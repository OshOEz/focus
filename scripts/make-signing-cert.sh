#!/usr/bin/env bash
# One-time: a self-signed code-signing identity in the login keychain, so rebuilt Focus.app keeps
# its Camera/Accessibility grants (scripts/build-app.sh uses it when present). Local only: it is not
# trusted by Gatekeeper and cannot notarise; it only gives the app a stable identity on this Mac.
set -euo pipefail
NAME="${FOCUS_SIGN_ID:-Focus Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "already there: $NAME"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$NAME" > "$D/cs.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cs.cnf"
# OpenSSL 3 writes a PKCS#12 that `security import` can't read unless told -legacy; macOS's own
# LibreSSL writes the old format already and doesn't know the flag.
LEGACY=; openssl version | grep -q '^OpenSSL 3' && LEGACY=-legacy
P=$(openssl rand -hex 12)
openssl pkcs12 -export $LEGACY -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout "pass:$P" -name "$NAME"
# -T lets codesign use the key without a keychain prompt (checked: build-app.sh signed unattended).
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
echo "created: $NAME"
