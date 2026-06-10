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
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
