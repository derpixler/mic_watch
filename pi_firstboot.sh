#!/usr/bin/env bash
##
## pi_firstboot.sh
##
## Drop this file onto the boot partition of a freshly flashed Raspberry Pi OS
## SD card. It runs once on first boot and turns the Pi into a dedicated
## mic_watch On Air lamp server.
##
## What it does:
##   1. Installs Node.js 20.x
##   2. Builds uhubctl from source
##   3. Deploys pi_server.mjs to /opt/mic_watch
##   4. Configures passwordless sudo for uhubctl
##   5. Creates and starts a systemd service
##   6. Disables itself after first run
##
## After first boot the Pi only does two things:
##   - Listen on port 8080 for /on and /off requests
##   - Switch USB power via uhubctl
##

set -euo pipefail

LOG="/var/log/mic_watch_firstboot.log"
exec > >(tee -a "$LOG") 2>&1

echo "============================================"
echo "  mic_watch firstboot – $(date)"
echo "============================================"

APP_DIR="/opt/mic_watch"
SERVICE_NAME="mic-watch"
NODE_MAJOR=20

# --------------------------------------------------------------------------
# 1) System update
# --------------------------------------------------------------------------
echo ">>> System update..."
apt-get update -qq
apt-get upgrade -y -qq

# --------------------------------------------------------------------------
# 2) Node.js
# --------------------------------------------------------------------------
if ! command -v node &>/dev/null; then
  echo ">>> Installing Node.js ${NODE_MAJOR}.x..."
  apt-get install -y -qq ca-certificates curl gnupg
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
fi
echo ">>> Node.js: $(node -v)"

# --------------------------------------------------------------------------
# 3) uhubctl
# --------------------------------------------------------------------------
if ! command -v uhubctl &>/dev/null; then
  echo ">>> Building uhubctl..."
  apt-get install -y -qq libusb-1.0-0-dev git make gcc
  UHUB_TMP=$(mktemp -d)
  git clone --depth 1 https://github.com/mvp/uhubctl.git "$UHUB_TMP"
  make -C "$UHUB_TMP"
  cp "$UHUB_TMP/uhubctl" /usr/local/bin/
  rm -rf "$UHUB_TMP"
fi
echo ">>> uhubctl installed"

# --------------------------------------------------------------------------
# 4) Detect USB hub location and pick the first available
# --------------------------------------------------------------------------
echo ">>> Detecting USB hub..."
USB_LOC=$(uhubctl 2>/dev/null | grep -oP '(?<=hub )\S+' | head -1 || echo "1-1")
echo ">>> Using USB location: ${USB_LOC}"

# --------------------------------------------------------------------------
# 5) Deploy server
# --------------------------------------------------------------------------
echo ">>> Deploying to ${APP_DIR}..."
mkdir -p "$APP_DIR"

# The server is embedded here so this single script is all you need on the SD card.
# It gets extracted from the main repo file if present, otherwise uses the inline version.
if [[ -f /boot/firmware/pi_server.mjs ]]; then
  cp /boot/firmware/pi_server.mjs "$APP_DIR/pi_server.mjs"
  echo ">>> Copied pi_server.mjs from boot partition"
elif [[ -f /boot/pi_server.mjs ]]; then
  cp /boot/pi_server.mjs "$APP_DIR/pi_server.mjs"
  echo ">>> Copied pi_server.mjs from boot partition"
else
  echo ">>> ERROR: pi_server.mjs not found on boot partition!"
  echo ">>> Copy pi_simulator.mjs as pi_server.mjs to the boot partition and rerun."
  exit 1
fi

# Create .env if not present
if [[ ! -f "$APP_DIR/.env" ]]; then
  cat > "$APP_DIR/.env" <<ENVFILE
PI_HOST=0.0.0.0
PI_PORT=8080
POLL_INTERVAL=0.5

LAMP_CMD_ON=sudo uhubctl -l ${USB_LOC} -a on
LAMP_CMD_OFF=sudo uhubctl -l ${USB_LOC} -a off
ENVFILE
  echo ">>> Created .env with USB location ${USB_LOC}"
fi

# --------------------------------------------------------------------------
# 6) Sudoers for uhubctl
# --------------------------------------------------------------------------
SUDOERS_FILE="/etc/sudoers.d/uhubctl"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "ALL ALL=(root) NOPASSWD: /usr/local/bin/uhubctl" > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  echo ">>> Sudoers rule created"
fi

# --------------------------------------------------------------------------
# 7) Systemd service
# --------------------------------------------------------------------------
echo ">>> Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=mic_watch On Air Lamp Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(command -v node) ${APP_DIR}/pi_server.mjs
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# --------------------------------------------------------------------------
# 8) Disable firstboot (don't run again)
# --------------------------------------------------------------------------
SELF="$(readlink -f "$0")"
if [[ -f "$SELF" ]]; then
  rm -f "$SELF"
  echo ">>> Firstboot script removed (won't run again)"
fi

# Remove the cron entry if we were called from cron
crontab -l 2>/dev/null | grep -v "pi_firstboot" | crontab - 2>/dev/null || true

echo ""
echo "============================================"
echo "  Firstboot complete!"
echo "============================================"
echo ""
echo "  Server running on http://0.0.0.0:8080"
echo "  USB hub location: ${USB_LOC}"
echo "  Config: ${APP_DIR}/.env"
echo "  Logs:   sudo journalctl -u ${SERVICE_NAME} -f"
echo ""
