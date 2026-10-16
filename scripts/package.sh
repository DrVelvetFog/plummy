#!/bin/zsh
# Build a signed + NOTARIZED Plummy.dmg — a double-click, drag-to-Applications installer with no
# Gatekeeper warning. This is the distribution build; build-mac.sh is the quick local one.
#
# One-time setup (yours, once — needs an Apple Developer account, team 3Q7ZZFFVFP):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +, or developer.apple.com).
#   2. A notarytool credential profile stored in the keychain:
#        xcrun notarytool store-credentials "plummy-notary" \
#          --apple-id "you@example.com" --team-id 3Q7ZZFFVFP --password "<app-specific-password>"
#      (make the app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords.)
#
# Then just run:  ./scripts/package.sh
#   Override the profile name with NOTARY_PROFILE=..., or the signing identity with DEVID_IDENTITY=...
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-plummy-notary}"

# 1. Build + assemble the app (same layout as build-mac.sh).
swift build -c release --product PlummyMac
STAGE=$(mktemp -d)
APP="$STAGE/Plummy.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PlummyMac" "$APP/Contents/MacOS/PlummyMac"
cp Mac/Info.plist "$APP/Contents/Info.plist"
cp Shared/Fonts/*.ttf "$APP/Contents/Resources/"
cp Mac/Resources/Plummy.icns "$APP/Contents/Resources/"

# 2. Sign with Developer ID + the hardened runtime + a secure timestamp (all three are required to notarize).
#    If the Kokoro voice subprocess or anything else trips the hardened runtime at launch, add an
#    entitlements plist here with `--entitlements scripts/plummy.entitlements`.
IDENTITY="${DEVID_IDENTITY:-$(security find-identity -v -p codesigning | grep '"Developer ID Application' | grep -v REVOKED | head -1 | awk '{print $2}' || true)}"
if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' certificate found in the keychain." >&2
  echo "Create one (see the one-time setup at the top of this script), then re-run." >&2
  echo "For local use only, scripts/build-mac.sh signs with a Development cert and needs no notarization." >&2
  exit 1
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

# 3. Notarize the app, then staple the ticket so it verifies offline.
ZIP="$STAGE/Plummy.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting the app to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# 4. Build a drag-to-Applications .dmg.
rm -rf build; mkdir -p build
DMG="build/Plummy.dmg"
DMGSTAGE=$(mktemp -d)
ditto --norsrc --noextattr "$APP" "$DMGSTAGE/Plummy.app"
ln -s /Applications "$DMGSTAGE/Applications"
hdiutil create -volname "Plummy" -srcfolder "$DMGSTAGE" -ov -format UDZO "$DMG"

# 5. Sign + notarize + staple the .dmg itself (so the download is trusted end to end).
codesign --force --sign "$IDENTITY" "$DMG"
echo "Submitting the .dmg to Apple for notarization…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

rm -rf "$STAGE" "$DMGSTAGE"
echo ""
echo "Made $DMG — a notarized, drag-to-Applications installer. Double-click it; no Gatekeeper warning."
echo "The app still asks for Accessibility, Screen Recording, Microphone, etc. on first launch, as macOS requires."
