#!/usr/bin/env bash
##
## prepare_sd.sh
##
## Prepares a freshly flashed Raspberry Pi OS SD card for the mic_watch
## On Air lamp. Run this on your Mac AFTER flashing Pi OS with the
## Raspberry Pi Imager.
##
## Usage:
##   1. Flash Raspberry Pi OS Lite with Raspberry Pi Imager
##      - Enable SSH, set Wi-Fi credentials, set hostname (e.g. "onair")
##   2. Eject & re-insert the SD card
##   3. Run: bash prepare_sd.sh
##   4. Eject SD card, insert into Pi, power on
##   5. Wait ~5 minutes for first boot setup
##   6. Done! Set PI_HOST=onair.local in your Mac .env
##

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------------------------------
# Find the boot partition
# --------------------------------------------------------------------------
BOOT_DIR=""
for candidate in /Volumes/bootfs /Volumes/boot; do
  if [[ -d "$candidate" ]]; then
    BOOT_DIR="$candidate"
    break
  fi
done

if [[ -z "$BOOT_DIR" ]]; then
  echo "❌  Boot partition not found. Insert the SD card and try again."
  echo "    Expected: /Volumes/bootfs or /Volumes/boot"
  exit 1
fi

echo "✅  Found boot partition: ${BOOT_DIR}"

# --------------------------------------------------------------------------
# Copy server file
# --------------------------------------------------------------------------
echo ">>> Copying pi_server.mjs..."
cp "${SCRIPT_DIR}/pi_simulator.mjs" "${BOOT_DIR}/pi_server.mjs"

# --------------------------------------------------------------------------
# Copy firstboot script
# --------------------------------------------------------------------------
echo ">>> Copying pi_firstboot.sh..."
cp "${SCRIPT_DIR}/pi_firstboot.sh" "${BOOT_DIR}/pi_firstboot.sh"

# --------------------------------------------------------------------------
# Create a cron-based trigger for firstboot
# --------------------------------------------------------------------------
echo ">>> Creating firstboot trigger (rc.local)..."

# userconf.txt was already created by Pi Imager, don't overwrite.
# Instead, add a firstrun.sh hook via cmdline.txt modification or
# create a simple systemd oneshot that calls our script.

cat > "${BOOT_DIR}/mic_watch_firstboot.service" <<'EOF'
[Unit]
Description=mic_watch first boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/boot/firmware/pi_firstboot.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /boot/firmware/pi_firstboot.sh
ExecStartPost=/bin/rm -f /etc/systemd/system/multi-user.target.wants/mic_watch_firstboot.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service by symlinking it into the rootfs.
# Since we only have access to the boot partition, we use a different approach:
# Place a script that the Pi's firstrun mechanism will pick up.

cat > "${BOOT_DIR}/firstrun_micwatch.sh" <<'FIRSTRUN'
#!/usr/bin/env bash
# Called once by the Pi on first boot to enable our setup service
cp /boot/firmware/mic_watch_firstboot.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable mic_watch_firstboot.service
systemctl start mic_watch_firstboot.service
FIRSTRUN

chmod +x "${BOOT_DIR}/firstrun_micwatch.sh"

echo ""
echo "============================================"
echo "  SD card prepared!"
echo "============================================"
echo ""
echo "  Files copied to ${BOOT_DIR}:"
echo "    - pi_server.mjs"
echo "    - pi_firstboot.sh"
echo "    - mic_watch_firstboot.service"
echo "    - firstrun_micwatch.sh"
echo ""
echo "  Next steps:"
echo "    1. Eject the SD card"
echo "    2. Insert into Raspberry Pi"
echo "    3. Power on and wait ~5 minutes"
echo "    4. SSH into the Pi: ssh pi@onair.local"
echo "    5. Check: sudo systemctl status mic-watch"
echo ""
echo "  After the Pi is running, set on your Mac:"
echo "    PI_HOST=onair.local"
echo "    PI_PORT=8080"
echo ""
