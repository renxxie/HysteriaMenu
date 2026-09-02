#!/bin/bash
# hysteria-helper.sh - Sets up full tunnel TUN VPN via Hysteria2
# Usage: sudo ./hysteria-helper.sh {start|stop|status}

# Set PATH explicitly for do shell script context
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

set -e

# Config - Edit these or use environment variables
SERVER_IP="${HYSTERIA_SERVER_IP:-YOUR_SERVER_IP}"
SOCKS_PORT="1080"
TUN_DEVICE="utun8"
TUN_IP="10.10.0.2"
TUN_GATEWAY="10.10.0.1"

# Try bundled binaries in app first, then fall back to /tmp
HYSTERIA_BIN="$HOME/Applications/HysteriaMenu.app/Contents/Resources/hysteria"
TUN2SOCKS_BIN="$HOME/Applications/HysteriaMenu.app/Contents/Resources/tun2socks"

# Fallback to /tmp if app bundle not found
if [ ! -x "$HYSTERIA_BIN" ]; then
    HYSTERIA_BIN="/tmp/hysteria-client/hysteria"
fi
if [ ! -x "$TUN2SOCKS_BIN" ]; then
    TUN2SOCKS_BIN="/tmp/hysteria-menu/tun2socks-bin"
fi

CONFIG_DIR="$HOME/Library/Application Support/Hysteria"
LOG_DIR="$HOME/Library/Logs/HysteriaMenu"
PID_DIR="$HOME/Library/Application Support/HysteriaMenu/pids"

mkdir -p "$LOG_DIR" "$PID_DIR"

start() {
    echo "Starting Hysteria full tunnel..."

    # Kill any existing
    pkill -f "hysteria client" 2>/dev/null || true
    pkill -f "tun2socks" 2>/dev/null || true
    sleep 1

    # Get original default gateway (before VPN)
    ORIG_GATEWAY=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
    ORIG_INTERFACE=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}')
    echo "$ORIG_GATEWAY" > "$PID_DIR/orig_gateway"
    echo "$ORIG_INTERFACE" > "$PID_DIR/orig_interface"
    echo "Original gateway: $ORIG_GATEWAY ($ORIG_INTERFACE)"

    # Create TUN device
    echo "Creating TUN device $TUN_DEVICE..."
    if ! ifconfig "$TUN_DEVICE" >/dev/null 2>&1; then
        # Need to create it via utun control
        # On macOS, we use ifconfig with the utun name and the kernel will create it
        :
    fi

    # Start hysteria client (SOCKS5 server)
    echo "Starting Hysteria client..."
    # Use subshell with redirection to fully detach (macOS doesn't have setsid)
    ("$HYSTERIA_BIN" client -c "$CONFIG_DIR/config.yaml" </dev/null >"$LOG_DIR/hysteria.log" 2>&1 & echo $! > "$PID_DIR/hysteria.pid") &
    sleep 3

    # Verify hysteria is running
    if ! pgrep -f "hysteria client" >/dev/null; then
        echo "ERROR: Hysteria client failed to start"
        cat "$LOG_DIR/hysteria.log"
        return 1
    fi
    echo "✅ Hysteria client running"

    # Start tun2socks
    echo "Starting tun2socks..."
    ("$TUN2SOCKS_BIN" \
        --device "$TUN_DEVICE" \
        --proxy "socks5://127.0.0.1:$SOCKS_PORT" \
        --mtu 1400 \
        --loglevel info \
        </dev/null >"$LOG_DIR/tun2socks.log" 2>&1 & echo $! > "$PID_DIR/tun2socks.pid") &
    sleep 2

    # Configure TUN device
    echo "Configuring TUN interface..."
    ifconfig "$TUN_DEVICE" "$TUN_IP" "$TUN_GATEWAY" up

    # Get the actual TUN device name (macOS may rename)
    ACTUAL_TUN=$(ifconfig | grep -B1 "10.10.0.2" | head -1 | awk -F: '{print $1}' | tr -d ' ')
    if [ -n "$ACTUAL_TUN" ] && [ "$ACTUAL_TUN" != "$TUN_DEVICE" ]; then
        echo "Actual TUN device: $ACTUAL_TUN (was $TUN_DEVICE)"
        TUN_DEVICE="$ACTUAL_TUN"
        echo "$TUN_DEVICE" > "$PID_DIR/tun_device"
    else
        echo "$TUN_DEVICE" > "$PID_DIR/tun_device"
    fi

    # Add route for Hysteria server through original gateway (so we can still reach it)
    echo "Adding route for Hysteria server..."
    # Ignore error if route already exists (from previous run)
    route add -host "$SERVER_IP" "$ORIG_GATEWAY" 2>/dev/null || echo "  (route already exists, ok)"

    # Set DNS (skip if /etc/resolver doesn't exist)
    if [ -d /etc/resolver ]; then
        echo "nameserver 1.1.1.1" > /etc/resolver/hysteria-vpn.conf 2>/dev/null || true
    fi

    # Replace default route to go through TUN
    echo "Setting default route through TUN..."
    route delete default 2>/dev/null || true
    route add default "$TUN_IP"

    echo ""
    echo "✅ Full tunnel VPN active"
    echo "TUN: $TUN_DEVICE ($TUN_IP -> $TUN_GATEWAY)"
    echo "Original gateway: $ORIG_GATEWAY (saved for restore)"
}

