#!/bin/bash
set -e

APP_NAME="HysteriaMenu"
APP_DIR="$HOME/Applications/${APP_NAME}.app"

echo "Building ${APP_NAME}..."

# IMPORTANT: Save bundled binaries BEFORE deleting the app
TMP_BIN_DIR=$(mktemp -d)
trap "rm -rf $TMP_BIN_DIR" EXIT

if [ -f "${APP_DIR}/Contents/Resources/hysteria" ]; then
    cp "${APP_DIR}/Contents/Resources/hysteria" "$TMP_BIN_DIR/"
fi
if [ -f "${APP_DIR}/Contents/Resources/tun2socks" ]; then
    cp "${APP_DIR}/Contents/Resources/tun2socks" "$TMP_BIN_DIR/"
fi

# Compile Swift to binary
swiftc -O \
  -target arm64-apple-darwin22.0 \
  -framework AppKit \
  -framework SwiftUI \
  -o "${APP_NAME}.bin" \
  HysteriaMenu.swift

# Now safe to remove old app
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy compiled Swift binary
cp "${APP_NAME}.bin" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Copy helper script
cp hysteria-helper.sh "${APP_DIR}/Contents/Resources/hysteria-helper.sh"
chmod +x "${APP_DIR}/Contents/Resources/hysteria-helper.sh"

# Restore bundled binaries (try saved copy first, then /tmp fallback)
if [ -f "$TMP_BIN_DIR/hysteria" ]; then
    cp "$TMP_BIN_DIR/hysteria" "${APP_DIR}/Contents/Resources/hysteria"
    chmod +x "${APP_DIR}/Contents/Resources/hysteria"
elif [ -f /tmp/hysteria-client/hysteria ]; then
    cp /tmp/hysteria-client/hysteria "${APP_DIR}/Contents/Resources/hysteria"
    chmod +x "${APP_DIR}/Contents/Resources/hysteria"
else
    echo "⚠️  Warning: hysteria binary not found, app won't work without it"
fi

if [ -f "$TMP_BIN_DIR/tun2socks" ]; then
    cp "$TMP_BIN_DIR/tun2socks" "${APP_DIR}/Contents/Resources/tun2socks"
    chmod +x "${APP_DIR}/Contents/Resources/tun2socks"
elif [ -f /tmp/hysteria-menu/tun2socks-bin ]; then
    cp /tmp/hysteria-menu/tun2socks-bin "${APP_DIR}/Contents/Resources/tun2socks"
    chmod +x "${APP_DIR}/Contents/Resources/tun2socks"
else
    echo "⚠️  Warning: tun2socks binary not found, app won't work without it"
fi

# Create Info.plist
cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.hysteriamenu</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Hysteria VPN</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc codesign
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

# Cleanup
rm -f "${APP_NAME}.bin"

echo ""
echo "✅ Built: $APP_DIR"
echo ""
echo "Run: open '$APP_DIR'"
echo ""
echo "Size:"
du -sh "$APP_DIR"
echo ""
echo "Bundled binaries:"
ls -lh "$APP_DIR/Contents/Resources/"