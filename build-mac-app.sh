#!/bin/sh
set -eu

app_name="SkeletonKey"
bundle_id="com.krisenigma.skeletonkey"
# Stable local signing identity. Ad-hoc (`codesign --sign -`) pins TCC to a
# cdhash that changes every rebuild, which is why Accessibility / Input
# Monitoring kept resetting. A real cert keeps the designated requirement
# anchored to the cert leaf across rebuilds.
sign_identity="${SKELETONKEY_SIGN_IDENTITY:-SkeletonKey Dev}"
keychain_password="${SKELETONKEY_KEYCHAIN_PASSWORD:-skeletonkey}"
keychain_path="${SKELETONKEY_KEYCHAIN_PATH:-$HOME/Library/Keychains/skeletonkey.keychain-db}"
build_root="build"
bundle_path="$build_root/$app_name.app"
contents_path="$bundle_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
plist_path="$contents_path/Info.plist"
executable_path="$macos_path/$app_name"

identity_is_usable() {
  security find-identity -v -p codesigning "$keychain_path" 2>/dev/null \
    | grep -F "\"$sign_identity\"" >/dev/null
}

ensure_keychain_in_search_list() {
  # Keep existing user keychains; prepend ours if missing.
  current="$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')"
  found=0
  for kc in $current; do
    if [ "$kc" = "$keychain_path" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$keychain_path" $current
  fi
}

create_signing_identity() {
  echo "Creating local code-signing identity \"$sign_identity\"…"
  echo "(One-time setup. After this, Accessibility / Input Monitoring grants survive rebuilds.)"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf \"$tmp\"" EXIT

  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$tmp/dev.key" -out "$tmp/dev.crt" \
    -subj "/CN=$sign_identity/O=SkeletonKey/C=US" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

  # macOS Keychain still expects the older PKCS#12 cipher suite.
  openssl pkcs12 -export -legacy \
    -in "$tmp/dev.crt" -inkey "$tmp/dev.key" \
    -out "$tmp/dev.p12" -password pass:skeletonkey \
    -name "$sign_identity"

  # -A: allow codesign access without interactive ACL prompts.
  security import "$tmp/dev.p12" -k "$keychain_path" \
    -P skeletonkey -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
    "$keychain_path" >/dev/null

  # Self-signed leaves need an explicit user trust entry or find-identity
  # reports CSSMERR_TP_NOT_TRUSTED and codesign refuses them. trustRoot is
  # the result type that works here (trustAsRoot is rejected on this macOS).
  # May prompt once for admin authentication via the system dialog.
  security add-trusted-cert -r trustRoot -p codeSign "$tmp/dev.crt"

  rm -rf "$tmp"
  trap - EXIT
}

ensure_signing_identity() {
  if [ ! -f "$keychain_path" ]; then
    security create-keychain -p "$keychain_password" "$keychain_path"
    # Avoid lock timeouts interrupting unsigned rebuild loops mid-session.
    security set-keychain-settings -lut 21600 "$keychain_path"
  fi

  security unlock-keychain -p "$keychain_password" "$keychain_path"
  ensure_keychain_in_search_list

  if identity_is_usable; then
    return 0
  fi

  create_signing_identity

  if ! identity_is_usable; then
    cat >&2 <<EOF

Couldn't create a usable "$sign_identity" identity in:
  $keychain_path

If Keychain Access shows the certificate, set Trust → Code Signing → Always Trust,
then re-run: sh build-mac-app.sh

EOF
    exit 1
  fi

  echo "Signing identity ready: $sign_identity"
}

rm -rf "$bundle_path"
mkdir -p "$macos_path" "$resources_path"

swiftc main.swift mac-sender.swift -o "$executable_path" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework Network

if [ ! -f assets/AppIcon.icns ]; then
  echo "Missing assets/AppIcon.icns" >&2
  exit 1
fi
cp assets/AppIcon.icns "$resources_path/AppIcon.icns"
if [ -f assets/MenuBarIcon.png ]; then
  cp assets/MenuBarIcon.png "$resources_path/MenuBarIcon.png"
fi
cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>SkeletonKey connects to a listener on your Windows PC over your local network to forward mouse input.</string>
</dict>
</plist>
PLIST

# Required for some Launch Services / Finder icon lookups.
printf 'APPL????' > "$contents_path/PkgInfo"

ensure_signing_identity

# Sign with the stable identity so TCC's designated requirement is anchored
# to the certificate leaf (not a per-build cdhash).
codesign --force --deep --sign "$sign_identity" --keychain "$keychain_path" \
  --identifier "$bundle_id" "$bundle_path"

# Sanity check: a surviving grant needs a cert-anchored DR, not "cdhash H...".
requirement="$(codesign -d -r- "$bundle_path" 2>&1 | sed -n 's/^.*designated => //p')"
case "$requirement" in
  *certificate*)
    echo "Signed with \"$sign_identity\" (stable TCC identity)."
    ;;
  *)
    echo "warning: designated requirement looks unstable: $requirement" >&2
    echo "Accessibility / Input Monitoring may still reset on rebuild." >&2
    ;;
esac

echo "Built $bundle_path"
