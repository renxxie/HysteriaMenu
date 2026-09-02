#!/bin/bash
# Downloads the required third-party binaries (hysteria, tun2socks)
# Run this once before building the app, or after deleting the binaries

set -e

echo "Downloading dependencies..."

mkdir -p deps

# hysteria - QUIC-based VPN client
HYSTERIA_URL=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest \
  | grep "browser_download_url.*darwin-arm64\"" \
  | cut -d '"' -f 4)

if [ -n "$HYSTERIA_URL" ]; then
    echo "Downloading hysteria..."
    curl -L -o deps/hysteria "$HYSTERIA_URL"
    chmod +x deps/hysteria
    echo "✅ hysteria $(deps/hysteria version | grep Version | head -1)"
else
    echo "❌ Failed to find hysteria download URL"
    exit 1
fi

# tun2socks - TUN device to SOCKS5 bridge
TUN2SOCKS_URL=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest \
  | grep "browser_download_url.*darwin-arm64\"" \
  | cut -d '"' -f 4)

if [ -n "$TUN2SOCKS_URL" ]; then
    echo "Downloading tun2socks..."
    curl -L -o deps/tun2socks.zip "$TUN2SOCKS_URL"
    unzip -o deps/tun2socks.zip -d deps/
    mv deps/tun2socks-darwin-arm64 deps/tun2socks 2>/dev/null || true
    rm -f deps/tun2socks.zip
    chmod +x deps/tun2socks
    echo "✅ tun2socks $(deps/tun2socks --version | head -1)"
else
    echo "❌ Failed to find tun2socks download URL"
    exit 1
fi

echo ""
echo "✅ All dependencies downloaded to ./deps/"
echo "Now run ./build.sh to create the app"