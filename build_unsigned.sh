#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/NOVA-Build-61.xcarchive"
IPA="$BUILD_DIR/NOVA-Build-61-unsigned.ipa"
echo "Building repository revision: $(git -C "$ROOT" rev-parse --short HEAD)"

NOVA_API_BASE_URL="${NOVA_API_BASE_URL:-}"
if [[ ! "$NOVA_API_BASE_URL" =~ ^https://[^/]+/api/?$ ]] || [[ "$NOVA_API_BASE_URL" == *".example"* ]]; then
  echo 'Set NOVA_API_BASE_URL to your real HTTPS API base, for example https://api.yourdomain.com/api.' >&2
  exit 2
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }
python3 "$ROOT/generate_embedded_localizations.py"

xcodebuild \
  -project "$ROOT/ThreeOneOSFive.xcodeproj" \
  -scheme 3105 \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

APP="$ARCHIVE/Products/Applications/NOVA.app"
test -d "$APP"
# Remote patches must never be embedded in the signed app. Remove packages
# from every possible Xcode resource layout, not only from the app root.
find "$APP" -type f -name '*.3105' -print -delete
if find "$APP" -type f -name '*.3105' -print -quit | grep -q .; then
  echo "Error: a local .3105 patch remains inside the app bundle." >&2
  exit 1
fi
echo "Verified no bundled local patch resources; patches are loaded only from NOVA API."

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SAK" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :NOVA_API_BASE_URL $NOVA_API_BASE_URL" "$APP/Info.plist"
echo "Configured NOVA API URL in app bundle."

test -f "$APP/SAK"
# The embedded-resource footer stores its own offset; no large executable
# padding is needed for it to be read at runtime.
python3 "$ROOT/embed_app_resources.py" "$APP"
EXECUTABLE_BYTES="$(wc -c < "$APP/SAK" | tr -d ' ')"
MAX_EXECUTABLE_BYTES=$((64 * 1024 * 1024))
if (( EXECUTABLE_BYTES > MAX_EXECUTABLE_BYTES )); then
  echo "Error: SAK executable exceeds the 64 MiB size limit ($EXECUTABLE_BYTES bytes)." >&2
  exit 1
fi
echo "Verified SAK executable size: $EXECUTABLE_BYTES bytes."
python3 "$ROOT/embed_app_resources.py" --strip-audio "$APP"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -9qry "$IPA" Payload
  rm -rf Payload
)
ls -lh "$IPA"
echo "$IPA"
