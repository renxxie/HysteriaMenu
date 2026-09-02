#!/bin/bash
# hysteria-helper.sh - Sets up full tunnel TUN VPN via Hysteria2
# Usage: sudo ./hysteria-helper.sh {start|stop|status}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -e

# Config
# Server IP is read from config.yaml automatically (no need to set here)
SOCKS_PORT="1080"
TUN_DEVICE="utun9"          # Use utun9 to avoid conflict with AmneziaWG
TUN_IP="10.10.0.2"
TUN_GATEWAY="10.10.0.1"

# Paths
HYSTERIA_BIN="$HOME/Applications/HysteriaMenu.app/Contents/Resources/hysteria"
TUN2SOCKS_BIN="$HOME/Applications/HysteriaMenu.app/Contents/Resources/tun2socks"

# Fallback to /tmp
[ ! -x "$HYSTERIA_BIN" ] && HYSTERIA_BIN="/tmp/hysteria-client/hysteria"
[ ! -x "$TUN2SOCKS_BIN" ] && TUN2SOCKS_BIN="/tmp/hysteria-menu/tun2socks-bin"

CONFIG_DIR="$HOME/Library/Application Support/Hysteria"
LOG_DIR="$HOME/Library/Logs/HysteriaMenu"
PID_DIR="$HOME/Library/Application Support/HysteriaMenu/pids"

mkdir -p "$LOG_DIR" "$PID_DIR"

# Extract server IP from config.yaml (so we don't hardcode it here)
extract_server_ip() {
    local config="$CONFIG_DIR/config.yaml"
    if [ ! -f "$config" ]; then
        echo ""
        return
    fi
    # Get server line, extract IP:port, return just IP
    local full=$(grep "^server:" "$config" | head -1 | sed 's/^server:[[:space:]]*//')
    # Remove :port if present
    echo "$full" | cut -d: -f1
}

# Set SERVER_IP from env var or config
SERVER_IP="${HYSTERIA_SERVER_IP:-$(extract_server_ip)}"
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "YOUR_SERVER_IP" ]; then
    echo "ERROR: Set HYSTERIA_SERVER_IP env var or configure config.yaml" >&2
    exit 1
fi

cleanup_all() {
    # Kill everything VPN-related
    pkill -9 -f "hysteria client" 2>/dev/null || true
    pkill -9 -f "tun2socks" 2>/dev/null || true
    pkill -9 -f "AmneziaWG" 2>/dev/null || true
    pkill -9 -f "WireGuardNetworkExtension" 2>/dev/null || true
    sleep 1
}

start() {
    echo "=== Starting Hysteria2 full tunnel ==="

    # Step 1: Clean everything
    cleanup_all

    # Step 2: Get original gateway
    ORIG_GATEWAY=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
    ORIG_INTERFACE=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}')
    if [ -z "$ORIG_GATEWAY" ]; then
        echo "ERROR: No default route found"
        exit 1
    fi
    echo "Original gateway: $ORIG_GATEWAY ($ORIG_INTERFACE)"

    # Step 3: Ensure VPN server is reachable BEFORE changing routes
    # Add host route to VPS via original gateway (so QUIC can connect)
    route delete -host "$SERVER_IP" 2>/dev/null || true
    route add -host "$SERVER_IP" "$ORIG_GATEWAY"
    echo "✅ Host route to $SERVER_IP via $ORIG_GATEWAY"

    # Step 4: Start hysteria client FIRST (before TUN changes)
    echo "Starting Hysteria client..."
    "$HYSTERIA_BIN" client -c "$CONFIG_DIR/config.yaml" --disable-update-check \
        </dev/null >"$LOG_DIR/hysteria.log" 2>&1 &
    HYSTERIA_PID=$!
    echo $HYSTERIA_PID > "$PID_DIR/hysteria.pid"
    sleep 4

    # Verify hysteria connected
    if ! kill -0 $HYSTERIA_PID 2>/dev/null; then
        echo "ERROR: Hysteria client died"
        cat "$LOG_DIR/hysteria.log"
        exit 1
    fi
    echo "✅ Hysteria client running (PID $HYSTERIA_PID)"

    # Step 5: Start tun2socks (creates TUN device)
    echo "Starting tun2socks..."
    "$TUN2SOCKS_BIN" \
        --device "$TUN_DEVICE" \
        --proxy "socks5://127.0.0.1:$SOCKS_PORT" \
        --mtu 1400 \
        --loglevel info \
        </dev/null >"$LOG_DIR/tun2socks.log" 2>&1 &
    TUNSOCKS_PID=$!
    echo $TUNSOCKS_PID > "$PID_DIR/tun2socks.pid"
    sleep 3

    # Verify tun2socks running
    if ! kill -0 $TUNSOCKS_PID 2>/dev/null; then
        echo "ERROR: tun2socks died"
        cat "$LOG_DIR/tun2socks.log"
        kill $HYSTERIA_PID 2>/dev/null
        exit 1
    fi
    echo "✅ tun2socks running (PID $TUNSOCKS_PID)"

    # Step 6: Configure TUN interface (use /24 mask for better routing)
    echo "Configuring TUN interface..."
    ifconfig "$TUN_DEVICE" "$TUN_IP" "$TUN_GATEWAY" up 2>/dev/null || true
    # Add broadcast route
    route add -net 10.10.0.0/24 -interface "$TUN_DEVICE" 2>/dev/null || true

    # Save state for stop
    cat > "$PID_DIR/state" <<EOF
