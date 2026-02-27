#!/bin/bash
# Build and Install script for Latency Monitor Pro

set -e

REPO_ROOT=$(pwd)
APP_NAME="Latency Monitor"
SOURCE_FILE="LatencyMonitor.swift"
ICON_FILE="Resources/AppIcon.icns"
INFO_PLIST="Info.plist"

echo "🚀 Building $APP_NAME..."

# 1. Compile
swiftc "$SOURCE_FILE" -o LatencyMonitor_bin

# 2. Build App Bundle
echo "📦 Packaging..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

mv LatencyMonitor_bin "$APP_NAME.app/Contents/MacOS/LatencyMonitor"
chmod +x "$APP_NAME.app/Contents/MacOS/LatencyMonitor"

cp "$ICON_FILE" "$APP_NAME.app/Contents/Resources/"
cp "$INFO_PLIST" "$APP_NAME.app/Contents/"

# 3. Zip for Release
echo "🗜 Updating release zip..."
mkdir -p release
zip -r "release/Latency Monitor.zip" "$APP_NAME.app"

echo "✅ Build Complete!"
echo "Do you want to copy the app to your Desktop? (y/n)"
read -r choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    cp -R "$APP_NAME.app" ~/Desktop/
    echo "✨ Copied to Desktop."
fi

echo "🏁 All done!"
