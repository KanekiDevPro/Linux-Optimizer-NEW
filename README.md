# Linux-Optimizer

A robust, idempotent system optimizer for Debian/Ubuntu servers — focused on VPN/proxy performance, stability and safety. Ships as two scripts: a hardened **launcher** (hosts + DNS + timezone) that downloads and runs the matching **distro optimizer** (system update, packages, swap, sysctl, SSH, limits).

> **Note:** This tool does **not** create tunnels. It prepares the server for high-performance VPN workloads (WireGuard, OpenVPN, etc.) by optimizing kernel parameters and system settings.

---

## What it actually does

**Stage 1 — Launcher (`linux-optimizer.sh`)**
- Fixes `/etc/hosts` (`127.0.1.1 <hostname>`)
- Configures DNS from 15 presets (Cloudflare, Google, Quad9, AdGuard, OpenDNS, Iranian resolvers, custom) with per-server DoT (SNI) on systemd ≥ 243
- Supports `systemd-resolved`, NetworkManager, resolvconf or a direct `/etc/resolv.conf` — auto-detected
- Writes a netplan override + networkd-dispatcher hook so DNS **survives reboots**
- Auto-detects the timezone from your public IP (with per-country fallback)
- Downloads and runs the distro optimizer from this repo (pinned-checksum supported)

**Stage 2 — Distro optimizer (`ubuntu-optimizer.sh`, v2.0.5)**
- System update + cleanup, useful packages (single apt transaction, per-package fallback)
- Swap file creation — filesystem-aware (btrfs/NOCOW, ZFS/XFS/overlay → dd), space-checked, transactional replacement
- Sysctl network tuning — 5 selectable profiles, BBR + fq when available
- SSH hardening — managed drop-in (`00-optimizer.conf`), verified with `sshd -T`, reload (never restart)
- System limits — finite, DoS-resistant values in `limits.d` + systemd defaults + PAM

---

## Features

- ✅ **Idempotent** – safe to re-run; managed files are reproduced byte-for-byte
- 🧠 **Profile-based sysctl tuning** – `balanced | vpn-high-throughput | vpn-low-latency | conservative | auto`
- ⚡ **Auto profile** – selects based on RAM, CPU cores and link speed (never guesses)
- 🔒 **SSH hardening** – first-match drop-in wins over stock cloud images; effective values verified via `sshd -T`
- 💾 **Transactional swap** – old swap stays live until the replacement is built, verified and activated
- 🧹 **Legacy cleanup** – strips old optimizer keys from `sysctl.conf` / `profile`, preserves everything else
- 💥 **Atomic writes** – staged temp file + `mv` for sysctl, sshd, fstab and limits (a crash can never truncate configs)
- ⏪ **Backups & rollback** – timestamped backups (last 5 kept) before every change; DNS changes verified and rolled back on failure
- 🔁 **Single APT update** – centralized guard runs `apt update` once per run
- 🚦 **Honest status** – failed stages are recorded; the final banner and reboot gate tell the truth
- 🐳 **Container-aware** – swap/sysctl steps degrade gracefully inside LXC/Docker

> **Deliberate choices:** no `tcp_tw_reuse` (outgoing-only since kernel 4.x), ephemeral ports start at **10000** (no collision with service ports), no pinned SSH Ciphers list (distro security team maintains it), `kernel.panic = 10` (a 1s reboot loop destroys crash evidence).

---

## Requirements

- **OS:** Ubuntu 20+ / Debian 11+ (the launcher also detects CentOS 8+, AlmaLinux/Rocky, Fedora and downloads the matching optimizer)
- **Privileges:** root (`sudo`)
- **Shell:** Bash
- **Network:** internet access

> ⚠️ Run on a fresh or minimal server first. Always test in a non-production environment.

---

## Installation (one-liner)

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer-NEW/main/linux-optimizer.sh)"
```

Or step by step:

```bash
wget https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer-NEW/main/linux-optimizer.sh -O linux-optimizer.sh
chmod +x linux-optimizer.sh
sudo bash linux-optimizer.sh
```

## Non-interactive usage (launcher)

```bash
# Cloudflare Anti-Malware DNS, no prompts
sudo bash linux-optimizer.sh --dns=2 --yes

# Custom DNS servers
sudo bash linux-optimizer.sh --dns=15 --dns-v4="1.1.1.1 8.8.8.8" --yes

# Force a timezone, skip the optimizer stage
sudo bash linux-optimizer.sh --timezone=Asia/Tehran --no-optimizer --yes
```

Useful flags: `--dns=1-15`, `--dns-v4/--dns-v6`, `--timezone=TZ`, `--yes`, `--no-optimizer`, `--no-bootstrap`, `--netplan-apply`, `--backup-keep=N`, `--pin-checksum`, `--allow-unverified`, `--optimizer-ref=REF`.

**Exit codes (bitmask):** `1` DNS failed/rolled back · `2` timezone failed · `4` optimizer failed · `0` all good.

## Usage (optimizer menu)

| Option | Action |
|---|---|
| 1 | Apply Everything (recommended) |
| 2–3 | Update + (packages) + swap + network + SSH + limits |
| 4 | Update & clean the OS |
| 5 | Install useful packages |
| 6 | Make SWAP (2G) |
| 7 | Optimize network + SSH + limits |
| 8–10 | Individual: network / SSH / limits |

CLI equivalents:

```bash
sudo ./ubuntu-optimizer.sh --all --profile auto -y
sudo ./ubuntu-optimizer.sh --network --profile vpn-high-throughput
sudo ./ubuntu-optimizer.sh --swap --swap-size 4G
```

## DNS presets

| # | Preset | | # | Preset |
|---|---|---|---|---|
| 1 | Cloudflare | | 8 | Shecan (IR) |
| 2 | Cloudflare Anti-Malware ★ | | 9 | Electro (IR) |
| 3 | Cloudflare Family | | 10 | 403.online (IR) |
| 4 | Google | | 11 | Begzar (IR) |
| 5 | Quad9 | | 12 | Radar Game (IR) |
| 6 | AdGuard | | 13 | Mix: Shecan + Electro |
| 7 | OpenDNS | | 14/15 | Mix CF+Google / Custom |

## Verified

Tested end-to-end on **Ubuntu 24.04 (Noble)**: full run + reboot persistence — DNS (DoT with SNI, BBR enabled, 2G swap, `ulimit -n = 1048576`, sshd effective values) all verified with `resolvectl`, `sshd -T` and `swapon` after reboot.

## License

MIT
