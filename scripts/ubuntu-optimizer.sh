#!/usr/bin/env bash

set -o pipefail

# Green, Yellow & Red Messages.
green_msg() {
    tput setaf 2 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

yellow_msg() {
    tput setaf 3 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

red_msg() {
    tput setaf 1 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

# Declare Paths & Settings.
SYS_PATH="/etc/sysctl.conf"
SYS_OPTIMIZER_PATH="/etc/sysctl.d/99-optimizer.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE="2G"
LIMITS_CONF="/etc/security/limits.d/99-optimizer.conf"
APT_UPDATED=0

# Central package list guard
apt_update_once() {
    if [ "$APT_UPDATED" = "1" ]; then
        yellow_msg "Skipping package list update (already done this run)"
        return 0
    fi
    yellow_msg "Running package list update..."
    export DEBIAN_FRONTEND=noninteractive
    if apt-get -q update -y; then
        APT_UPDATED=1
        return 0
    else
        yellow_msg "package list update failed (will retry on next call)"
        return 1
    fi
}

# Root check
check_if_running_as_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
      echo
      red_msg 'Error: You must run this script as root!'
      echo
      sleep 0.5
      exit 1
    fi
}

check_if_running_as_root
sleep 0.5

# Ask Reboot
ask_reboot() {
    yellow_msg 'Reboot now? (Recommended) (y/n)'
    echo
    while true; do
        read -r choice
        echo
        if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
            sleep 0.5
            reboot
            exit 0
        fi
        if [[ "$choice" == 'n' || "$choice" == 'N' ]]; then
            break
        fi
        yellow_msg 'Please answer y or n.'
    done
}

# Update & Upgrade & Remove & Clean
complete_update() {
    echo
    yellow_msg 'Updating the System... (This can take a while.)'
    echo
    sleep 0.5

    export DEBIAN_FRONTEND=noninteractive
    apt_update_once || yellow_msg "package list update had warnings, continuing..."
    apt-get -y upgrade
    apt-get -y full-upgrade
    apt-get -y autoremove --purge
    apt-get -y autoclean
    apt-get -y clean

    echo
    green_msg 'System Updated & Cleaned Successfully.'
    echo
    sleep 0.5
}

# Disable Terminal Ads
disable_terminal_ads() {
    echo
    yellow_msg 'Disabling Terminal Ads...'
    echo
    sleep 0.5

    if [ -f /etc/default/motd-news ]; then
        sed -i 's/ENABLED=1/ENABLED=0/g' /etc/default/motd-news
    fi
    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false || true
    fi

    echo
    green_msg 'Terminal Ads Disabled.'
    echo
    sleep 0.5
}

# Install useful packages
installations() {
    echo
    yellow_msg 'Installing Useful Packages...'
    echo
    sleep 0.5

    export DEBIAN_FRONTEND=noninteractive
    apt_update_once || yellow_msg "package list update had warnings, continuing..."

    packages=(
        apt-transport-https
        apt-utils bash-completion busybox ca-certificates cron curl gnupg2 locales lsb-release nano screen software-properties-common unzip vim wget xxd zip
        git pkg-config python3 python3-pip
        bc binutils binutils-common binutils-x86-64-linux-gnu ubuntu-keyring jq libsodium-dev libsqlite3-dev libssl-dev packagekit qrencode socat
        dialog htop net-tools
    )

    failed_pkgs=()
    for pkg in "${packages[@]}"; do
        [ -z "$pkg" ] && continue
        yellow_msg "Installing $pkg ..."
        if ! apt-get -y install "$pkg" 2>&1; then
            yellow_msg "Warning: failed to install $pkg, skipping (package may not exist on this release)"
            failed_pkgs+=("$pkg")
        fi
    done

    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        yellow_msg "Some packages failed/skipped: ${failed_pkgs[*]}"
        yellow_msg "This is normal on some Ubuntu/Debian releases."
    fi

    echo
    green_msg 'Useful Packages Installed Successfully.'
    echo
    sleep 0.5
}

# Enable packages at server boot
enable_packages() {
    for svc in cron; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
            systemctl enable "$svc" 2>/dev/null || true
        fi
    done
    echo
    green_msg 'Packages Enabled Successfully.'
    echo
    sleep 0.5
}

## Swap Maker - 100% Robust
swap_maker() {
    echo
    yellow_msg 'Making SWAP Space...'
    echo
    sleep 0.5

    if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[GMKgmk]?$ ]]; then
        red_msg "Invalid SWAP_SIZE: $SWAP_SIZE (use e.g., 2G)"
        return 1
    fi

    if grep -qs "$SWAP_PATH" /proc/swaps; then
        yellow_msg "Swap $SWAP_PATH is already active. Turning off to recreate..."
        swapoff "$SWAP_PATH" 2>/dev/null || {
            red_msg "Failed to swapoff $SWAP_PATH - maybe in use"
            return 1
        }
    fi

    if [ -f "$SWAP_PATH" ]; then
        yellow_msg "Old swap file found at $SWAP_PATH, removing..."
        rm -f "$SWAP_PATH"
    fi

    if grep -qF "$SWAP_PATH" /etc/fstab; then
        yellow_msg "Removing old fstab entry for $SWAP_PATH"
        cp /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S)"
        sed -i "\|$SWAP_PATH|d" /etc/fstab
    fi

    swap_dir=$(dirname "$SWAP_PATH")
    [ -d "$swap_dir" ] || swap_dir="/"
    avail_mb=$(df -m --output=avail "$swap_dir" 2>/dev/null | tail -n1 | tr -d ' ')

    case "$SWAP_SIZE" in
        *G|*g) swap_mb=$((${SWAP_SIZE%[Gg]} * 1024)) ;;
        *M|*m) swap_mb=${SWAP_SIZE%[Mm]} ;;
        *K|*k) swap_mb=$((${SWAP_SIZE%[Kk]} / 1024)); [ "$swap_mb" -eq 0 ] && swap_mb=1 ;;
        *)     swap_mb=$((SWAP_SIZE / 1024 / 1024)); [ "$swap_mb" -eq 0 ] && swap_mb=2048 ;;
    esac

    if ! [[ "$avail_mb" =~ ^[0-9]+$ ]]; then
        yellow_msg "Warning: could not determine free space for $swap_dir, skipping space check"
    elif [ "$avail_mb" -lt $((swap_mb + 100)) ]; then
        red_msg "Not enough disk space on $swap_dir. Available: ${avail_mb}M, Required: ${swap_mb}M + 100M overhead"
        return 1
    fi

    yellow_msg "Allocating $SWAP_SIZE at $SWAP_PATH..."
    local created_with_fallocate=false
    if fallocate -l "$SWAP_SIZE" "$SWAP_PATH" 2>/dev/null; then
        created_with_fallocate=true
    fi

    chmod 600 "$SWAP_PATH"
    if ! mkswap "$SWAP_PATH" 2>/dev/null || ! swapon "$SWAP_PATH" 2>/dev/null; then
        if [ "$created_with_fallocate" = true ]; then
            yellow_msg "Fallocate swap failed activation (filesystem hole issue). Retrying with dd..."
            rm -f "$SWAP_PATH"
        fi
        case "$SWAP_SIZE" in
            *G|*g) count=$((${SWAP_SIZE%[Gg]} * 1024)) ;;
            *M|*m) count=${SWAP_SIZE%[Mm]} ;;
            *K|*k) count=$((${SWAP_SIZE%[Kk]} / 1024)); [ "$count" -eq 0 ] && count=1 ;;
            *)     count=$((SWAP_SIZE / 1024 / 1024)); [ "$count" -eq 0 ] && count=2048 ;;
        esac
        if ! dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$count" status=none; then
            red_msg "Failed to create swap file via dd"
            rm -f "$SWAP_PATH"
            return 1
        fi
        chmod 600 "$SWAP_PATH"
        if ! mkswap "$SWAP_PATH" || ! swapon "$SWAP_PATH"; then
            red_msg "swapon failed - check dmesg"
            rm -f "$SWAP_PATH"
            return 1
        fi
    fi

    # Safe fstab entry with nofail to guarantee clean boot
    if ! grep -qF "$SWAP_PATH" /etc/fstab; then
        echo "$SWAP_PATH   none    swap    sw,nofail    0   0" >> /etc/fstab
    fi

    if grep -qs "$SWAP_PATH" /proc/swaps; then
        green_msg "SWAP Created & Activated Successfully."
    else
        red_msg "SWAP creation verification failed"
    fi

    echo
    sleep 0.5
}

