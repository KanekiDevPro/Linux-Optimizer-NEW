# Linux-Optimizer

A robust, idempotent system optimizer script for Debian/Ubuntu servers with a focus on VPN performance, stability, and security.

This script safely applies a set of best-practice system tweaks:
- System updates and cleanup
- Useful package installation
- Swap file creation
- Network (sysctl) tuning with selectable profiles
- SSH hardening
- System limits optimization
- UFW firewall setup (TCP-only)

> **Note:** This tool does **not** create tunnels. It prepares the server for high-performance VPN workloads (WireGuard, OpenVPN, etc.) by optimizing kernel parameters and system settings.

---

## Features

- ✅ **Idempotent** – Safe to run multiple times without duplicating entries or breaking configuration.
- 🧠 **Profile-based sysctl tuning** – Choose from 5 profiles tailored to different use cases.
- ⚡ **Automatic detection** – Auto profile selects the best settings based on RAM, CPU cores, and link speed.
- 🔒 **SSH hardening** – Reasonable keepalive values and secure defaults (no risky forwarding).
- 🛡️ **UFW firewall** – Opens only necessary TCP ports (SSH, 80, 443); UDP rules removed.
- 💾 **Swap creation** – Creates and mounts a 2G swap file with filesystem-aware checks.
- 📦 **Package installation** – Installs useful packages individually, so a missing package won’t abort the whole process.
- 🔁 **Single APT update** – Centralised guard ensures only one `apt update` per run (even in Option 1).
- 🧹 **Legacy cleanup** – Removes old optimizer entries from `/etc/sysctl.conf` and `/etc/profile` without touching user customizations.

---

## Requirements

- **Operating System:** Debian or Ubuntu (including derivatives).
- **Privileges:** Must be run as `root` (or with `sudo`).
- **Shell:** Bash.
- **Network:** Internet access for package installation and updates.

> ⚠️ The script should be run on a fresh or minimal server. Always test in a non‑production environment first.

---

## Installation

1. Download the script:
   ```bash
   wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer-NEW/main/linux-optimizer.sh" -O linux-optimizer.sh && chmod +x linux-optimizer.sh && bash linux-optimizer.sh
