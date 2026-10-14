# msi-game-cooling

**Stops MSI gaming laptops on Linux from overheating and hard-powering-off mid-game.**

**The fans stay completely stock.** While a game runs on the NVIDIA GPU, it holds MSI's embedded-controller (EC) temperature sensors under a target. It trims CPU power and caps GPU clocks only as far as that takes, and gives the performance back as things cool down. This is what Intel's DTT "passive policy" does on Windows; nothing on Linux does it.

- **Anything that keeps the EC sensors under 82 °C:** full performance. The CPU runs at MSI's own "NVIDIA GPU active" limit (30 W) and the GPU is untouched.
- **Long, heavy Ultra sessions:** the GPU clock and CPU power step down until the heat fits what the stock fans can move.
- **Emergency:** Cooler Boost turns on only if the sensors still reach 88 °C. It should never happen.

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

### 1. The stock fans can't move that much heat

The EC stores two seven-point fan curves (temperature → duty): CPU at `0x6A`–`0x78`, GPU at `0x82`–`0x90`. Out of the box both top out at **78 %, even at 100 °C**:

```
CPU temps  0x6A: 51 58 65 73 78 83 100      CPU fan%  0x72: 38 40 45 54 60 68 78
GPU temps  0x82: 43 48 53 58 65 70 100      GPU fan%  0x8A: 38 40 45 54 60 68 78
```

In MSI's default **Balanced** shift mode ("comfort") the EC also caps the fans at about **3,600 RPM**, whatever the curve says. With Cooler Boost or the "turbo" shift mode they reach about 6,000–6,200 RPM, but that's loud: a jet engine for the whole session. With stock fans and a game pulling CPU 30 W + GPU 40 W, the EC sensors keep climbing. The ACPI zones are `SEN2`/`SEN3`/`SEN4`, with trip points passive 65 °C / hot 75 °C / critical 80 °C. They climb past 90 °C until the EC slams the brakes on everything (the lag) and then cuts power.