stop() {
    echo "Stopping Hysteria full tunnel..."

    # Kill tun2socks
    if [ -f "$PID_DIR/tun2socks.pid" ]; then
        kill $(cat "$PID_DIR/tun2socks.pid") 2>/dev/null || true
        rm -f "$PID_DIR/tun2socks.pid"
    fi
    pkill -f "tun2socks" 2>/dev/null || true

    # Kill hysteria
    if [ -f "$PID_DIR/hysteria.pid" ]; then
        kill $(cat "$PID_DIR/hysteria.pid") 2>/dev/null || true
        rm -f "$PID_DIR/hysteria.pid"
    fi
    pkill -f "hysteria client" 2>/dev/null || true

    sleep 1

    # Restore original gateway
    if [ -f "$PID_DIR/orig_gateway" ]; then
        ORIG_GATEWAY=$(cat "$PID_DIR/orig_gateway")
        ORIG_INTERFACE=$(cat "$PID_DIR/orig_interface")
        echo "Restoring default route to $ORIG_GATEWAY ($ORIG_INTERFACE)..."

        route delete default 2>/dev/null || true
        route add default "$ORIG_GATEWAY"

        # Remove specific route for VPS
        route delete -host "$SERVER_IP" 2>/dev/null || true

        rm -f "$PID_DIR/orig_gateway" "$PID_DIR/orig_interface"
    fi

    # Remove TUN
    if [ -f "$PID_DIR/tun_device" ]; then
        TUN=$(cat "$PID_DIR/tun_device")
        ifconfig "$TUN" down 2>/dev/null || true
        rm -f "$PID_DIR/tun_device"
    fi

    echo "✅ VPN stopped, routes restored"
}

status() {
    echo "=== Hysteria Status ==="
    if pgrep -f "hysteria client" >/dev/null; then
        echo "Hysteria client: ✅ Running"
    else
        echo "Hysteria client: ❌ Stopped"
    fi

    if pgrep -f "tun2socks" >/dev/null; then
        echo "tun2socks: ✅ Running"
    else
        echo "tun2socks: ❌ Stopped"
    fi

    if [ -f "$PID_DIR/tun_device" ]; then
        TUN=$(cat "$PID_DIR/tun_device")
        if ifconfig "$TUN" >/dev/null 2>&1; then
            echo "TUN device: ✅ $TUN active"
            ifconfig "$TUN" | grep "inet " | head -1
        fi
    fi

    echo ""
    echo "=== Routing Table ==="
    netstat -rn | grep -E "^default|^109.206" | head -3
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    restart) stop; sleep 1; start ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        exit 1
        ;;

esac