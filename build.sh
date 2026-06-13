#!/bin/zsh
# Build Glancebar.app from the Objective-C sources. No Xcode project needed.
set -e
cd "$(dirname "$0")"

APP=build/Glancebar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -O2 -mmacosx-version-min=13.0 Sources/pure.m Sources/main.m \
    -framework Cocoa -framework IOKit -framework Security \
    -o "$APP/Contents/MacOS/Glancebar"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so the Keychain "Always Allow" grant for the Claude
# Code-credentials item survives rebuilds (ad-hoc signing changes the code hash every
# build, which re-triggers the prompt). Falls back to ad-hoc on machines that don't
# have the cert. Create the identity once in Keychain Access > Certificate Assistant >
# Create a Certificate (Name: "Glancebar Self-Signed", Identity Type: Self Signed Root,
# Certificate Type: Code Signing); ./build.sh then picks it up automatically. See README.
IDENTITY="${GLANCEBAR_CODESIGN_IDENTITY:-Glancebar Self-Signed}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
