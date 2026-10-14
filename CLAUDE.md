# msi-game-cooling: notes for Claude

The bug: MSI Cyborg 15 A13VE (MS-15K1, i7-13620H + RTX 4050 Laptop, EC firmware
`15K1IMS1.110`, BIOS E15K1IMS.10E) on Omarchy/Arch. In long games the laptop
lagged (mouse at 10-20 fps), then the EC hard-cut power. The journal just stops.
Earlier the same thing showed up as NVIDIA `Xid 79` (GPU fell off the bus).

This repo is the fix. It's public (github.com/Malekabokhatwa/msi-game-cooling).
`~/Work/Malek-Omarchy/setup.sh` (section `cooling`) installs it from GitHub, so
there is only one copy of the script.

## What Malek wants (hard requirements)

- **Fans stay stock.** No Cooler Boost while gaming, no custom fan curve, no
  turbo shift mode. Two earlier versions did that and he rejected both as "jet
  engine". Cooler Boost is only an emergency brake that should never fire.
- No shutdowns. Losing fps is acceptable only as far as it's needed to stay
  under the temperature target; give it back when cool.
- Report what changed **before committing** when he asks for that.
- Never touch the Windows NVMe.

## How it works now

`msi-game-cooling` (bash, root, systemd unit `After=graphical.target`):
1. Detects a game when the NVIDIA GPU draws 12 W or more for 10 s. It leaves
   game mode after 60 s below 12 W. An open Steam client keeps the GPU at
   3-10 W, so never use a lower idle threshold.
