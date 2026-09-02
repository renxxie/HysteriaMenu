#!/bin/bash
# hyvpn - Hysteria2 VPN control (alternative to menu bar app)
# Usage: hyvpn {start|stop|status}

HELPER="$HOME/Library/Application Support/HysteriaMenu/hysteria-helper.sh"

# Fallback to old location if new doesn't exist
if [ ! -x "$HELPER" ]; then
    HELPER="/tmp/hysteria-menu/hysteria-helper.sh"
fi

case "${1:-}" in
    start)
        echo "Starting VPN..."
        # Properly quote the path to handle spaces
        osascript -e "do shell script quoted form of \"$HELPER\" & \" start\" with administrator privileges"
        ;;

    stop)
        echo "Stopping VPN..."
        osascript -e "do shell script quoted form of \"$HELPER\" & \" stop\" with administrator privileges"
        ;;

    status)
        if pgrep -x hysteria >/dev/null && pgrep -x tun2socks >/dev/null; then
            echo "VPN Status: ✅ Connected"
            IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
            echo "Public IP: $IP"
        else
            echo "VPN Status: ❌ Disconnected"
            IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
            echo "Real IP: $IP"
        fi
        ;;

    *)
        echo "Usage: hyvpn {start|stop|status}"
        ;;
esac