# msi-game-cooling

**Stops MSI gaming laptops on Linux from overheating and hard-powering-off mid-game.**

While a game runs on the NVIDIA GPU, it does what MSI Center does on Windows:

- turns on **Cooler Boost** (both fans at full speed), and
- puts the CPU on **MSI's own "NVIDIA GPU active" power limits** (30 W / 30 W).

When the GPU goes idle again, it puts both back. Your fps don't change: the GPU keeps its full power, and the CPU limit is the one MSI's firmware specifies for gaming on the dGPU.

Tested on an **MSI Cyborg 15 A13VE** (MS-15K1, i7-13620H + RTX 4050 Laptop, EC firmware `15K1IMS1.110`, BIOS E15K1IMS.10E) on Arch Linux. It probably also helps other MSI laptops with the same EC firmware family (`15K1IMS1.110`–`.113`: Cyborg 15 A12V/A13V); see [Other models](#other-models).

## Symptoms

- After 15–30 minutes of a demanding game, the whole system starts lagging. Even the mouse cursor drops to 10–20 fps.
- The fans are loud, but not as loud as they can go.
- Then the laptop **switches off instantly**, as if you held the power button.
- `journalctl -b -1` just stops: no kernel panic, no shutdown sequence. The embedded controller (EC) cut the power.
- Sometimes it fails as NVIDIA `Xid 79, GPU has fallen off the bus` instead.
- The owner reports it doesn't happen on Windows.

## Root cause

There are two parts, both firmware behavior that only MSI Center adjusts on Windows.

### 1. The EC's factory fan curve stops at 78 %

The EC stores two seven-point fan curves (temperature → duty): CPU at `0x6A`–`0x78`, GPU at `0x82`–`0x90`. Out of the box both top out at **78 %, even at 100 °C**:

```
CPU temps  0x6A: 51 58 65 73 78 83 100      CPU fan%  0x72: 38 40 45 54 60 68 78
GPU temps  0x82: 43 48 53 58 65 70 100      GPU fan%  0x8A: 38 40 45 54 60 68 78
```

78 % is about 4,700 RPM. With **Cooler Boost** the fans run at about **6,200 RPM**. Nothing on Linux ever turns Cooler Boost on or changes the curve, so in a long game the EC sensors keep climbing. The ACPI zones are `SEN2`/`SEN3`/`SEN4`, with trip points passive 65 °C / hot 75 °C / critical 80 °C. They climb past 90 °C until the EC slams the brakes on everything (the lag) and then cuts power.

This was independently found by another A13VE owner in [msi-ec issue #848](https://github.com/BeardOverflow/msi-ec/issues/848).

### 2. Linux runs the CPU on the "iGPU only" power profile, even in games

MSI's DPTF tables (read by `thermald --adaptive`) contain separate CPU limits for when the NVIDIA GPU is active:

| MSI firmware profile | CPU PL1 | CPU PL2 |
|---|---|---|
| AC balance_discrete (NVIDIA GPU active) | 30 W | 30 W |
| AC performance_discrete | 45 W | 45 W |
| **AC balance_uma (Intel iGPU only), which Linux uses** | **45 W** | **70 W** |

Windows chooses the profile from an "Oem1" flag that MSI Center sets. Linux never sets it, and it can't be set from userspace (the `odvp*` sysfs files are read-only). So the CPU keeps its 70 W boost while the GPU also dumps 35–45 W into the **shared heatpipes**. In testing, that burst took the CPU to 95 °C in 17 seconds, even with Cooler Boost on. thermald does drop the CPU to 30 W eventually, but only after the chassis is already hot.

## What it does

`msi-game-cooling` is a small bash service. Every 5 seconds it reads the GPU's power draw with `nvidia-smi`.

- **GPU at or above 12 W for 10 s (a game is running):**
  - Cooler Boost on, through the upstream [msi-ec](https://github.com/BeardOverflow/msi-ec) driver
  - CPU RAPL limits set to 30/30 W
  - temperatures, CPU watts and fan RPM logged once a minute
  - all of this re-applied every sample, in case the firmware or a suspend/resume resets it
- **GPU under 12 W for 60 s:** Cooler Boost off, and the CPU limits it found at boot restored. An open Steam client keeps the GPU at 3–10 W, so that still counts as idle.
- **Service stopped:** same restore.

Notes:
- The service only touches the **MSR** RAPL limits (`intel-rapl:0`). thermald keeps owning the MMIO ones, and the lower of the two always wins, so they never fight.
- It starts after `graphical.target`, so it never competes with the display manager at boot.

## Test results

Same laptop, room temperature, plugged in. The load was `glmark2` on the NVIDIA GPU (40–45 W, harder than a game) plus `stress-ng` on every CPU core. A watchdog aborted any run where an EC sensor reached 85 °C.

| Setup | EC sensors SEN3/SEN4 | CPU | GPU | Result |
|---|---|---|---|---|
| Stock fans, CPU 30 W | 85 °C at 130 s and still rising | 89 °C | 79 °C | **aborted** (would have reached the cutoff) |
| Cooler Boost, stock CPU limits (70 W burst) | – | 95 °C in 17 s | – | **aborted** |
| **Cooler Boost + CPU 30 W** (this tool) | **plateau 77–79 °C** | 84 °C | 74 °C | **passed 10 min** |
| Cooler Boost + CPU 30 W, second run | plateau 77–80 °C | 84 °C | 75 °C | passed 9 min |

There was also a **real game test**. The game, *Sort The Capybaras* (Unreal Engine 5, all Ultra, Proton), had shut the laptop down twice that day after 17 and 28 minutes. With the service installed and acting on its own, it ran **26 minutes**:
- EC sensors flat at **81–83 °C** for the last 20 minutes; the crashed sessions sat at 92–93 °C before the power cut
- GPU 40 W / 77 °C, CPU 84 °C on average
- **no shutdown**

## Install

Requirements:
- Linux with systemd
- the NVIDIA proprietary or open driver (`nvidia-smi`)
- an Intel CPU with RAPL
- an MSI laptop whose EC firmware the upstream [msi-ec](https://github.com/BeardOverflow/msi-ec) driver supports

```bash
git clone https://github.com/Malekabokhatwa/msi-game-cooling.git
cd msi-game-cooling
./install.sh
```

`install.sh`:
1. Loads `msi_ec`. If the in-kernel driver doesn't know your firmware, it installs `msi-ec-dkms-git` from the AUR with `yay` (on other distros, install msi-ec from its repo first).
2. **Refuses to continue** if msi-ec still doesn't support your EC firmware.
3. Installs `/usr/local/bin/msi-game-cooling` and enables `msi-game-cooling.service`.

Watch it while you play:

```bash
journalctl -fu msi-game-cooling
```

```
NVIDIA GPU busy (39W): Cooler Boost on, CPU limits -> 30/30W (MSI balance_discrete)
temps: cpu=74C cpu_draw=29W gpu=69C gpu_draw=39W SEN2=62C SEN3=72C SEN4=73C THRM=78C fan=6233rpm cooler_boost=on cpu_limits=30/30W
...
restored: Cooler Boost off, CPU limits PL1=80W PL2=160W
```

Uninstall with `./uninstall.sh`. It turns Cooler Boost off and restores the CPU limits.

## Is it safe?

- **EC writes:** the only one is the Cooler Boost bit (`0x98` bit 7). It goes through msi-ec's sysfs file, which refuses to load on firmware it doesn't know. It's the same Cooler Boost feature MSI exposes on Windows, at the register msi-ec maps for this firmware.
- **CPU limits:** these are standard Linux powercap sysfs writes, restored on stop. The value comes from MSI's own firmware tables.
- **Noise:** Cooler Boost is loud. That's the trade for not shutting down; it only runs while the GPU is busy.
- **`tools/thermal-test.sh`:** the watchdog used for the tests above. It reads the EC read-only and kills the load before anything gets close to the cutoff. Use it to check your own laptop before and after:

  ```bash
  sudo tools/thermal-test.sh mytest 600 runuser -u $USER -- env DISPLAY=$DISPLAY \
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
    bash -c 'glmark2 --off-screen --run-forever -b terrain & stress-ng --cpu 0 & wait'
  ```

## Things that did *not* help

- **CPU power cap alone (30 W).** It still shut down after 28 minutes. The fans are the main problem.
- **`pcie_aspm=off pcie_port_pm=off nvidia.NVreg_DynamicPowerManagement=0x00`** for the Xid 79s. The GPU still fell off the bus. The Xid 79s were most likely the same overheating; they happened during the same kind of long gaming sessions.
- **Turning Cooler Boost *off* in MSI Center.** It was already off; that's the problem.
- **The `ACPI BIOS Error: Could not resolve symbol [\_TZ.ETMD]` message.** It's a harmless firmware bug common to many laptops.

## Other models

The fan-curve cap and the DPTF profile split are MSI firmware behavior, so other MSI laptops may have the same problem. Before installing on a different model:

1. Check that msi-ec supports your firmware: `cat /sys/devices/platform/msi-ec/fw_version` exists after `sudo modprobe msi_ec`.
2. Run `tools/thermal-test.sh` without the service, then with it, and compare.
3. Check your DPTF table's discrete-GPU CPU limit: `sudo systemctl stop thermald; sudo thermald --no-daemon --adaptive --loglevel=info` (look for `name:AC balance_discrete ... PL1MAX`), then `sudo systemctl start thermald`. Change `GAME_W` in the script if yours differs.

## Credits

- [msi-ec](https://github.com/BeardOverflow/msi-ec) for the EC driver and register maps, and [issue #848](https://github.com/BeardOverflow/msi-ec/issues/848) for the fan-curve finding.
- [intel/thermal_daemon](https://github.com/intel/thermal_daemon), whose adaptive-mode log exposed MSI's DPTF profiles.

## License

MIT
