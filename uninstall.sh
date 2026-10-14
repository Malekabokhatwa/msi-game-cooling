#!/usr/bin/env bash
# Remove msi-game-cooling. Stopping the service turns Cooler Boost off and
# restores the CPU power limits it found at boot. The msi-ec driver is left
# installed (remove it with: sudo pacman -R msi-ec-dkms-git).
set -euo pipefail
sudo systemctl disable --now msi-game-cooling.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/msi-game-cooling.service /usr/local/bin/msi-game-cooling /run/msi-game-cooling.state /run/msi-game-cooling.orig
sudo systemctl daemon-reload
echo "==> msi-game-cooling removed"
