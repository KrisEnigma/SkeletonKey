#!/bin/sh
set -eu

app_name="SkeletonKey"
build_root="build"
bundle_path="$build_root/$app_name.app"
contents_path="$bundle_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
plist_path="$contents_path/Info.plist"
executable_path="$macos_path/$app_name"

rm -rf "$bundle_path"
mkdir -p "$macos_path" "$resources_path"

swiftc main.swift mac-sender.swift -o "$executable_path" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework Network

cat > "$plist_path" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SkeletonKey</string>
  <key>CFBundleIdentifier</key>
  <string>com.krisenigma.skeletonkey</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SkeletonKey</string>
  <key>CFBundleDisplayName</key>
  <string>SkeletonKey</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>SkeletonKey connects to a listener on your Windows PC over your local network to forward mouse input.</string>
</dict>
</plist>
PLIST

# The binary was completely unsigned before this. macOS's TCC (Accessibility
# / Input Monitoring) grants tie themselves to a stable code identity when
# one exists, but fall back to hashing the raw executable when it doesn't.
# That meant every rebuild produced a different hash and looked like a
# brand-new, untrusted app, forcing you to re-grant permissions each time.
# Ad-hoc signing with a fixed --identifier gives TCC something stable to key
# the grant to instead, so a rebuild should no longer invalidate the
# existing grant.
codesign --force --deep --sign - --identifier "com.krisenigma.skeletonkey" "$bundle_path"

echo "Built $bundle_path"
