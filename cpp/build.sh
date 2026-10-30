#!/bin/bash
# Build Notepad.app — native macOS C++ app.
# Requires: Xcode Command Line Tools (run: xcode-select --install)
set -e
cd "$(dirname "$0")"

echo "Compiling…"
clang++ -std=c++17 -O2 -framework Cocoa -o Notepad main.mm

echo "Bundling Notepad.app…"
rm -rf Notepad.app
mkdir -p Notepad.app/Contents/MacOS
mkdir -p Notepad.app/Contents/Resources
cp Notepad Notepad.app/Contents/MacOS/Notepad
cat > Notepad.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Notepad</string>
  <key>CFBundleIdentifier</key>
  <string>com.icecream.notepad</string>
  <key>CFBundleName</key>
  <string>Notepad</string>
  <key>CFBundleDisplayName</key>
  <string>Notepad</string>
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

echo "Done: ./Notepad.app"
echo "Install: cp -r Notepad.app /Applications/ && xattr -cr /Applications/Notepad.app"