ORIG_GATEWAY=$ORIG_GATEWAY
ORIG_INTERFACE=$ORIG_INTERFACE
TUN_DEVICE=$TUN_DEVICE
SERVER_IP=$SERVER_IP
EOF

    # Step 7: Change default route to TUN
    echo "Setting default route through TUN..."
    route delete default 2>/dev/null || true
    route add default "$TUN_IP"

    echo ""
    echo "✅ VPN ACTIVE"
    echo "  TUN: $TUN_DEVICE ($TUN_IP)"
    echo "  VPS via: $ORIG_GATEWAY"
    echo "  All other traffic via: $TUN_IP"
}

stop() {
    echo "=== Stopping Hysteria2 ==="

    # Kill processes
    if [ -f "$PID_DIR/hysteria.pid" ]; then
        kill $(cat "$PID_DIR/hysteria.pid") 2>/dev/null || true
        rm -f "$PID_DIR/hysteria.pid"
    fi
    if [ -f "$PID_DIR/tun2socks.pid" ]; then
        kill $(cat "$PID_DIR/tun2socks.pid") 2>/dev/null || true
        rm -f "$PID_DIR/tun2socks.pid"
    fi
    pkill -9 -f "hysteria client" 2>/dev/null || true
    pkill -9 -f "tun2socks" 2>/dev/null || true
    sleep 1

    # Restore routes
    if [ -f "$PID_DIR/state" ]; then
        source "$PID_DIR/state"
        echo "Restoring routes..."
        route delete default 2>/dev/null || true
        if [ -n "$ORIG_GATEWAY" ]; then
            route add default "$ORIG_GATEWAY"
        fi
        route delete -host "$SERVER_IP" 2>/dev/null || true
        route delete -net 10.10.0.0/24 2>/dev/null || true
        rm -f "$PID_DIR/state"
    fi

    echo "✅ VPN stopped"
}

status() {
    echo "=== Hysteria2 Status ==="
    if [ -f "$PID_DIR/hysteria.pid" ] && kill -0 $(cat "$PID_DIR/hysteria.pid") 2>/dev/null; then
        echo "Hysteria: ✅ Running (PID $(cat $PID_DIR/hysteria.pid))"
    else
        echo "Hysteria: ❌ Stopped"
    fi

    if [ -f "$PID_DIR/tun2socks.pid" ] && kill -0 $(cat "$PID_DIR/tun2socks.pid") 2>/dev/null; then
        echo "tun2socks: ✅ Running"
    else
        echo "tun2socks: ❌ Stopped"
    fi

    if [ -f "$PID_DIR/state" ]; then
        source "$PID_DIR/state"
        if ifconfig "$TUN_DEVICE" >/dev/null 2>&1; then
            echo "TUN: ✅ $TUN_DEVICE"
        else
            echo "TUN: ❌ Not found"
        fi
    fi
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    restart) stop; sleep 2; start ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        exit 1
        ;;
esac