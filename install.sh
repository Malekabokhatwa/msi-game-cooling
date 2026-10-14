#!/usr/bin/env bash
# Install msi-game-cooling: the script, its systemd unit, and (on Arch) the
# upstream msi-ec driver it needs for Cooler Boost. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

say() { echo "==> $*"; }

[[ -e /sys/class/powercap/intel-rapl:0 ]] || sudo modprobe intel_rapl_msr
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found: this needs the NVIDIA driver." >&2; exit 1; }

# Cooler Boost goes through msi-ec. The in-kernel copy may not know your EC
# firmware; the upstream one (github.com/BeardOverflow/msi-ec) usually does.
if [[ ! -e /sys/devices/platform/msi-ec/cooler_boost ]]; then
  sudo modprobe msi_ec 2>/dev/null || true
fi
if [[ ! -e /sys/devices/platform/msi-ec/cooler_boost ]]; then
  if command -v yay >/dev/null; then
    say "installing msi-ec-dkms-git (upstream msi-ec driver) from the AUR"
    yay -S --needed msi-ec-dkms-git
    sudo modprobe -r msi_ec 2>/dev/null || true
    sudo modprobe msi_ec
  fi
fi
if [[ -e /sys/devices/platform/msi-ec/cooler_boost ]]; then
  say "msi-ec loaded, EC firmware $(cat /sys/devices/platform/msi-ec/fw_version)"
else
  echo "msi-ec does not support this laptop's EC firmware (see 'sudo dmesg | grep msi_ec')." >&2
  echo "Not installing: without it there is no Cooler Boost, which is the main fix." >&2
  exit 1
fi

say "installing /usr/local/bin/msi-game-cooling and its systemd unit"
sudo install -Dm755 msi-game-cooling /usr/local/bin/msi-game-cooling
sudo install -Dm644 msi-game-cooling.service /etc/systemd/system/msi-game-cooling.service
sudo systemctl daemon-reload
sudo systemctl enable msi-game-cooling.service
sudo systemctl restart msi-game-cooling.service
say "done. Watch it work while you play:  journalctl -fu msi-game-cooling"
