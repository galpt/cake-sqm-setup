# CAKE SQM Setup Script

Interactive helper to install and configure CAKE (Common Applications Kept Enhanced) on a Linux interface. The script detects network interfaces, can create an IFB device for inbound shaping, and applies recommended CAKE options for low-latency, fair sharing.

---

## Table of Contents
- [Status](#status)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Examples](#examples)
- [Design Notes](#design-notes)
- [Limitations & Next Steps](#limitations--next-steps)
- [Contributing](#contributing)
- [License](#license)

## Status
- Stable interactive script that detects interfaces and applies CAKE.
- Includes IFB creation + ingress redirect and safe removal mode.

## Features
- Auto-detects network interfaces (hides helper devices like IFB).
- Detects existing CAKE qdiscs and offers to replace them.
- Creates `ifb-<iface>` for inbound shaping when needed.
- Uses recommended CAKE options for egress and ingress.
- Non-destructive `--remove <iface>` cleanup mode.

## Requirements
- Linux
- iproute2 (`ip`), `tc` (iproute2), `modprobe`
- Optional: `ethtool` / `iw` for autodetecting link speed

## Tested on (local machine)
- OS: CachyOS x86_64 — Kernel 6.19.2-2-cachyos
- Host: 82SB (IdeaPad Gaming 3 15ARH7)
- CPU: AMD Ryzen 7 6800H (16 threads)
- Memory: 58.54 GiB total
- GPUs: NVIDIA GeForce RTX 3050 Mobile (discrete), AMD Radeon 680M (integrated)
- Shell / Terminal: fish 4.5.0 / Konsole 25.12.2
- Desktop: KDE Plasma 6.6.0 (Wayland)
- Local IP (wlan0): 10.0.0.42/8
- Disk (root): ~472.6 GiB (xfs)

Verified on: 19 Feb 2026 (local test)

## Install / Run
1. Make executable:

```bash
chmod +x cake-sqm-setup.sh
```

2. Run interactively (root required):

```bash
sudo ./cake-sqm-setup.sh
```

3. Remove CAKE from an interface (cleanup):

```bash
sudo ./cake-sqm-setup.sh --remove eth0
```

## Usage (interactive)
- The script shows detected interfaces (hiding IFB helper devices).
- Select the interface number to configure (choose the physical WAN/egress if possible).
- Provide upload/download rates (examples: `10M`, `800k`, `auto`, `unlimited`).
  - `auto` attempts to read the interface speed using `ethtool` or `iw`.
  - `unlimited` installs CAKE without a bandwidth shaper.
- The script will optionally create an IFB device and redirect ingress traffic to it.
- Confirm to apply changes — the script replaces qdiscs atomically.

## Examples
- Configure `eth0` egress at 10 Mbit and ingress at 50 Mbit:

```bash
sudo ./cake-sqm-setup.sh
# choose interface 'eth0'
# upload: 10M
# download: 50M
# proceed: Y
```

- Remove CAKE and cleanup IFB for `wlan0`:

```bash
sudo ./cake-sqm-setup.sh --remove wlan0
```

## Design Notes
- CAKE options used by default:
  - Egress: `internet diffserv4 dual-srchost nat split-gso conservative`
  - Ingress: `internet diffserv4 dual-dsthost nat split-gso conservative`
- The script detects IFB devices using kernel-reported link type (`ip link show type ifb`) — robust even if the interface name does not include "ifb".
- IFS is intentionally restricted to newline+tab to avoid accidental word-splitting; the script handles array expansions safely.

## Limitations & Next Steps
- Persistence: this script does not yet create a system startup unit to re-apply settings after reboot — can be added on request.
- Non-interactive mode: currently interactive; CLI flags can be added for automation.

## Contributing
- Open an issue or PR with improvements or platform-specific fixes.
- Run the script locally and add tests for additional distributions.

## License
MIT
