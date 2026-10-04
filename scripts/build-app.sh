#!/usr/bin/env bash
# Optional scripts/build-app.local.env (gitignored) sets local signing/build defaults.
# Exported environment variables take precedence over values in that file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Preserve caller overrides before sourcing the local file.
for name in PIG_BUNDLE_ID PIG_SIGN_ID PIG_SIGN_KEYCHAIN PIG_CREATE_LOCAL_IDENTITY; do
  if [[ ${!name+x} ]]; then
    printf -v "env_$name" '%s' "${!name}"
    printf -v "has_$name" '%s' 1
  fi
done
if [[ -f "$ROOT_DIR/scripts/build-app.local.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/scripts/build-app.local.env"
fi
for name in PIG_BUNDLE_ID PIG_SIGN_ID PIG_SIGN_KEYCHAIN PIG_CREATE_LOCAL_IDENTITY; do
  marker="has_$name"
  if [[ ${!marker-} == 1 ]]; then
    saved="env_$name"
    printf -v "$name" '%s' "${!saved}"
  fi
done

APP_NAME="PiG"
BUNDLE_ID="${PIG_BUNDLE_ID-com.jacob.pig}"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD="${PIG_BUILD-1}"
CONFIG="release"
CLEAN=0
CREATE_LOCAL_IDENTITY="${PIG_CREATE_LOCAL_IDENTITY-0}"
SIGN_ID="${PIG_SIGN_ID--}"
KEYCHAIN="${PIG_SIGN_KEYCHAIN-$HOME/Library/Keychains/login.keychain-db}"
DIST_DIR="$ROOT_DIR/dist"
APP="$DIST_DIR/$APP_NAME.app"
EXECUTABLE="$ROOT_DIR/.build/$CONFIG/$APP_NAME"
ICON="$ROOT_DIR/Resources/AppIcon.icns"

for arg in "$@"; do
  case "$arg" in
    --clean)
      CLEAN=1
      ;;
    --create-local-identity)
      CREATE_LOCAL_IDENTITY=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--clean] [--create-local-identity]" >&2
      exit 2
      ;;
  esac
done

has_signing_identity() {
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -F "\"$SIGN_ID\"" >/dev/null
}

create_local_signing_identity() {
  local tmpdir key cert p12 conf p12_password
  tmpdir="$(/usr/bin/mktemp -d)"
  key="$tmpdir/signing.key"
  cert="$tmpdir/signing.crt"
  p12="$tmpdir/signing.p12"
  conf="$tmpdir/openssl.cnf"
  p12_password="pig-local-signing"

  cat > "$conf" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = ext

[ dn ]
CN = $SIGN_ID

[ ext ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

  echo "Creating local code signing identity: $SIGN_ID"
  /usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -keyout "$key" -out "$cert" -config "$conf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$key" -in "$cert" -name "$SIGN_ID" \
    -out "$p12" -passout "pass:$p12_password" >/dev/null 2>&1
  /usr/bin/security import "$p12" -k "$KEYCHAIN" -P "$p12_password" -T /usr/bin/codesign >/dev/null
  /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$cert" >/dev/null
  rm -rf "$tmpdir"
}

ensure_signing_identity() {
  if has_signing_identity; then
    return
  fi

  if [[ "$CREATE_LOCAL_IDENTITY" != 1 ]]; then
    echo "Code signing identity '$SIGN_ID' not found in $KEYCHAIN." >&2
    echo "Set PIG_SIGN_ID=- for ad-hoc signing, or rerun with --create-local-identity to create and trust a local identity." >&2
    exit 1
  fi

  create_local_signing_identity

  if ! has_signing_identity; then
    echo "Could not create/find local signing identity: $SIGN_ID" >&2
    echo "Open Keychain Access and create a Code Signing certificate named '$SIGN_ID', then rerun." >&2
    exit 1
  fi
}

cd "$ROOT_DIR"

if [[ "$CLEAN" == "1" ]]; then
  echo "Cleaning SwiftPM build artifacts…"
  swift package clean
fi

echo "Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG"

echo "Creating app bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  if [[ "$SIGN_ID" != "-" ]]; then
    ensure_signing_identity
  fi
  echo "Signing with identity: $SIGN_ID"
  /usr/bin/codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "Built: $APP"
echo "Signed identity: $SIGN_ID"
echo "Run: open '$APP'"