This was independently found by another A13VE owner in [msi-ec issue #848](https://github.com/BeardOverflow/msi-ec/issues/848).

### 2. Linux runs the CPU on the "iGPU only" power profile, even in games

MSI's DPTF tables (read by `thermald --adaptive`) contain separate CPU limits for when the NVIDIA GPU is active:

| MSI firmware profile | CPU PL1 | CPU PL2 |
|---|---|---|
| AC balance_discrete (NVIDIA GPU active) | 30 W | 30 W |
| AC performance_discrete | 45 W | 45 W |
| **AC balance_uma (Intel iGPU only), which Linux uses** | **45 W** | **70 W** |

Windows chooses the profile from an "Oem1" flag that MSI Center sets. Linux never sets it, and it can't be set from userspace (the `odvp*` sysfs files are read-only). So the CPU keeps its 70 W boost while the GPU also dumps 35–45 W into the **shared heatpipes**. In testing, that burst took the CPU to 95 °C in 17 seconds, even with Cooler Boost on. thermald does drop the CPU to 30 W eventually, but only after the chassis is already hot.

## What it does (and what it leaves alone)

`msi-game-cooling` is a small bash service. Every 5 seconds it reads the GPU's power draw with `nvidia-smi`.

- **GPU at or above 12 W for 10 s (a game is running):** it watches the hottest EC sensor (`SEN2`/`SEN3`/`SEN4`) and moves through levels:

  | Level | CPU limit | GPU max clock |
  |---|---|---|
  | 0 | 30 W | uncapped |
  | 1–5 | 27 → 21 W | 2400 → 1600 MHz |
  | 6–10 | 20 W | 1450 → 900 MHz |

  - **Down one level** every 15 s while at or above 82 °C; every 5 s at or above 84 °C; early when within 2 °C of 82 and rising fast.
  - **Up one level** only after a full minute at or below 78 °C, so it settles instead of flapping.
  - The CPU never goes below 20 W. At 15 W a UE5 game plus the desktop starved input: keys repeated by themselves.
- **GPU under 12 W for 60 s:** CPU limits restored to what it found at boot, and GPU clocks uncapped. An open Steam client keeps the GPU at 3–10 W, so that still counts as idle.
- **Emergency:** Cooler Boost (through the upstream [msi-ec](https://github.com/BeardOverflow/msi-ec) driver) turns on at 88 °C and off at 80 °C, in or out of a game.
- **Stopped, crashed or restarted:** the same restore (an `EXIT` trap, plus a restore at every start).
- **Logging:** temperatures, CPU watts, GPU clock and fan RPM once a minute while gaming, and every level change.

Notes:
- **Fans:** never touched. The shift mode, fan mode and fan curve stay at the factory settings.
- **GPU clocks:** capped with `nvidia-smi -lgc`. The GPU power limit (`-pl`) is locked on laptops.
- The service only touches the **MSR** RAPL limits (`intel-rapl:0`). thermald keeps owning the MMIO ones, and the lower of the two always wins, so they never fight.
- It starts after `graphical.target`, so it never competes with the display manager at boot.

## Test results

Same laptop, room temperature, plugged in, **stock fans**. The game was *Sort The Capybaras* (Unreal Engine 5, all Ultra, Proton, GPU about 40 W). Before this tool it shut the laptop down twice in one day, after 17 and 28 minutes. A watchdog (`tools/thermal-test.sh`) would have stopped any run whose EC sensors reached 88 °C.

| Setup | Hottest EC sensor | Fans | Result |
|---|---|---|---|
| Stock fans, no tool (the crashes) | 92–93 °C for ~15 min | stock | **power cut** |
| Stock fans, CPU held at 30 W only | 85 °C at 2 min, still rising | stock | aborted |
| Cooler Boost on while gaming (an earlier version) | 81–83 °C | ~6,200 RPM the whole time | passed, but a jet engine |
| **This tool, 20 min** | **79–80 °C after warm-up** (85 °C peak at 1.5 min) | **stock, max 78 % (~3,600 RPM)** | **passed** |

With this tool the heaviest Ultra scenes settled at **CPU 20 W and GPU about 1,300 MHz / 24 W** (uncapped it runs about 1,850 MHz / 40 W). It reached that level once and stayed there for 16 minutes. That fps cut is the price of stock fans in the heaviest scenes, and it only applies while the sensors are at the limit. Games and scenes that keep the sensors under 82 °C stay at level 0 by design (not separately tested). The emergency Cooler Boost never fired.

## Install

Requirements:
- Linux with systemd
- the NVIDIA proprietary or open driver (`nvidia-smi`)
- an Intel CPU with RAPL
- an MSI laptop that exposes the EC sensor zones `SEN2`-`SEN4` (and, for the emergency brake, an EC firmware the upstream [msi-ec](https://github.com/BeardOverflow/msi-ec) driver supports)

```bash
git clone https://github.com/Malekabokhatwa/msi-game-cooling.git
cd msi-game-cooling
./install.sh
```

`install.sh`:
1. Loads `msi_ec` for the emergency Cooler Boost. If the in-kernel driver doesn't know your firmware, it installs `msi-ec-dkms-git` from the AUR with `yay` (on other distros, install msi-ec from its repo first). Without it, everything except the emergency brake still works; it warns you.
2. Warns if the MSI EC sensor zones (`SEN2`-`SEN4`) aren't there, since that's what the controller watches.
3. Installs `/usr/local/bin/msi-game-cooling` and enables `msi-game-cooling.service`.

Watch it while you play:

```bash
journalctl -fu msi-game-cooling
```

```
NVIDIA GPU busy (39W): holding EC sensors under 82C, start at L0 (CPU 30W, GPU uncapped)
EC sensors 80C, rising: step down to L1 (CPU 27W, GPU max 2400MHz)
...
temps: cpu=82C cpu_draw=20W gpu=75C gpu_draw=24W gpu_clock=1290MHz SEN2=72 SEN3=79 SEN4=80 THRM=87C fan=3609rpm level=L7 (CPU 20W, GPU max 1300MHz)
back to stock: CPU limits 80/160W, GPU clocks uncapped
```

Uninstall with `./uninstall.sh`. Stopping the service restores the CPU limits and uncaps the GPU.

## Is it safe?

- **Fans and EC:** nothing is written to the EC in normal use. The only EC write is the emergency Cooler Boost bit (`0x98` bit 7), through msi-ec's sysfs file, which refuses to load on firmware it doesn't know.
- **CPU limits and GPU clocks:** standard Linux powercap sysfs writes and `nvidia-smi -lgc`. They are restored when the game ends, on stop, and at every start (in case of a crash).
- **Timeouts:** `nvidia-smi` calls are wrapped in `timeout`, so a hung driver can't stall the controller.
- **`tools/thermal-test.sh`:** the watchdog used for the tests above. It reads the EC read-only and kills the load before anything gets close to the cutoff. Use it to check your own laptop before and after:

  ```bash
  sudo tools/thermal-test.sh mytest 600 runuser -u $USER -- env DISPLAY=$DISPLAY \
    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
    bash -c 'glmark2 --off-screen --run-forever -b terrain & stress-ng --cpu 0 & wait'
  ```

## Things that did *not* help

- **CPU power cap alone (30 W).** It still shut down after 28 minutes. The GPU makes most of the heat.
- **Cooler Boost while gaming, or a custom EC fan curve in "turbo" shift mode.** Both work thermally (81–83 °C), but the fans end up at about 6,000 RPM for the whole session.
- **Holding the CPU at 15 W.** Cooler, but a UE5 game plus the desktop starved input, so keys auto-repeated. The floor is now 20 W.
- **`pcie_aspm=off pcie_port_pm=off nvidia.NVreg_DynamicPowerManagement=0x00`** for the Xid 79s. The GPU still fell off the bus. The Xid 79s were most likely the same overheating; they happened during the same kind of long gaming sessions.
- **The `ACPI BIOS Error: Could not resolve symbol [\_TZ.ETMD]` message.** It's a harmless firmware bug common to many laptops.

## Other models

The fan cap and the DPTF profile split are MSI firmware behavior, so other MSI laptops may have the same problem. Before installing on a different model:

1. Check that msi-ec supports your firmware: `cat /sys/devices/platform/msi-ec/fw_version` exists after `sudo modprobe msi_ec`.
2. Run `tools/thermal-test.sh` without the service, then with it, and compare.
3. Check your DPTF table's discrete-GPU CPU limit: `sudo systemctl stop thermald; sudo thermald --no-daemon --adaptive --loglevel=info` (look for `name:AC balance_discrete ... PL1MAX`), then `sudo systemctl start thermald`. If yours differs, change level 0 of `LEVEL_CPU` in the script; the sensor names (`SEN2`-`SEN4`) and `HOT`/`COOL` may need adjusting too.

## Credits

- [msi-ec](https://github.com/BeardOverflow/msi-ec) for the EC driver and register maps, and [issue #848](https://github.com/BeardOverflow/msi-ec/issues/848) for the fan-curve map.
- [intel/thermal_daemon](https://github.com/intel/thermal_daemon), whose adaptive-mode log exposed MSI's DPTF profiles.

## License

MIT
