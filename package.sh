#!/bin/bash
#
# Builds the universal plugin (Apple silicon + Intel) and packs it for colleagues:
#   dist/VolBrainLink-IsiX-<version>.zip   (TARGET=horos: dist/VolBrainLink-Horos-<version>.zip)
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then BUILD=build-horos; HOSTNAME=Horos; DIST_FILES=Distribution/Horos
else BUILD=build; HOSTNAME=IsiX; DIST_FILES=Distribution; fi
TARGET="$TARGET" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $BUILD/VolBrainLink.osirixplugin/Contents/Info.plist)
NAME="VolBrainLink-$HOSTNAME-$VERSION"
STAGE="dist/$NAME"

rm -rf "$STAGE" "dist/$NAME.zip"
mkdir -p "$STAGE"
cp -R $BUILD/VolBrainLink.osirixplugin "$STAGE/"
cp "$DIST_FILES/Install VolBrainLink.command" "$STAGE/"
chmod +x "$STAGE/Install VolBrainLink.command"
sed "s/@VERSION@/$VERSION/g" Distribution/README.txt > "$STAGE/README.txt"
cp LICENSE "$STAGE/LICENSE.txt"

codesign --verify --deep "$STAGE/VolBrainLink.osirixplugin"
echo "==> Architectures: $(lipo -archs "$STAGE/VolBrainLink.osirixplugin/Contents/MacOS/VolBrainLink")"
(cd dist && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip")
echo "==> Package: $(pwd)/dist/$NAME.zip"