# SYSCTL Optimization
sysctl_optimizations() {
    local profile_input="${1:-}"
    local profile=""
    local selected_profile=""
    local auto_reason=""
    local ram_gb="unknown"
    local cpu_cores="unknown"
    local iface="unknown"
    local speed="unknown"
    local TCP_CC="cubic"
    local QDISC="fq_codel"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")

    detect_ram_gb() {
        local mem_kb
        mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
        if [ -n "$mem_kb" ] && [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
            echo $(( (mem_kb + 1048575) / 1048576 ))
            return
        fi
        local mem_mb
        mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
        if [ -n "$mem_mb" ] && [[ "$mem_mb" =~ ^[0-9]+$ ]]; then
            echo $(( (mem_mb + 1023) / 1024 ))
            return
        fi
        echo "unknown"
    }

    detect_cpu_cores() {
        if command -v nproc >/dev/null 2>&1; then
            nproc 2>/dev/null || echo "1"
        else
            grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1"
        fi
    }

    detect_primary_iface() {
        local _iface=""
        if command -v ip >/dev/null 2>&1; then
            _iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            if [ -z "$_iface" ]; then
                _iface=$(ip -4 route ls 2>/dev/null | grep -m1 default | awk '{print $5}')
            fi
        fi
        if [ -z "$_iface" ] && [ -d /sys/class/net ]; then
            for f in /sys/class/net/*; do
                local bn
                bn=$(basename "$f")
                [ "$bn" != "lo" ] && _iface="$bn" && break
            done
        fi
        [ -z "$_iface" ] && _iface="unknown"
        echo "$_iface"
    }

    detect_link_speed() {
        local _iface="$1"
        local _speed="unknown"
        local raw=""
        if [ -z "$_iface" ] || [ "$_iface" = "unknown" ] || [ "$_iface" = "lo" ]; then
            echo "unknown"
            return
        fi
        if command -v ethtool >/dev/null 2>&1; then
            raw=$(ethtool "$_iface" 2>/dev/null | grep -i "Speed:" | awk -F: '{print $2}' | tr -d ' ')
            if echo "$raw" | grep -qi "unknown"; then
                _speed="unknown"
            elif [ -n "$raw" ]; then
                local num
                num=$(echo "$raw" | grep -oE "[0-9]+" | head -n1)
                if [ -n "$num" ] && [[ "$num" =~ ^[0-9]+$ ]]; then
                    if echo "$raw" | grep -q "Gb/s"; then
                        num=$((num * 1000))
                    fi
                    _speed="$num"
                else
                    _speed="unknown"
                fi
            fi
        fi
        if [ "$_speed" = "unknown" ] && [ -f "/sys/class/net/$_iface/speed" ]; then
            raw=$(cat "/sys/class/net/$_iface/speed" 2>/dev/null | tr -d ' ')
            if [ -n "$raw" ] && [ "$raw" != "-1" ] && ! echo "$raw" | grep -qi "unknown" && [[ "$raw" =~ ^[0-9]+$ ]]; then
                _speed="$raw"
            fi
        fi
        if [ "$_speed" != "unknown" ] && ! [[ "$_speed" =~ ^[0-9]+$ ]]; then
            _speed="unknown"
        fi
        echo "$_speed"
    }

    if [ -n "$profile_input" ]; then
        case "$profile_input" in
            balanced|vpn-high-throughput|vpn-low-latency|conservative|auto)
                profile="$profile_input"
                ;;
            *)
                red_msg "Invalid profile: $profile_input"
                echo "Valid profiles: balanced, vpn-high-throughput, vpn-low-latency, conservative, auto" >&2
                return 1
                ;;
        esac
    else
        if [ -t 0 ]; then
            echo
            yellow_msg "Select sysctl profile:"
            echo "  1) balanced              - General-purpose VPN/server (DEFAULT, stable + good perf)"
            echo "  2) vpn-high-throughput   - High-bandwidth VPN, many connections (>=8GB RAM / >=4 CPU / >=1Gbps)"
            echo "  3) vpn-low-latency       - Optimize for latency/jitter, smaller buffers, conservative busy_poll"
            echo "  4) conservative          - Minimal changes, safe improvements only"
            echo "  5) auto                  - Automatically select best profile (RAM/CPU/speed detection)"
            echo
            printf "Enter choice [1-5] (default 1): "
            local choice
            read -r choice
            case "$choice" in
                1|"") profile="balanced" ;;
                2) profile="vpn-high-throughput" ;;
                3) profile="vpn-low-latency" ;;
                4) profile="conservative" ;;
                5) profile="auto" ;;
                balanced|vpn-high-throughput|vpn-low-latency|conservative|auto) profile="$choice" ;;
                *)
                    red_msg "Invalid choice, defaulting to balanced"
                    profile="balanced"
                    ;;
            esac
        else
            yellow_msg "No profile supplied and non-interactive shell detected, defaulting to balanced"
            profile="balanced"
        fi
    fi

    ram_gb=$(detect_ram_gb)
    cpu_cores=$(detect_cpu_cores)
    iface=$(detect_primary_iface)
    speed=$(detect_link_speed "$iface")

    local ram_gb_num=2
    if [[ "$ram_gb" =~ ^[0-9]+$ ]]; then
        ram_gb_num="$ram_gb"
    fi
    local cpu_cores_num=1
    if [[ "$cpu_cores" =~ ^[0-9]+$ ]]; then
        cpu_cores_num="$cpu_cores"
    fi

    if [ "$profile" = "auto" ]; then
        if [[ "$ram_gb" =~ ^[0-9]+$ ]] && [ "$ram_gb" -ge 8 ] && [ "$cpu_cores_num" -ge 4 ]; then
            selected_profile="vpn-high-throughput"
            auto_reason="RAM >=8GB ($ram_gb GB) and CPU >=4 ($cpu_cores cores)"
        elif [ "$speed" != "unknown" ] && [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -ge 1000 ]; then
            selected_profile="vpn-high-throughput"
            auto_reason="link speed >=1Gbps ($speed Mb/s on $iface)"
        else
            selected_profile="balanced"
            if [ "$speed" = "unknown" ]; then
                auto_reason="default (RAM ${ram_gb}GB, CPU ${cpu_cores} cores, speed unknown - not guessing)"
            else
                auto_reason="default (RAM ${ram_gb}GB, CPU ${cpu_cores} cores, speed ${speed}Mb/s <1Gbps)"
            fi
        fi
        echo
        yellow_msg "Auto detection:"
        echo "  Detected RAM: ${ram_gb} GB"
        echo "  CPU cores: ${cpu_cores}"
        echo "  Network interface: ${iface}"
        echo "  Detected link speed: ${speed} $([ "$speed" != "unknown" ] && echo "Mb/s" || echo "")"
        echo "  Selected profile: ${selected_profile}"
        echo "  Reason: ${auto_reason}"
        echo
    else
        selected_profile="$profile"
    fi

    echo
    yellow_msg "Optimizing Network via sysctl (profile: $selected_profile)..."
    echo
    sleep 0.5

    if [ -f "$SYS_PATH" ]; then
        _backup_dest="/etc/sysctl.conf.bak.$(date +%F-%H%M%S)"
        [ -f "$_backup_dest" ] || cp "$SYS_PATH" "$_backup_dest" 2>/dev/null || cp "$SYS_PATH" "/etc/sysctl.conf.bak" 2>/dev/null || true
        green_msg "Backup of sysctl.conf created."
    fi

    TCP_CC="bbr"
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        modprobe tcp_bbr 2>/dev/null || true
        if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            yellow_msg "BBR not available, falling back to cubic"
            TCP_CC="cubic"
        fi
    fi

    QDISC="fq_codel"
    local _qdisc_iface="$iface"
    if [ -z "$_qdisc_iface" ] || [ "$_qdisc_iface" = "unknown" ]; then
        if command -v ip >/dev/null 2>&1; then
            _qdisc_iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            [ -z "$_qdisc_iface" ] && _qdisc_iface=$(ip -4 route ls 2>/dev/null | grep -m1 default | awk '{print $5}')
        fi
        [ -z "$_qdisc_iface" ] && _qdisc_iface="lo"
    fi
    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq 2>/dev/null || true
    fi
    if lsmod 2>/dev/null | grep -qw "sch_fq"; then
        QDISC="fq"
    elif command -v modinfo >/dev/null 2>&1 && modinfo sch_fq >/dev/null 2>&1; then
        QDISC="fq"
    elif command -v tc >/dev/null 2>&1; then
        if tc qdisc add dev lo root fq 2>/dev/null; then
            tc qdisc del dev lo root 2>/dev/null || true
            QDISC="fq"
        elif tc qdisc add dev "$_qdisc_iface" root fq 2>/dev/null; then
            tc qdisc del dev "$_qdisc_iface" root 2>/dev/null || true
            QDISC="fq"
        fi
    elif sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        if sysctl -n net.core.default_qdisc 2>/dev/null | grep -qw "fq"; then
            QDISC="fq"
        else
            sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
            QDISC="fq_codel"
        fi
    else
        QDISC="fq_codel"
    fi

    local tcp_mem=""
    local udp_mem=""
    local min_free_kbytes=""
    case "$selected_profile" in
        balanced)
            if [ "$ram_gb_num" -lt 2 ]; then
                tcp_mem="8192 32768 65536"
                udp_mem="8192 16384 32768"
                min_free_kbytes="16384"
            elif [ "$ram_gb_num" -lt 4 ]; then
                tcp_mem="16384 65536 131072"
                udp_mem="16384 32768 65536"
                min_free_kbytes="32768"
            elif [ "$ram_gb_num" -lt 8 ]; then
                tcp_mem="32768 131072 262144"
                udp_mem="32768 65536 131072"
                min_free_kbytes="65536"
            else
                tcp_mem="65536 262144 524288"
                udp_mem="65536 131072 262144"
                min_free_kbytes="65536"
            fi
            ;;
        vpn-high-throughput)
            if [ "$ram_gb_num" -lt 2 ]; then
                tcp_mem="16384 65536 131072"
                udp_mem="16384 32768 65536"
                min_free_kbytes="32768"
            elif [ "$ram_gb_num" -lt 4 ]; then
                tcp_mem="32768 131072 262144"
                udp_mem="32768 65536 131072"
                min_free_kbytes="65536"
            elif [ "$ram_gb_num" -lt 8 ]; then
                tcp_mem="65536 262144 524288"
                udp_mem="65536 131072 262144"
                min_free_kbytes="65536"
            else
                tcp_mem="98304 393216 786432"
                udp_mem="98304 196608 393216"
                min_free_kbytes="131072"
            fi
            ;;
        vpn-low-latency)
            if [ "$ram_gb_num" -lt 2 ]; then
                tcp_mem="8192 16384 32768"
                udp_mem="8192 16384 32768"
                min_free_kbytes="16384"
            elif [ "$ram_gb_num" -lt 4 ]; then
                tcp_mem="8192 32768 65536"
                udp_mem="8192 16384 32768"
                min_free_kbytes="16384"
            elif [ "$ram_gb_num" -lt 8 ]; then
                tcp_mem="16384 65536 131072"
                udp_mem="16384 32768 65536"
                min_free_kbytes="32768"
            else
                tcp_mem="32768 131072 262144"
                udp_mem="32768 65536 131072"
                min_free_kbytes="65536"
            fi
            ;;
        conservative)
            tcp_mem=""
            udp_mem=""
            min_free_kbytes="16384"
            ;;
    esac

    local busy_poll_supported=0
    if sysctl -n net.core.busy_poll >/dev/null 2>&1; then
        busy_poll_supported=1
    fi

    local header_info
    header_info="# Generated: $timestamp
# Selected profile: $selected_profile
# Requested profile: $profile
# Detected RAM: ${ram_gb} GB
# Detected CPU cores: ${cpu_cores}
# Detected interface: ${iface}
# Detected link speed: ${speed} $([ "$speed" != "unknown" ] && echo "Mb/s" || echo "")
# Auto reason: ${auto_reason:-N/A (direct selection)}
# BBR: $TCP_CC
# QDISC: $QDISC
# RAM-aware tcp_mem: ${tcp_mem:-not set (conservative)}
# Host: $(hostname 2>/dev/null || echo unknown) Kernel: $(uname -r 2>/dev/null || echo unknown)"

    case "$selected_profile" in
        balanced)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: balanced - General-purpose VPN/server (stable + good perf)
################################################################

# File system
fs.file-max = 67108864

# Packet forwarding for VPN/Tunnels/Docker
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - moderate
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 262144
net.core.somaxconn = 16384
net.core.rmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_max = 16777216
net.core.wmem_default = 262144

# TCP - balanced
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = $TCP_CC
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 144000
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# UDP - balanced
net.ipv4.udp_mem = $udp_mem

# UNIX
net.unix.max_dgram_qlen = 256

# VM - RAM-aware balanced
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 10
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security (rp_filter=2 loose mode prevents dropped packets on multi-interface/VPNs)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60
kernel.panic = 1

EOF
            ;;
        vpn-high-throughput)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: vpn-high-throughput - High-bandwidth VPN, many conns
################################################################

# File system
fs.file-max = 67108864

# Packet forwarding for VPN/Tunnels/Docker
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - high throughput
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 524288
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_max = 33554432
net.core.wmem_default = 1048576

# TCP - high throughput
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.ipv4.tcp_congestion_control = $TCP_CC
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 524288
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# UDP - high throughput
net.ipv4.udp_mem = $udp_mem

# UNIX
net.unix.max_dgram_qlen = 512

# VM - RAM-aware high throughput
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 15
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security (rp_filter=2 loose mode)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_stale_time = 60
kernel.panic = 1

EOF
            ;;
        vpn-low-latency)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: vpn-low-latency - Low latency/jitter, smaller buffers
################################################################

# File system
fs.file-max = 67108864

# Packet forwarding for VPN/Tunnels/Docker
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - low latency (smaller buffers)
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 10000
net.core.optmem_max = 262144
net.core.somaxconn = 8192
net.core.rmem_max = 8388608
net.core.rmem_default = 212992
net.core.wmem_max = 8388608
net.core.wmem_default = 212992

# TCP - low latency
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 87380 8388608
net.ipv4.tcp_congestion_control = $TCP_CC
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 72000
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# UDP - low latency
net.ipv4.udp_mem = $udp_mem

# UNIX
net.unix.max_dgram_qlen = 256

# VM - RAM-aware low latency
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 10
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security (rp_filter=2 loose mode)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60
kernel.panic = 1

EOF
            if [ "$busy_poll_supported" = "1" ]; then
                {
                    echo "# Busy poll - conservative"
                    echo "net.core.busy_poll = 50"
                    echo "net.core.busy_read = 50"
                } >> "$SYS_OPTIMIZER_PATH"
                yellow_msg "Enabled conservative busy_poll (50) - kernel supports it"
            else
                yellow_msg "Skipping busy_poll - not supported by current kernel"
            fi
            ;;
        conservative)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: conservative - Minimal changes, safe improvements only
################################################################

# File system - minimal increase
fs.file-max = 2097152

# Packet forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - conservative
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 5000
net.core.optmem_max = 204800
net.core.somaxconn = 4096

# TCP - conservative
net.ipv4.tcp_congestion_control = $TCP_CC
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 720
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 144000
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 0

# VM - minimal
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 30
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 20
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security (rp_filter=2 loose mode)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
kernel.panic = 1

EOF
            ;;
    esac

    if [ ! -s "$SYS_OPTIMIZER_PATH" ]; then
        red_msg "Generated sysctl config is empty!"
        return 1
    fi

    local dup_keys
    dup_keys=$(grep -v "^#" "$SYS_OPTIMIZER_PATH" | grep -v "^$" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort | uniq -d)
    if [ -n "$dup_keys" ]; then
        red_msg "Duplicate keys found in generated config:"
        echo "$dup_keys"
        return 1
    fi

    if grep -q "99-optimizer" "$SYS_PATH" 2>/dev/null; then
        sed -i '/99-optimizer/d' "$SYS_PATH"
    fi

    for key in fs.file-max net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.core.default_qdisc net.core.netdev_max_backlog net.core.optmem_max net.core.somaxconn net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.core.busy_poll net.core.busy_read net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_probes net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_max_orphans net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_mem net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.ipv4.tcp_retries2 net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_ecn net.ipv4.tcp_ecn_fallback net.ipv4.tcp_syncookies net.ipv4.tcp_fastopen net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range net.ipv4.udp_mem net.unix.max_dgram_qlen vm.min_free_kbytes vm.swappiness vm.vfs_cache_pressure net.ipv4.conf.default.rp_filter net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_source_route net.ipv4.conf.default.accept_source_route net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3 net.ipv4.neigh.default.gc_stale_time kernel.panic vm.dirty_ratio vm.overcommit_memory vm.overcommit_ratio; do
        if grep -q "^${key}[[:space:]]*=" "$SYS_PATH" 2>/dev/null; then
            if grep -q "^${key}[[:space:]]*=" "$SYS_OPTIMIZER_PATH" 2>/dev/null; then
                sed -i "/^${key//./\\.}[[:space:]]*=/d" "$SYS_PATH"
            fi
        fi
    done

    chmod 644 "$SYS_OPTIMIZER_PATH"

    echo
    yellow_msg "Applying sysctl settings (profile: $selected_profile)..."
    local apply_log
    apply_log=$(mktemp)
    if sysctl --system 2>&1 | tee "$apply_log"; then
        if grep -q -i "error\|invalid\|cannot stat\|unknown key\|permission denied" "$apply_log"; then
            yellow_msg "Some sysctl keys reported warnings (likely unsupported on this kernel):"
            grep -i "error\|invalid\|cannot stat\|unknown key\|permission denied" "$apply_log" | head -n 20
            yellow_msg "Continuing - unsupported keys ignored, other settings applied"
        else
            green_msg "sysctl --system applied successfully"
        fi
    else
        yellow_msg "sysctl --system had warnings, checking details..."
        if grep -q -i "error\|invalid\|cannot stat\|unknown key" "$apply_log"; then
            yellow_msg "Failed keys:"
            grep -i "error\|invalid\|cannot stat\|unknown key\|permission denied" "$apply_log" | head -n 20
        fi
        yellow_msg "Trying sysctl -p $SYS_OPTIMIZER_PATH for detailed errors..."
        local p_log
        p_log=$(mktemp)
        if sysctl -p "$SYS_OPTIMIZER_PATH" 2>&1 | tee "$p_log"; then
            if grep -q -i "error\|invalid" "$p_log"; then
                yellow_msg "Some keys in $SYS_OPTIMIZER_PATH unsupported:"
                grep -i "error\|invalid" "$p_log"
            else
                green_msg "sysctl -p applied successfully"
            fi
        else
            red_msg "sysctl -p also reported errors:"
            cat "$p_log"
            yellow_msg "Continuing - unsupported keys ignored"
        fi
        rm -f "$p_log"
    fi
    rm -f "$apply_log"

    echo
    green_msg "Network is Optimized (profile: $selected_profile). Config: $SYS_OPTIMIZER_PATH"
    echo
    sleep 0.5
}

# Remove old SSH config
remove_old_ssh_conf() {
    if [ ! -f "$SSH_PATH" ]; then
        red_msg "SSH config not found, skipping backup"
        return 0
    fi
    cp "$SSH_PATH" "/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
    echo
    yellow_msg "Default SSH Config file Saved to /etc/ssh/sshd_config.bak.*"
    echo
    sleep 1

    sed -i -e 's/^\s*#\?UseDNS.*/UseDNS no/' \
        -e 's/^\s*#\?Compression.*/Compression yes/' \
        -e '/^\s*Ciphers.*/d' \
        -e '/^\s*MaxAuthTries/d' \
        -e '/^\s*MaxSessions/d' \
        -e '/^\s*TCPKeepAlive/d' \
        -e '/^\s*ClientAliveInterval/d' \
        -e '/^\s*ClientAliveCountMax/d' \
        -e '/^\s*AllowAgentForwarding/d' \
        -e '/^\s*AllowTcpForwarding/d' \
        -e '/^\s*GatewayPorts/d' \
        -e '/^\s*PermitTunnel/d' \
        -e '/^\s*X11Forwarding/d' "$SSH_PATH"

    if ! grep -q "^Ciphers" "$SSH_PATH"; then
        echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" >> "$SSH_PATH"
    fi
}

# Update SSH config
update_sshd_conf() {
    echo
    yellow_msg 'Optimizing SSH...'
    echo
    sleep 0.5

    set_sshd_opt() {
        local key="$1" val="$2"
        if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$SSH_PATH"; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$SSH_PATH"
        else
            echo "${key} ${val}" >> "$SSH_PATH"
        fi
    }

    set_sshd_opt "TCPKeepAlive" "yes"
    set_sshd_opt "ClientAliveInterval" "300"
    set_sshd_opt "ClientAliveCountMax" "3"
    set_sshd_opt "AllowTcpForwarding" "yes"
    set_sshd_opt "GatewayPorts" "no"
    set_sshd_opt "PermitTunnel" "no"
    set_sshd_opt "X11Forwarding" "no"
    set_sshd_opt "AllowAgentForwarding" "yes"

    if sshd -t 2>/dev/null; then
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            green_msg 'SSH is Optimized.'
        else
            red_msg 'SSH config test passed but restart failed - try manually: systemctl restart ssh'
        fi
    else
        red_msg 'sshd -t failed - NOT restarting SSH to avoid lockout. Check /etc/ssh/sshd_config'
        sshd -t
    fi
    echo
    sleep 0.5
}

# System Limits Optimizations
limits_optimizations() {
    echo
    yellow_msg 'Optimizing System Limits...'
    echo
    sleep 0.5

    optimizer_ulimits=(
        "ulimit -c unlimited"
        "ulimit -d unlimited"
        "ulimit -f unlimited"
        "ulimit -i unlimited"
        "ulimit -l unlimited"
        "ulimit -m unlimited"
        "ulimit -n 1048576"
        "ulimit -q unlimited"
        "ulimit -s -H 65536"
        "ulimit -s 32768"
        "ulimit -t unlimited"
        "ulimit -u unlimited"
        "ulimit -v unlimited"
        "ulimit -x unlimited"
    )
    found_optimizer_entry=false
    for entry in "${optimizer_ulimits[@]}"; do
        if grep -qF "$entry" "$PROF_PATH" 2>/dev/null; then
            found_optimizer_entry=true
            break
        fi
    done
    if [ "$found_optimizer_entry" = true ]; then
        yellow_msg "Cleaning old optimizer ulimit entries from $PROF_PATH (preserving custom user entries)"
        cp "$PROF_PATH" "/etc/profile.bak.$(date +%F-%H%M%S)"
        tmp_prof="${PROF_PATH}.tmp.$$"
        : > "$tmp_prof"
        while IFS= read -r line || [ -n "$line" ]; do
            trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            skip=false
            for entry in "${optimizer_ulimits[@]}"; do
                if [ "$trimmed" = "$entry" ]; then
                    skip=true
                    break
                fi
            done
            if [ "$skip" = false ]; then
                printf '%s\n' "$line" >> "$tmp_prof"
            else
                yellow_msg "Removed optimizer entry: $trimmed"
            fi
        done < "$PROF_PATH"
        mv "$tmp_prof" "$PROF_PATH"
    else
        yellow_msg "No optimizer ulimit entries found in $PROF_PATH, leaving custom entries untouched"
    fi

    cat > "$LIMITS_CONF" <<'EOF'
# /etc/security/limits.d/99-optimizer.conf - Fixed
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
*               soft    nproc           unlimited
*               hard    nproc           unlimited
*               soft    memlock         unlimited
*               hard    memlock         unlimited
*               soft    core            unlimited
*               hard    core            unlimited
*               soft    stack           32768
*               hard    stack           65536
EOF
    chmod 644 "$LIMITS_CONF"

    for conf in /etc/systemd/system.conf /etc/systemd/user.conf; do
        if [ -f "$conf" ]; then
            if ! grep -q "DefaultLimitNOFILE=1048576" "$conf"; then
                cp "$conf" "${conf}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
                sed -i '/^DefaultLimitNOFILE/d' "$conf"
                sed -i '/^DefaultLimitNPROC/d' "$conf"
                sed -i '/^DefaultLimitMEMLOCK/d' "$conf"
                {
                    echo "DefaultLimitNOFILE=1048576"
                    echo "DefaultLimitNPROC=infinity"
                    echo "DefaultLimitMEMLOCK=infinity"
                } >> "$conf"
            fi
        fi
    done

    if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    echo
    green_msg 'System Limits are Optimized. Config: /etc/security/limits.d/99-optimizer.conf (re-login required)'
    echo
    sleep 0.5
}

# Show Menu
show_menu() {
    echo
    yellow_msg 'Choose One Option: '
    echo
    green_msg '1  - Apply Everything (Update + Packages + SWAP + Network + SSH + Limits) (RECOMMENDED)'
    echo
    green_msg '2  - Complete Update + Useful Packages + Make SWAP + Optimize Network, SSH & System Limits'
    green_msg '3  - Complete Update + Make SWAP + Optimize Network, SSH & System Limits'
    echo
    green_msg '4  - Complete Update & Clean the OS.'
    green_msg '5  - Install Useful Packages.'
    green_msg '6  - Make SWAP (2Gb).'
    green_msg '7  - Optimize the Network, SSH & System Limits.'
    echo
    green_msg '8  - Optimize the Network settings.'
    green_msg '9  - Optimize the SSH settings.'
    green_msg '10 - Optimize the System Limits.'
    echo
    red_msg 'q - Exit.'
    echo
}

# Main Execution Loop
main() {
    while true; do
        show_menu
        read -rp 'Enter Your Choice: ' choice
        case $choice in
        1)
            apply_everything
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        2)
            complete_update
            sleep 0.5
            installations
            enable_packages
            sleep 0.5
            swap_maker
            sleep 0.5
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        3)
            complete_update
            sleep 0.5
            swap_maker
            sleep 0.5
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        4)
            complete_update
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        5)
            complete_update
            sleep 0.5
            installations
            enable_packages
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        6)
            swap_maker
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        7)
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        8)
            sysctl_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ;;
        9)
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ;;
        10)
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        q|Q)
            exit 0
            ;;
        *)
            red_msg 'Wrong input!'
            ;;
        esac
    done
}

# Apply Everything
apply_everything() {
    complete_update
    sleep 0.5
    disable_terminal_ads
    sleep 0.5
    installations
    enable_packages
    sleep 0.5
    swap_maker
    sleep 0.5
    sysctl_optimizations
    sleep 0.5
    remove_old_ssh_conf
    sleep 0.5
    update_sshd_conf
    sleep 0.5
    limits_optimizations
    sleep 0.5
}

main
