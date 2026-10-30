#!/bin/bash
# Build Icecream Notepad.app — native macOS C++ app.
# Requires: Xcode Command Line Tools (run: xcode-select --install)
set -e
cd "$(dirname "$0")"

echo "Compiling…"
clang++ -std=c++17 -O2 -fobjc-arc -framework Cocoa -framework UniformTypeIdentifiers -o "Icecream Notepad" main.mm

echo "Bundling…"
rm -rf "Icecream Notepad.app"
mkdir -p "Icecream Notepad.app/Contents/MacOS"
mkdir -p "Icecream Notepad.app/Contents/Resources"
cp "Icecream Notepad" "Icecream Notepad.app/Contents/MacOS/Icecream Notepad"
cat > "Icecream Notepad.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Icecream Notepad</string>
  <key>CFBundleIdentifier</key>
  <string>com.icecream.notepad</string>
  <key>CFBundleName</key>
  <string>Icecream Notepad</string>
  <key>CFBundleDisplayName</key>
  <string>Icecream Notepad</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

echo "Done: ./Icecream Notepad.app"
echo "Install: cp -r \"Icecream Notepad.app\" /Applications/ && xattr -cr \"/Applications/Icecream Notepad.app\""
