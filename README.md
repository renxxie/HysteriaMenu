# HysteriaMenu

A lightweight macOS menu bar app for managing a full-tunnel Hysteria2 VPN connection.

## Features

- 🛡 **Menu bar app** — One-click connect/disconnect from your menu bar
- 🔒 **Full tunnel** — All traffic (including DNS) goes through the VPN
- 🚀 **QUIC-based** — Built on Hysteria2 for fast handshakes and low latency
- 📦 **Self-contained** — Binaries bundled inside the .app
- ⚡ **Fast** — Replaces AmneziaWG for better DPI resistance
- 🔐 **Touch ID support** — Via osascript subprocess (system-signed)

## Architecture

```
┌─────────────────────────────────────────┐
│ HysteriaMenu.app/                       │
│ ├── MacOS/HysteriaMenu   (Swift UI)     │
│ └── Resources/                          │
│     ├── hysteria          (QUIC client) │
│     ├── tun2socks         (TUN bridge)  │
│     └── hysteria-helper.sh (TUN setup)  │
└─────────────────────────────────────────┘
            │
            │ spawns (osascript)
            ▼
   ~/Library/Application Support/
   └── HysteriaMenu/hysteria-helper.sh
            │
            │ creates
            ▼
   TUN device (utun8) → all traffic → VPS
```

## Prerequisites

- macOS 12.0+
- A VPS running Hysteria2 server (see [server setup](#server-setup))
- Xcode Command Line Tools (`xcode-select --install`)

## Installation

### 1. Clone the repo
```bash
git clone https://github.com/YOUR_USERNAME/HysteriaMenu.git
cd HysteriaMenu
```

### 2. Download dependencies
```bash
./download-deps.sh
```

### 3. Build the app
```bash
./build.sh
```
This creates `~/Applications/HysteriaMenu.app`

### 4. Configure
```bash
mkdir -p ~/Library/Application\ Support/Hysteria
cp config.example.yaml ~/Library/Application\ Support/Hysteria/config.yaml
# Edit the file with your server IP and password
nano ~/Library/Application\ Support/Hysteria/config.yaml
```

### 5. Optional: Install CLI helper
```bash
cp hyvpn.sh ~/bin/hyvpn   # or anywhere in PATH
chmod +x ~/bin/hyvpn
```

## Usage

### Menu bar app
Click the 🛡 icon in your menu bar → **Connect** → enter password (or use Touch ID if prompted)

### Command line
```bash
hyvpn start    # Connect
hyvpn stop     # Disconnect
hyvpn status   # Check
```

## Configuration

### Client config (`~/Library/Application Support/Hysteria/config.yaml`)
See `config.example.yaml` for the template. Key fields:
- `server`: Your VPS IP:port
- `auth`: Password matching server config

### Server IP override
You can override the server IP used for routing via environment variable:
```bash
HYSTERIA_SERVER_IP="1.2.3.4" hyvpn start
```

## Server Setup

On your VPS (Ubuntu example):
```bash
# Install hysteria server
curl -L -o /usr/local/bin/hysteria https://get.hy2.sh/
chmod +x /usr/local/bin/hysteria

# Create config
cat > /etc/hysteria/config.yaml <<EOF
listen: 0.0.0.0:8443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: YOUR_PASSWORD_HERE

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

# Generate self-signed cert
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

# Run as service
systemctl enable --now hysteria-server
```

For production, use a real domain and Let's Encrypt cert.

## How It Works

1. **App launch** → Spawns `osascript` (signed system binary) to run helper script with admin privileges
2. **Helper script** → Creates TUN device, configures routes, starts hysteria + tun2socks
3. **tun2socks** → Reads packets from TUN, forwards through SOCKS5 to hysteria
4. **hysteria** → QUIC connection to VPS, masks traffic as HTTPS
5. **All app traffic** → Goes through TUN → VPS → internet

## Troubleshooting

### Menu bar icon not visible
macOS menu bar may be full. Check for `•••` overflow indicator at far right.

### Permission denied
The script needs sudo for TUN/routing. macOS will prompt for password.

### DNS leaks
The TUN device captures DNS queries. If you have issues, check that `/etc/resolver` is writable.

### Hysteria client fails
- Check your server is reachable: `nc -zv YOUR_IP 8443`
- Verify password matches server config
- Check logs: `cat ~/Library/Logs/HysteriaMenu/hysteria.log`

## Security Notes

- Helper script is stored in `~/Library/Application Support/HysteriaMenu/` (user-only)
- Self-signed TLS cert on server (replace with real cert for production)
- Touch ID supported when running via osascript subprocess
- App is ad-hoc signed (no Developer ID required)

## License

MIT

## Credits

- [Hysteria2](https://github.com/apernet/hysteria) — QUIC-based proxy
- [tun2socks](https://github.com/xjasonlyu/tun2socks) — TUN to SOCKS5 bridge
- Built with SwiftUI for macOS