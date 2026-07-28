#!/bin/sh
set -eu

launcher_name="KrisKVM"
cli_name="mac-sender"
build_root="build"
bundle_path="$build_root/$launcher_name.app"
contents_path="$bundle_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
plist_path="$contents_path/Info.plist"
launcher_executable_path="$macos_path/$launcher_name"
cli_executable_path="$build_root/$cli_name"

rm -rf "$bundle_path"
mkdir -p "$macos_path" "$resources_path"

swiftc cli-main.swift mac-sender.swift -o "$cli_executable_path" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework Network

swiftc launcher-main.swift -o "$launcher_executable_path" \
  -framework AppKit \
  -framework Foundation

cat > "$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>KrisKVM</string>
  <key>CFBundleIdentifier</key>
  <string>com.krisenigma.kriskvmlauncher</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>KrisKVM</string>
  <key>CFBundleDisplayName</key>
  <string>KrisKVM</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $bundle_path"
