#!/usr/bin/env bash
##
## pi_setup.sh
##
## Sets up a Raspberry Pi from scratch to run the mic_watch On Air lamp server.
## Installs Node.js, uhubctl, deploys the server, and creates a systemd service.
##
## Usage (on the Pi):
##   curl -sSL <raw-url>/pi_setup.sh | bash
##   # or after cloning:
##   chmod +x pi_setup.sh && ./pi_setup.sh
##
## Prerequisites:
##   - Raspberry Pi OS (Bookworm / Bullseye)
##   - Internet connection
##   - USB LED lamp plugged in
##

set -euo pipefail

APP_DIR="/opt/mic_watch"
SERVICE_NAME="mic-watch"
NODE_MAJOR=20

echo "============================================"
echo "  mic_watch – Raspberry Pi Setup"
echo "============================================"
echo ""

# --------------------------------------------------------------------------
# 1) System update
# --------------------------------------------------------------------------
echo ">>> Updating system packages..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

# --------------------------------------------------------------------------
# 2) Install Node.js (via NodeSource)
# --------------------------------------------------------------------------
if command -v node &>/dev/null; then
  echo ">>> Node.js already installed: $(node -v)"
else
  echo ">>> Installing Node.js ${NODE_MAJOR}.x..."
  sudo apt-get install -y -qq ca-certificates curl gnupg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq nodejs
  echo ">>> Node.js installed: $(node -v)"
fi

# --------------------------------------------------------------------------
# 3) Install uhubctl
# --------------------------------------------------------------------------
if command -v uhubctl &>/dev/null; then
  echo ">>> uhubctl already installed: $(uhubctl -v 2>&1 | head -1)"
else
  echo ">>> Building uhubctl from source..."
  sudo apt-get install -y -qq libusb-1.0-0-dev git make gcc
  UHUB_TMP=$(mktemp -d)
  git clone --depth 1 https://github.com/mvp/uhubctl.git "$UHUB_TMP"
  make -C "$UHUB_TMP"
  sudo cp "$UHUB_TMP/uhubctl" /usr/local/bin/
  rm -rf "$UHUB_TMP"
  echo ">>> uhubctl installed"
fi

# --------------------------------------------------------------------------
# 4) Detect USB hub location
# --------------------------------------------------------------------------
echo ""
echo ">>> Detecting USB hubs..."
echo ""
sudo uhubctl || true
echo ""
echo "NOTE: Check the output above for your USB hub location (e.g. '1-1')."
echo "You will need this for the LAMP_CMD_ON/OFF settings in .env."
echo ""

# --------------------------------------------------------------------------
# 5) Deploy application
# --------------------------------------------------------------------------
echo ">>> Deploying application to ${APP_DIR}..."
sudo mkdir -p "$APP_DIR"
sudo cp -v pi_simulator.mjs "$APP_DIR/pi_server.mjs"

if [[ -f "$APP_DIR/.env" ]]; then
  echo ">>> .env already exists in ${APP_DIR} – keeping it"
else
  cat <<'ENVFILE' | sudo tee "$APP_DIR/.env" > /dev/null
PI_HOST=0.0.0.0
PI_PORT=8080
POLL_INTERVAL=0.5

# Adjust the -l parameter to match your USB hub location (run: sudo uhubctl)
LAMP_CMD_ON=sudo uhubctl -l 1-1 -a on
LAMP_CMD_OFF=sudo uhubctl -l 1-1 -a off
ENVFILE
  echo ">>> Created ${APP_DIR}/.env with default uhubctl commands"
fi

# --------------------------------------------------------------------------
# 6) Allow uhubctl without password (sudoers)
# --------------------------------------------------------------------------
echo ">>> Configuring passwordless sudo for uhubctl..."
SUDOERS_FILE="/etc/sudoers.d/uhubctl"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "ALL ALL=(root) NOPASSWD: /usr/local/bin/uhubctl" \
    | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 0440 "$SUDOERS_FILE"
  echo ">>> Sudoers rule created"
else
  echo ">>> Sudoers rule already exists"
fi

# --------------------------------------------------------------------------
# 7) Create systemd service
# --------------------------------------------------------------------------
echo ">>> Creating systemd service '${SERVICE_NAME}'..."
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
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

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Service:  sudo systemctl status ${SERVICE_NAME}"
echo "  Logs:     sudo journalctl -u ${SERVICE_NAME} -f"
echo "  Config:   ${APP_DIR}/.env"
echo ""
echo "  Test lamp:"
echo "    sudo uhubctl -l 1-1 -a on   # lamp on"
echo "    sudo uhubctl -l 1-1 -a off  # lamp off"
echo ""
echo "  Test HTTP:"
echo "    curl http://localhost:8080/on"
echo "    curl http://localhost:8080/off"
echo "    curl http://localhost:8080/status"
echo ""
echo "  On your Mac, set PI_HOST to this Pi's IP in .env"
echo "  and run: swift mic_watch.swift"
echo ""