2. In game mode it holds the hottest EC sensor (ACPI zones `SEN2`/`SEN3`/
   `SEN4`) under 82 C by stepping through levels. Each level sets CPU PL1=PL2
   on the MSR RAPL (`intel-rapl:0`) and a GPU clock cap (`nvidia-smi -lgc
   0,<MHz>`). Level 0 is CPU 30 W (MSI's own "NVIDIA active" limit) with the GPU
   uncapped. The CPU floor is 20 W; deeper levels only lower the GPU clock (down
   to 900 MHz).
   - It steps down every 15 s while at or above 82 C, every 5 s at or above
     84 C, and early when close to 82 and rising 2 C or more in 15 s.
   - It steps up only after 60 s at or below 78 C.
3. Emergency: Cooler Boost turns on at 88 C and off at 80 C. It's re-asserted
   every sample.
4. Leaving game mode, a stop, a crash (EXIT trap) or a restart all restore the
   CPU limits recorded at first start (`/run/msi-game-cooling.state`) and run
   `nvidia-smi -rgc`.

## Facts measured on this laptop

- **EC sensors decide the shutdown, not CPU/GPU temps.** SEN3/SEN4 sat at
  92-93 C for about 15 min before the cut. ACPI says passive 65 / hot 75 /
  critical 80, but nothing on Linux enforces those.
- **Stock fans:** shift mode `comfort` caps the fans at about 3600 RPM (curve
  duty 60 % and up all give ~3600). The factory curve (CPU temps at `0x6A`,
  duty `0x72`; GPU `0x82`/`0x8A`) tops out at 78 %.
  - In `turbo` the curve is linear, about 60 RPM per % up to about 6000.
  - Cooler Boost (`0x98` bit 7) gives 6150-6233 RPM.
  - The curve only takes effect with fan_mode `advanced` (`0xd4`=`0x8d`).
- **Heat budget with stock fans:** heavy Ultra UE5 (Sort The Capybaras) needs
  about CPU 20 W + GPU 24 W (capped ~1300 MHz, level L7) to hold 79-80 C.
  The v3 test (20 min) settled there once and held 16 min, with a peak of
  85 C at 1.5 min during warm-up and no brake.
  Uncapped (CPU 30 W + GPU 40 W) the sensors climb past 85 C within about 2 min.
- **Thermald** (`--adaptive`) runs MSI's iGPU-only profile (MMIO 45/70 W),
  because the Oem1 flag MSI Center sets on Windows never gets set; the `odvp`
  sysfs files are read-only.
  - The EC shift mode feeds that choice: in `turbo` thermald switched to 55/78.
  - Under heat it drops MMIO to 30/30 by itself, but only after the chassis is
    already hot.
- **GPU:** `nvidia-smi -pl` is refused on this laptop ("not supported in
  current scope"). `-lgc`/`-rgc` work. Max clock 3105 MHz; in game about
  1845 MHz uncapped at about 36-40 W.
- **hwmon fans:** `msi_wmi_platform` `fan1_input` is the real RPM. `fan2`-`fan4`
  read 0 (not reported, not dead). The EC duty registers (`0x71`/`0x89`) show the
  curve's target, not the real speed.

## Gotchas (each one cost time)

- **Repeated keys while typing:** a game running in the background with the CPU
  held at 15 W starved the desktop. Key-release events arrived late, so
  Hyprland auto-repeated keys (repeat rate 40, delay 250). This is not a
  keyboard fault: there were no `atkbd` errors. The fix is the 20 W CPU floor.
  Also: never leave a test game running while Malek uses the laptop.
- **Long-blocking tool calls annoy Malek.** User settings now cap Bash at 5 min
  (`BASH_MAX_TIMEOUT_MS=300000`, default 120000; also in Malek-Omarchy
  `claude/settings.fragment.json`).
  - Run long tests in the background and poll with
    `timeout 280 bash -c 'until <cond>; do sleep 5; done'`.
  - A plain `sleep N; cmd` is blocked by the harness.

- **sudo:** pass the password with `-S` on every call. A helper that called
  `sudo` about 20 times without it tripped faillock (`deny=10`) and locked the
  account for 10 minutes. Put multi-step root work in one `sudo -S sh -c '...'`.
- The Bash safety check blocks `rm` inside a `sudo bash -c '...'` string.
  Run `rm` as its own `sudo -S rm -f <explicit paths>`.
- `pgrep -f`/`pkill -f` match your own shell's command line when it contains
  the pattern. Use the bracket trick: `pgrep -f '[S]ortTheCapybaras'`. A plain
  `pkill -f 'sim4/script'` killed the shell running it.
- `$!` after `cmd | grep &` is grep's PID, not cmd's. Redirect to a file
  instead of piping when you need the PID.
- **Steam from root:** `runuser ... steam` doesn't start Steam (session env
  missing). Launch from Claude's own shell, which is in the user session:
  `setsid uwsm-app -- steam steam://rungameid/5130480 & disown`.
- **The in-kernel `msi_ec` rejects fw `15K1IMS1.110`.** Upstream msi-ec
  supports it: AUR `msi-ec-dkms-git` (PKGBUILD reviewed, clean). Installing it
  rebuilds the UKI through the limine hooks.
- **EC RAM survives reboots and crashes.** A custom curve or turbo set by an
  earlier experiment stays until written back. The factory values are above;
  check with `ec_sys write_support=0` reads before assuming "stock".
- **Clean up after manual experiments** (RAPL limits, `-lgc`, EC writes)
  before (re)starting the service. Otherwise it records your leftovers as
  "stock" in `/run/msi-game-cooling.state` (this happened once: 30/30 W).
- **One-sample CPU spikes to 94-97 C** at 25-35 W are normal boost behaviour.
  The watchdog only aborts on CPU/GPU temps if they stay hot for 3 samples.
  EC sensors abort at once.
- **SDDM:** after a hard power-off the greeter can miss SDDM's 15 s Wayland
  socket window on this HDD, and the retry trips over a stale lock. The result
  is a blank screen. Fix: `sudo systemctl restart sddm` from a tty. Also seen
  on 2026-10-11, before this service existed.
- **Things that do not fix it:**
  - `pcie_aspm=off pcie_port_pm=off nvidia.NVreg_DynamicPowerManagement=0x00`
    (still live in `/etc/default/limine`; Malek chose to keep them; Xid 79
    recurred with them)
  - the CPU cap alone
  - turning Cooler Boost off (it was already off)
- **Malek declined:** BIOS update (latest E15K1IMS.114) and opening or
  cleaning the laptop.

## Testing

`tools/thermal-test.sh` is the watchdog harness (root). It logs every 2 s
(temps, CPU/GPU W, EC fan duty, Cooler Boost, GPU throttle reasons). It kills the
load if an EC sensor reaches its limit (85 by default; 88 for runs where the
service's own brake is at 88), or CPU/GPU/THRM stay hot for 3 samples.

- **Synthetic load (harder than any game):** `glmark2 --off-screen
  --run-forever -b terrain` with `__NV_PRIME_RENDER_OFFLOAD=1
  __GLX_VENDOR_LIBRARY_NAME=nvidia` (about 40-45 W) plus `stress-ng --cpu 0`.
- **Real game:** launch Sort The Capybaras (appid 5130480) as above, then
  attach the watchdog to a waiter script that closes the game when stopped.
- **Logic:** simulate with fake `RAPL`/`BOOST`/`ORIG` paths, a fake
  `nvidia-smi` on `PATH`, and fake thermal zones (`sed` the paths in a copy).
  This covers idle, game, heat, cool, the brake, `nvidia-smi` failure, TERM and
  restart without touching hardware.
- Watch a live session: `journalctl -fu msi-game-cooling`.
