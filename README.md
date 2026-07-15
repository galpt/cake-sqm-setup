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
- Stable interactive script that detects interfaces and applies CAKE with optional boot-time persistence.

## Features
- Auto-detects network interfaces (hides helper devices like IFB).
- Detects existing CAKE qdiscs and offers to replace them.
- Creates `ifb-<iface>` for inbound shaping when needed.
- Desktop / Router mode — uses `flows` for desktop (VPN-safe) or `dual-srchost`/`dual-dsthost` for router deployment.
- Optional systemd persistence — CAKE survives reboots automatically.
- `--remove <iface>` cleanup with persistence warning.
- `--restore <iface>` non-interactive restore from saved config.
- `--unpersist <iface>` cleanly removes all persistence artifacts.

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

4. Restore CAKE from saved config (typically run by systemd at boot):

```bash
sudo ./cake-sqm-setup.sh --restore eth0
```

5. Remove persistence (disable boot-time restore + delete saved config):

```bash
sudo ./cake-sqm-setup.sh --unpersist eth0
```

## Usage (interactive)
- The script shows detected interfaces (hiding IFB helper devices).
- Select the interface number to configure (choose the physical WAN/egress if possible).
- Provide upload/download rates (examples: `10M`, `800k`, `auto`, `unlimited`).
  - `auto` attempts to read the interface speed using `ethtool` or `iw`.
  - `unlimited` installs CAKE without a bandwidth shaper.
- Choose **Desktop** (uses `flows` — recommended for VPN users) or **Router** (uses `dual-srchost`/`dual-dsthost`).
- The script will optionally create an IFB device and redirect ingress traffic to it.
- Confirm to apply changes — the script replaces qdiscs atomically.
- After applying, you can opt into **systemd persistence** so CAKE is restored automatically after every reboot.

## Examples
- Configure `eth0` in router mode, egress at 10 Mbit, ingress at 50 Mbit, with persistence:

```bash
sudo ./cake-sqm-setup.sh
# choose interface 'eth0'
# upload: 10M
# download: 50M
# select deployment mode: 2 (router)
# proceed: Y
# persist across reboots: Y
```

- Configure `eth0` in desktop mode (uses `flows` — VPN-safe):

```bash
sudo ./cake-sqm-setup.sh
# choose interface 'eth0'
# upload: 10M
# download: 50M
# select deployment mode: 1 (desktop)
# proceed: Y
```

- Remove CAKE and cleanup IFB for `wlan0`:

```bash
sudo ./cake-sqm-setup.sh --remove wlan0
```

- Restore CAKE from saved config (non-interactive, used by systemd at boot):

```bash
sudo ./cake-sqm-setup.sh --restore wlan0
```

- Disable boot-time restore and delete saved config:

```bash
sudo ./cake-sqm-setup.sh --unpersist wlan0
```

## Design Notes
- CAKE options used by default, per deployment mode:

  **Desktop mode** (uses `flows` — hashes per-flow, VPN-safe):
  - Egress:  `oceanic diffserv4 conservative flows split-gso nat nowash memlimit 32mb`
  - Ingress: `ingress oceanic diffserv4 conservative flows split-gso nat nowash memlimit 32mb`

  **Router mode** (uses `dual-srchost` / `dual-dsthost` — per-host flow accounting):
  - Egress:  `oceanic diffserv4 conservative dual-srchost split-gso nat nowash memlimit 32mb`
  - Ingress: `ingress oceanic diffserv4 conservative dual-dsthost split-gso nat nowash memlimit 32mb`

  All three modes hash the full 5-tuple (src IP, dst IP, proto, src port,
  dst port) for queue assignment. The difference is that `dual-srchost` and
  `dual-dsthost` additionally track per-host flow counts to ensure fairness
  between different LAN clients — ideal for router deployments.

  `flows` is required when a VPN (e.g. WireGuard) is in use. Since Linux 5.7,
  the kernel can compute the flow hash on the inner packet *before* encryption
  and preserve it for the outer qdisc. However, this only works in `flows`
  mode — the host-tracking modes need to dissect the outer (encrypted) header
  and are incompatible with hash preservation. As CAKE maintainer Toke
  Høiland-Jørgensen [explains](https://blog.lucid.net.au/2021/12/12/linux-tc-cake-notes/):
  *"all of 'srchost', 'dsthost', 'hosts', 'dual-srchost', 'dual-dsthost' and
  'triple-isolate' will do host-based hashing which is not compatible with
  preserving the hash from inside wireguard."*
- The script detects IFB devices using kernel-reported link type (`ip link show type ifb`) — robust even if the interface name does not include "ifb".
- If an `ifb-<iface>` device already exists, the script will automatically reuse it (no prompt). If that IFB already has CAKE configured, the script will prompt whether to replace it — you may reply `y`/`n` or enter a bandwidth directly (for example `unlimited`) at that prompt to immediately replace with the provided bandwidth.
- IFS is intentionally restricted to newline+tab to avoid accidental word-splitting; the script handles array expansions safely.
- **Persistence:** When enabled, the script saves the configuration to `/etc/cake-sqm/<iface>.conf` and installs a systemd oneshot service (`cake-sqm-restore@<iface>.service`). The service triggers after `network-online.target` and waits up to 30 seconds for the interface to appear before applying CAKE, so it works reliably even for wireless interfaces that connect later in the boot sequence. CAKE is re-applied automatically via `--restore <iface>` on every boot.

## Limitations & Next Steps
- Non-interactive flags (`--remove`, `--restore`, `--unpersist`) are available; full CLI automation (e.g. `--apply <iface> --bandwidth 10M`) is a future enhancement.

## Contributing
- Open an issue or PR with improvements or platform-specific fixes.
- Run the script locally and add tests for additional distributions.

## License
MIT
