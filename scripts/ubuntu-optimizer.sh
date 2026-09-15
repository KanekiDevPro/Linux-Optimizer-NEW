#!/usr/bin/env bash
###############################################################################
# Linux Optimizer — production VPS tuning for Debian/Ubuntu
#
# Target: high-throughput proxy / relay / tunnel / VPN servers with many
# concurrent TCP connections.
#
# Usage:
#   sudo ./linux-optimizer.sh                        # interactive menu
#   sudo ./linux-optimizer.sh --all --profile auto -y
#   sudo ./linux-optimizer.sh --network --profile vpn-high-throughput
#   sudo ./linux-optimizer.sh --swap --swap-size 4G
#
# Options:
#   --all                  run the full pipeline (same as menu option 1)
#   --update               apt update + full-upgrade + cleanup
#   --packages             install minimal useful packages
#   --swap                 create/verify swap file
#   --network              sysctl network tuning
#   --ssh                  SSH tuning (safe reload, never restart)
#   --limits               system limits tuning (finite values)
#   --profile NAME         balanced | vpn-high-throughput |
#                          vpn-low-latency | conservative | auto
#   --swap-size SIZE       e.g. 2G, 4096M (default: 2G)
#   -y, --yes              assume "yes" where safe (reboot only if required)
#   -h, --help             show this help
#
# DELIBERATE divergences from naive "optimizer" advice (read before changing):
#   * net.ipv4.tcp_tw_reuse is NOT set. Since kernel 4.x it only affects
#     *outgoing* connections and is a no-op for a listening server; with NAT
#     in front it can break clients unless tcp_timestamps is on. TIME_WAIT
#     pressure is handled via tcp_max_tw_buckets + syncookies + timestamps.
#   * net.ipv4.ip_local_port_range is 10000 65535, NOT 1024 65535. Starting
#     at 1024 collides ephemeral ports with well-known service ports
#     (3128, 3306, 51820, ...) -> "Address already in use" on bind().
#     10000-65535 gives ~55k ports; genuinely reserved service ports are
#     additionally protected via ip_local_reserved_ports below.
#   * No hardcoded Ciphers list. Distro OpenSSH defaults are maintained by
#     the security team; a pinned list rots and silently disables future
#     (incl. post-quantum) algorithms.
#   * kernel.panic = 10, not 1: a 1-second reboot loop destroys the crash
#     evidence you need to diagnose the panic.
#
# Idempotency: re-running produces the same files. Managed sysctl/limits
# files are overwritten atomically; /etc/sysctl.conf, sshd_config, fstab and
# systemd configs only get conflicting *managed* keys replaced, everything
# else is preserved. Backups are rotated (last 5 kept).
###############################################################################

set -uo pipefail

readonly SCRIPT_VERSION="2.0.5"
readonly SCRIPT_NAME="$(basename "$0")"

# --- Paths & defaults (overridable via CLI/env) ------------------------------
SYS_PATH="/etc/sysctl.conf"
SYS_OPTIMIZER_PATH="/etc/sysctl.d/99-optimizer.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SSH_DROPIN_PATH="/etc/ssh/sshd_config.d/00-optimizer.conf"
SSH_DROPIN_LEGACY="/etc/ssh/sshd_config.d/99-optimizer.conf"
SSH_USE_DROPIN=0
SSH_MAIN_SNAP=""
SSH_DROPIN_SNAP=""
SSH_DROPIN_LEGACY_SNAP=""
BACKUP_LAST=""
SWAP_PATH="/swapfile"
SWAP_SIZE="${SWAP_SIZE:-2G}"
LIMITS_CONF="/etc/security/limits.d/99-optimizer.conf"
APT_UPDATED=0
ASSUME_YES=0
BACKUP_KEEP=5
FAILED_STEPS=()

# --- Temp-file tracking -------------------------------------------------------
OPT_TMPFILES=()
cleanup_tmp() { rm -f "${OPT_TMPFILES[@]:-}" 2>/dev/null || true; release_lock 2>/dev/null || true; }
trap cleanup_tmp EXIT
new_tmp() {
    local f
    f="$(mktemp)" || return 1
    OPT_TMPFILES+=("$f")
    printf '%s' "$f"
}

# --- Failure tracking ---------------------------------------------------------
# Pipelines stay resilient (a failed stage does not abort the rest), but the
# FINAL status is always honest: any recorded failure suppresses "Done".
reset_failures() { FAILED_STEPS=(); }

record_failure() {
    # record_failure <step-name>
    FAILED_STEPS+=("${1:-unknown}")
    return 0
}

run_step() {
    # run_step <step-name> <command...>: run it, record on failure, never abort.
    local step="$1"; shift
    if "$@"; then
        return 0
    fi
    record_failure "$step"
    return 1
}

report_failures() {
    # report_failures: summarize recorded failures; return 1 if any exist.
    if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
        return 0
    fi
    red_msg "FAILED stages (${#FAILED_STEPS[@]}): ${FAILED_STEPS[*]}"
    return 1
}

print_final_status() {
    # print_final_status: honest tail banner for pipelines (replaces a blind
    # "Done" that would also print after failures).
    if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
        echo
        green_msg '========================='
        green_msg 'Done.'
        green_msg '========================='
        return 0
    fi
    echo
    red_msg '========================='
    red_msg "Completed WITH FAILURES: ${FAILED_STEPS[*]}"
    red_msg '========================='
    return 1
}

# require_arg_value <option> <candidate>: guard for options expecting a value.
require_arg_value() {
    local opt="$1" val="${2:-}"
    if [ -z "$val" ]; then
        red_msg "Missing value for $opt."
        return 1
    fi
    case "$val" in
        --*)
            red_msg "Missing value for $opt (got another option: $val)."
            return 1
            ;;
    esac
    return 0
}

# --- Concurrency protection ---------------------------------------------------
# A second simultaneous invocation must fail cleanly instead of interleaving
# fstab/sshd/sysctl edits and backup rotation with the first run.
OPT_LOCK_FILE=""
OPT_LOCK_DIR=""
acquire_lock() {
    local d
    for d in /run/lock /var/lock /tmp; do
        if [ -d "$d" ] && [ -w "$d" ] 2>/dev/null; then
            OPT_LOCK_FILE="$d/linux-optimizer.lock"
            break
        fi
    done
    [ -n "$OPT_LOCK_FILE" ] || OPT_LOCK_FILE="/tmp/linux-optimizer.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$OPT_LOCK_FILE" 2>/dev/null || {
            red_msg "Cannot open lock file $OPT_LOCK_FILE."
            return 1
        }
        if ! flock -n 9 2>/dev/null; then
            red_msg "Another instance is already running (lock: $OPT_LOCK_FILE). Exiting."
            return 1
        fi
        return 0
    fi
    # Fallback for minimal systems without flock(1): mkdir is atomic.
    OPT_LOCK_DIR="${OPT_LOCK_FILE}.d"
    if ! mkdir "$OPT_LOCK_DIR" 2>/dev/null; then
        red_msg "Another instance is already running (lock: $OPT_LOCK_DIR). Exiting."
        return 1
    fi
    return 0
}

release_lock() {
    [ -n "${OPT_LOCK_DIR:-}" ] && [ -d "$OPT_LOCK_DIR" ] && rmdir "$OPT_LOCK_DIR" 2>/dev/null
    return 0
}

# --- Logging ------------------------------------------------------------------
green_msg() {
    tput setaf 2 2>/dev/null || true
    # shellcheck disable=SC2059
    printf '[*] ----- %s\n' "$*"
    tput sgr0 2>/dev/null || true
}

yellow_msg() {
    tput setaf 3 2>/dev/null || true
    # shellcheck disable=SC2059
    printf '[*] ----- %s\n' "$*"
    tput sgr0 2>/dev/null || true
}

red_msg() {
    tput setaf 1 2>/dev/null || true
    # shellcheck disable=SC2059
    printf '[*] ----- %s\n' "$*" >&2
    tput sgr0 2>/dev/null || true
}

# --- Helpers ------------------------------------------------------------------
# Per-run unique suffix so two backups of the same file (even within one
# second, even from concurrent runs) can never share a filename.
RUN_STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo norun)-$$"
BACKUP_SEQ=0
backup_file() {
    # backup_file <path> : timestamped copy, rotate to BACKUP_KEEP newest.
    # Sets BACKUP_LAST to the exact path created (empty if source missing).
    local src="$1" dst nanos
    BACKUP_LAST=""
    [ -f "$src" ] || return 0
    nanos=$(date +%N 2>/dev/null || echo "$RANDOM")
    case "$nanos" in ''|*[!0-9]*) nanos="$RANDOM" ;; esac
    BACKUP_SEQ=$((BACKUP_SEQ + 1))
    dst="${src}.bak.$(date +%F-%H%M%S)-${RUN_STAMP}-${nanos}-${BACKUP_SEQ}-$$"
    cp -p "$src" "$dst" 2>/dev/null || return 1
    BACKUP_LAST="$dst"
    local pattern="${src}.bak.*"
    # shellcheck disable=SC2086
    ls -1t $pattern 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f --
    green_msg "Backup created: $dst"
}

is_container() {
    # LXC / OpenVZ / Docker / Podman / nspawn cannot enable swap from inside
    # (the host controls it), so swap_maker skips gracefully there.
    if [ -f /.dockerenv ]; then return 0; fi
    if [ -f /run/.containerenv ]; then return 0; fi
    if [ -n "${container:-}" ]; then return 0; fi
    if grep -qaE 'container=(lxc|docker|podman|systemd-nspawn)' /proc/1/environ 2>/dev/null; then return 0; fi
    if grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then return 0; fi
    if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then return 0; fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt -c -q 2>/dev/null && return 0
    fi
    return 1
}

reboot_required() {
    [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]
}

# Surface a pending reboot without forcing one (for non-interactive paths that
# never prompt). Never reboots; only informs.
notify_reboot_if_required() {
    if reboot_required; then
        yellow_msg "A reboot is required (see /var/run/reboot-required). Reboot when convenient: reboot"
    else
        green_msg "No reboot required (no pending kernel/core update)."
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

check_supported_os() {
    local id="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"
    fi
    case "$id" in
        ubuntu|debian) ;;
        *)
            red_msg "Unsupported OS: '$id'. This script targets Ubuntu/Debian only."
            exit 1
            ;;
    esac
}

print_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# Central package list guard
apt_update_once() {
    if [ "$APT_UPDATED" = "1" ]; then
        yellow_msg "Skipping package list update (already done this run)"
        return 0
    fi
    yellow_msg "Running package list update..."
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update; then
        APT_UPDATED=1
        return 0
    else
        yellow_msg "package list update failed (will retry on next call)"
        return 1
    fi
}

has_failures() { [ "${#FAILED_STEPS[@]}" -gt 0 ]; }

# Ask Reboot (only when the system actually needs it).
# INVARIANT: FAILED_STEPS non-empty => reboot MUST NOT execute automatically.
# On failure paths callers must use ask_reboot_guarded instead, which withholds
# the reboot and preserves the non-zero status.
ask_reboot() {
    if has_failures; then
        if reboot_required; then
            red_msg "Reboot is required BUT WITHHELD: this run has failures (${FAILED_STEPS[*]}). Review the errors above and reboot manually when fixed."
        else
            yellow_msg "Run completed with failures (${FAILED_STEPS[*]}); no reboot pending."
        fi
        return 1
    fi
    if [ ! -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
        yellow_msg "Non-interactive shell: skipping reboot prompt."
        return 0
    fi
    if ! reboot_required; then
        green_msg "No reboot required (no pending kernel/core update)."
        return 0
    fi
    yellow_msg "A reboot is required (see /var/run/reboot-required)."
    if [ "$ASSUME_YES" = "1" ]; then
        yellow_msg "--yes given, rebooting..."
        reboot
        exit 0
    fi
    yellow_msg 'Reboot now? (y/n)'
    echo
    local choice=""
    while true; do
        if ! read -r choice; then
            echo
            return 0
        fi
        echo
        if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
            reboot
            exit 0
        fi
        if [[ "$choice" == 'n' || "$choice" == 'N' ]]; then
            break
        fi
        yellow_msg 'Please answer y or n.'
    done
}

# Guarded reboot entry point for pipelines: never reboots when FAILED_STEPS is
# non-empty (withholds + warns), otherwise behaves exactly like ask_reboot.
# Returns 0 on the success path, 1 when failures were recorded.
ask_reboot_guarded() {
    if has_failures; then
        if reboot_required; then
            red_msg "Reboot is required BUT WITHHELD: this run has failures (${FAILED_STEPS[*]}). Review the errors above and reboot manually when fixed."
        else
            yellow_msg "Run completed with failures (${FAILED_STEPS[*]}); no reboot pending."
        fi
        return 1
    fi
    ask_reboot
}

# Update & Upgrade & Remove & Clean
complete_update() {
    echo
    yellow_msg 'Updating the System... (This can take a while.)'
    echo

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt_update_once || yellow_msg "package list update had warnings, continuing..."
    # NOTE: full-upgrade alone covers upgrade; running both is redundant.
    if ! apt-get -y full-upgrade; then
        red_msg "System upgrade FAILED (apt-get full-upgrade returned non-zero) - NOT reporting success."
        echo
        return 1
    fi
    if ! apt-get -y autoremove --purge; then
        red_msg "apt autoremove reported errors (upgrade itself succeeded) - NOT reporting success."
        echo
        return 1
    fi
    # NOTE: clean covers autoclean; one is enough.
    if ! apt-get -y clean; then
        red_msg "apt clean reported errors (upgrade itself succeeded) - NOT reporting success."
        echo
        return 1
    fi

    echo
    green_msg 'System Updated & Cleaned Successfully.'
    echo
}

# Disable Terminal Ads
disable_terminal_ads() {
    echo
    yellow_msg 'Disabling Terminal Ads...'
    echo

    if [ -f /etc/default/motd-news ]; then
        backup_file /etc/default/motd-news
        sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    fi
    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false || true
    fi

    echo
    green_msg 'Terminal Ads Disabled.'
    echo
}

# Install useful packages (minimal production footprint)
installations() {
    echo
    yellow_msg 'Installing Useful Packages...'
    echo

    export DEBIAN_FRONTEND=noninteractive
    apt_update_once || yellow_msg "package list update had warnings, continuing..."

    # Rationale per group:
    #  base/net: required by this script or by tunnel/proxy tooling
    #    (iproute2+ethtool+kmod+procps = detection & diagnostics; socat = relay;
    #     qrencode = subscription QR codes; cron = jobs)
    #  ops: editor/monitor/archive basics. No -dev toolchains, no packagekit
    #    (pulls desktop/dbus stack), no busybox (redundant on systemd distros),
    #    no net-tools (deprecated; iproute2 replaces it), no ubuntu-keyring
    #    (breaks pure Debian).
    local packages=(
        apt-transport-https apt-utils bash-completion ca-certificates cron
        curl gnupg iproute2 ethtool kmod procps locales lsb-release
        software-properties-common
        git python3
        htop nano vim screen dialog unzip zip xxd qrencode socat jq wget
    )

    # Idempotent: install only what is missing, in ONE apt transaction.
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        [ -n "$pkg" ] || continue
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    local failed_pkgs=()
    if [ "${#missing[@]}" -eq 0 ]; then
        yellow_msg "All useful packages already installed, nothing to do."
    else
        yellow_msg "Installing missing: ${missing[*]}"
        if ! apt-get -y --no-install-recommends install "${missing[@]}"; then
            # Fall back per-package so one bad name cannot sink the batch,
            # and report honestly instead of claiming success.
            yellow_msg "Batch install had errors, retrying per-package..."
            for pkg in "${missing[@]}"; do
                yellow_msg "Installing $pkg ..."
                if ! apt-get -y --no-install-recommends install "$pkg"; then
                    yellow_msg "Warning: failed to install $pkg, skipping"
                    failed_pkgs+=("$pkg")
                fi
            done
        fi
    fi

    if [ "${#failed_pkgs[@]}" -gt 0 ]; then
        yellow_msg "Some packages failed/skipped: ${failed_pkgs[*]}"
        red_msg "Package installation INCOMPLETE - see warnings above."
        return 1
    fi

    echo
    green_msg 'Useful Packages Installed Successfully.'
    echo
}

# Enable packages at server boot
enable_packages() {
    local svc
    for svc in cron; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
            systemctl enable --now "$svc" 2>/dev/null || systemctl enable "$svc" 2>/dev/null || true
        fi
    done
    echo
    green_msg 'Packages Enabled Successfully.'
    echo
}

# swap_entry_active <path>: true when /etc/fstab contains an ACTIVE
# (non-comment, non-blank) line referencing the path. Commented or stale
# mentions do not count (and must never be deleted as "duplicates").
swap_entry_active() {
    [ -f /etc/fstab ] || return 1
    grep -vE '^[[:space:]]*(#|$)' /etc/fstab 2>/dev/null | grep -qF "$1"
}

# swap_build_file <target> [dd]: allocate + mkswap a swap file WITHOUT
# activating it. Sets SWAP_BUILT_WITH to "fallocate" or "dd". Never touches
# the live swap or fstab; safe to run against a staging path.
SWAP_BUILT_WITH=""
swap_build_file() {
    local target="$1" mode="${2:-auto}" tdir
    SWAP_BUILT_WITH=""
    tdir=$(dirname "$target")
    [ -d "$tdir" ] || tdir="/"
    # CoW/odd filesystems: fallocate leaves holes swapon rejects
    # ("swapfile has holes"). dd writes real blocks everywhere.
    local fstype use_dd_only=0 btrfs_nocow=0
    fstype=$(stat -f -c %T "$tdir" 2>/dev/null || echo unknown)
    case "$fstype" in
        btrfs)
            yellow_msg "Filesystem btrfs: using dd + NOCOW (mandatory for swap on btrfs)."
            use_dd_only=1
            btrfs_nocow=1
            ;;
        overlayfs|aufs|zfs|xfs)
            yellow_msg "Filesystem $fstype does not support fallocate swap, using dd directly."
            use_dd_only=1
            ;;
    esac
    [ "$mode" = "dd" ] && use_dd_only=1
    yellow_msg "Allocating $SWAP_SIZE at $target..."
    local created_with_fallocate=false
    if [ "$use_dd_only" -eq 0 ]; then
        if fallocate -l "$SWAP_SIZE" "$target" 2>/dev/null; then
            created_with_fallocate=true
        else
            yellow_msg "fallocate unavailable/failed, falling back to dd..."
        fi
    fi
    if [ "$created_with_fallocate" = true ]; then
        SWAP_BUILT_WITH="fallocate"
    else
        local count
        count=$(swap_size_to_mb "$SWAP_SIZE")
        if [ "$btrfs_nocow" -eq 1 ]; then
            # btrfs REQUIRES a fresh NOCOW file: preallocate empty, set the
            # flag, THEN write data. chattr +C on an existing non-empty file
            # is a silent no-op, so order matters.
            rm -f "$target"
            touch "$target"
            chmod 600 "$target"
            if ! chattr +C "$target" 2>/dev/null; then
                red_msg "btrfs: cannot set NOCOW on $target - swap is unsupported on this subvolume (compressed/odd mount?). Leaving NO swap; system runs without it."
                rm -f "$target"
                return 1
            fi
        fi
        if ! dd if=/dev/zero of="$target" bs=1M count="$count" status=none; then
            red_msg "Failed to create swap file via dd"
            rm -f "$target"
            return 1
        fi
        SWAP_BUILT_WITH="dd"
    fi
    chmod 600 "$target"
    if ! mkswap "$target" >/dev/null 2>&1; then
        red_msg "mkswap failed"
        rm -f "$target"
        return 1
    fi
    return 0
}

# Swap Maker — idempotent, container-aware, fstype-aware
swap_maker() {
    echo
    yellow_msg 'Making SWAP Space...'
    echo

    if is_container; then
        yellow_msg "Container detected: swap cannot be enabled from inside (host controls it). Skipping."
        return 0
    fi

    validate_swap_size "$SWAP_SIZE" || return 1

    local SWAP_REPLACE=0
    # Idempotent: already-active swap of the right size -> nothing to do.
    # NOTE: /proc/swaps "Size" excludes the swap header page, so an exact
    # KB comparison NEVER matches the requested size (2G file shows as
    # 2097148K, not 2097152K). Compare the backing FILE size instead,
    # with 1MB tolerance for rounding.
    if grep -qs "^${SWAP_PATH}[[:space:]]" /proc/swaps; then
        local cur_bytes="" want_bytes="" diff_bytes=""
        cur_bytes=$(stat -c %s "$SWAP_PATH" 2>/dev/null || echo 0)
        want_bytes=$(( $(swap_size_to_mb "$SWAP_SIZE") * 1024 * 1024 ))
        diff_bytes=$(( ${cur_bytes:-0} - ${want_bytes:-0} ))
        if [ "${diff_bytes#-}" -le 1048576 ]; then
            if swap_entry_active "$SWAP_PATH"; then
                green_msg "Swap $SWAP_PATH already active (correct size) with fstab entry. Nothing to do."
                echo
                return 0
            fi
            # Correct file, correct size, only the fstab entry is missing:
            # preserve the live swap file and just repair persistence instead
            # of swapoff/rm/dd for no reason.
            yellow_msg "Swap $SWAP_PATH is active with the correct size but its fstab entry is missing. Repairing fstab only (keeping the live swap file)."
            backup_file /etc/fstab
            echo "$SWAP_PATH   none    swap    sw,nofail    0   0" >> /etc/fstab
            swapon -a 2>/dev/null || true
            if grep -qs "^${SWAP_PATH}[[:space:]]" /proc/swaps && swap_entry_active "$SWAP_PATH"; then
                green_msg "Swap $SWAP_PATH already active (correct size); fstab entry restored. Nothing else to do."
                echo
                return 0
            fi
            red_msg "Failed to restore the fstab entry for $SWAP_PATH."
            return 1
        fi
        yellow_msg "Swap $SWAP_PATH is active but differs from desired $SWAP_SIZE. Preparing replacement FIRST (old swap stays live until the new file is proven)..."
        SWAP_REPLACE=1
    else
        SWAP_REPLACE=0
    fi

    if [ "${SWAP_REPLACE:-0}" = "1" ]; then
        # Safe recreate: stage at $SWAP_PATH.new, mkswap it, and only then
        # swapoff the old file + move the new one into place. A failure here
        # leaves the old working swap untouched (never worse than before).
        if ! swap_build_file "${SWAP_PATH}.new"; then
            red_msg "Replacement swap preparation failed; keeping the existing working swap at $SWAP_PATH."
            rm -f "${SWAP_PATH}.new"
            return 1
        fi
        yellow_msg "Replacement swap prepared; switching over..."
        if ! swapoff "$SWAP_PATH" 2>/dev/null; then
            red_msg "Failed to swapoff $SWAP_PATH - keeping existing swap; discarding replacement."
            rm -f "${SWAP_PATH}.new"
            return 1
        fi
        rm -f "$SWAP_PATH"
        if ! mv -f "${SWAP_PATH}.new" "$SWAP_PATH"; then
            red_msg "Failed to install replacement swap; trying to re-enable previous state."
            swapon "$SWAP_PATH" 2>/dev/null || true
            rm -f "${SWAP_PATH}.new"
            return 1
        fi
        chmod 600 "$SWAP_PATH"
        if ! swapon "$SWAP_PATH" 2>/dev/null; then
            red_msg "swapon of the replacement failed; old swap was already off. Check dmesg."
            return 1
        fi
        if ! swap_entry_active "$SWAP_PATH"; then
            backup_file /etc/fstab
            echo "$SWAP_PATH   none    swap    sw,nofail    0   0" >> /etc/fstab
        fi
        if grep -qs "^${SWAP_PATH}[[:space:]]" /proc/swaps; then
            green_msg "SWAP Recreated & Activated Successfully."
        else
            red_msg "SWAP recreation verification failed"
            return 1
        fi
        echo
        return 0
    fi

    if [ -f "$SWAP_PATH" ]; then
        yellow_msg "Old swap file found at $SWAP_PATH, removing..."
        rm -f "$SWAP_PATH"
    fi

    if swap_entry_active "$SWAP_PATH"; then
        yellow_msg "Removing old fstab entry for $SWAP_PATH"
        backup_file /etc/fstab
        # Delete only ACTIVE (non-comment, non-blank) lines referencing the
        # path; documentation comments mentioning it are preserved. awk keeps
        # this readable where a negated-address sed gets fragile.
        awk -v p="$SWAP_PATH" '($0 ~ /^[[:space:]]*(#|$)/) {print; next} index($0, p) == 0 {print}' /etc/fstab > /etc/fstab.optnew \
            && cat /etc/fstab.optnew > /etc/fstab && rm -f /etc/fstab.optnew
    elif grep -qF "$SWAP_PATH" /etc/fstab; then
        # Commented/stale mention only: leave documentation comments alone.
        yellow_msg "fstab mentions $SWAP_PATH only in non-active form; leaving it untouched."
    fi

    local swap_dir avail_mb swap_mb
    swap_dir=$(dirname "$SWAP_PATH")
    [ -d "$swap_dir" ] || swap_dir="/"
    avail_mb=$(df -m --output=avail "$swap_dir" 2>/dev/null | tail -n1 | tr -d ' ')
    swap_mb=$(swap_size_to_mb "$SWAP_SIZE")

    if ! [[ "$avail_mb" =~ ^[0-9]+$ ]]; then
        yellow_msg "Warning: could not determine free space for $swap_dir, skipping space check"
    elif [ "$avail_mb" -lt $((swap_mb + 100)) ]; then
        red_msg "Not enough disk space on $swap_dir. Available: ${avail_mb}M, Required: ${swap_mb}M + 100M overhead"
        return 1
    fi

    if ! swap_build_file "$SWAP_PATH"; then
        return 1
    fi
    # Capture swapon stderr: the exact message ("has holes" vs "Operation
    # not permitted") tells a CoW filesystem apart from a host that forbids
    # swap. Swallowing it (2>/dev/null) leaves the user guessing.
    local swapon_err=""
    if ! swapon_err=$(swapon "$SWAP_PATH" 2>&1); then
        if [ "${SWAP_BUILT_WITH:-}" = "fallocate" ]; then
            # Classic failure: fallocate hole-punching on an FS that
            # claims support but rejects swapon. Retry once with dd.
            yellow_msg "swapon rejected fallocate file: ${swapon_err:-unknown error}"
            yellow_msg "Retrying once with dd (real blocks, no holes)..."
            rm -f "$SWAP_PATH"
            if ! swap_build_file "$SWAP_PATH" dd; then
                red_msg "Failed to rebuild swap file via dd"
                return 1
            fi
            if ! swapon_err=$(swapon "$SWAP_PATH" 2>&1); then
                red_msg "swapon failed: ${swapon_err:-unknown error}"
                red_msg "Host likely forbids swap (container) or FS rejected it. Check dmesg. Continuing without swap."
                rm -f "$SWAP_PATH"
                return 1
            fi
        else
            red_msg "swapon failed: ${swapon_err:-unknown error}"
            red_msg "Common causes: container/host forbids swap, or CoW filesystem. Check dmesg."
            rm -f "$SWAP_PATH"
            return 1
        fi
    fi

    # Safe fstab entry with nofail to guarantee clean boot
    if ! swap_entry_active "$SWAP_PATH"; then
        backup_file /etc/fstab
        echo "$SWAP_PATH   none    swap    sw,nofail    0   0" >> /etc/fstab
    fi

    if grep -qs "^${SWAP_PATH}[[:space:]]" /proc/swaps; then
        green_msg "SWAP Created & Activated Successfully."
    else
        red_msg "SWAP creation verification failed"
        return 1
    fi

    echo
}

swap_size_to_mb() {
    # $1 like 2G/512M/1024K/2048 (bare = MB). 10# avoids octal surprises.
    local s="$1" n
    case "$s" in
        *[Gg]) n="10#${s%[Gg]}"; echo $((n * 1024)) ;;
        *[Mm]) echo "$((10#${s%[Mm]}))" ;;
        *[Kk]) n="10#${s%[Kk]}"; echo $((n / 1024 == 0 ? 1 : n / 1024)) ;;
        *)     echo "$((10#$s))" ;;
    esac
}

# Validate a swap-size string (e.g. 2G, 4096M, 512). Rejects bad formats and
# zero/degenerate sizes (0, 0G, 0M) that would only fail later in mkswap.
validate_swap_size() {
    local s="${1:-}" mb num
    if ! [[ "$s" =~ ^[0-9]+[GMKgmk]?$ ]]; then
        red_msg "Invalid SWAP_SIZE: $s (use e.g., 2G, 4096M)"
        return 1
    fi
    # Reject an explicit zero request in ANY unit before unit conversion can
    # round it up (e.g. swap_size_to_mb maps 0K -> max(1, 0) = 1MB).
    num="${s%[GMKgmk]}"
    num="${num%[gmk]}"
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$((10#$num))" -le 0 ]; then
        red_msg "Invalid SWAP_SIZE: $s (size must be greater than zero; use e.g., 2G, 4096M)"
        return 1
    fi
    mb=$(swap_size_to_mb "$s" 2>/dev/null || echo 0)
    if ! [[ "$mb" =~ ^[0-9]+$ ]] || [ "$mb" -le 0 ]; then
        red_msg "Invalid SWAP_SIZE: $s (size must be greater than zero; use e.g., 2G, 4096M)"
        return 1
    fi
    return 0
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
            echo $(((10#$mem_kb + 1048575) / 1048576))
            return
        fi
        local mem_mb
        mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
        if [ -n "$mem_mb" ] && [[ "$mem_mb" =~ ^[0-9]+$ ]]; then
            echo $(((10#$mem_mb + 1023) / 1024))
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
            local f bn
            for f in /sys/class/net/*; do
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
                        num=$((10#$num * 1000))
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
        # NOTE: virtio/KVM/Xen usually report -1/Unknown here, so speed-based
        # auto-selection is best-effort only; RAM/CPU decide.
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
        if [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
            echo
            yellow_msg "Select sysctl profile:"
            echo "  1) balanced              - General-purpose VPN/server (DEFAULT, stable + good perf)"
            echo "  2) vpn-high-throughput   - High-bandwidth relay/VPN, many connections (needs RAM/CPU)"
            echo "  3) vpn-low-latency       - Latency/jitter sensitive, smaller buffers"
            echo "  4) conservative          - Minimal changes, safe improvements only"
            echo "  5) auto                  - Auto-select throughput vs balanced (RAM/CPU/speed)"
            echo
            printf "Enter choice [1-5] (default 1): "
            local choice=""
            if ! read -r choice; then
                echo
                yellow_msg "EOF on stdin, defaulting to balanced"
                profile="balanced"
            else
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
            fi
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

    if [ -f "$SYS_PATH" ]; then
        backup_file "$SYS_PATH"
    fi

    # BBR: read-only detection first, try loading the module once.
    TCP_CC="bbr"
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null || true
        if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            yellow_msg "BBR not available (needs kernel >=4.9 / host support), falling back to cubic"
            TCP_CC="cubic"
        fi
    fi

    # QDISC: READ-ONLY detection. BBR's reference qdisc is fq; fq_codel is the
    # safe fallback. Never mutate a live interface or live sysctl as a "test".
    QDISC="fq_codel"
    if [ -d /sys/module/sch_fq ] || { command -v modinfo >/dev/null 2>&1 && modinfo sch_fq >/dev/null 2>&1; }; then
        if modprobe sch_fq 2>/dev/null || [ -d /sys/module/sch_fq ]; then
            QDISC="fq"
        fi
    fi
    if [ "$QDISC" = "fq" ] && [ "$selected_profile" = "vpn-low-latency" ]; then
        # fq without codel trades latency for throughput; latency profile
        # explicitly prefers fq_codel even when fq exists.
        QDISC="fq_codel"
    fi

    local tcp_mem="" udp_mem="" min_free_kbytes="" file_max=""
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

    # file-max must cover DefaultLimitNOFILE (1M) with headroom, but 67M
    # entries of ~1KB slab each can OOM a small VPS. Scale with intent.
    if [ "$selected_profile" = "conservative" ]; then
        file_max="1048576"
    elif [ "$ram_gb_num" -ge 4 ]; then
        file_max="4194304"
    else
        file_max="2097152"
    fi

    # conntrack only exists when nf_conntrack is loaded (absent on some VPS).
    local conntrack_max=""
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
        if [ "$selected_profile" = "vpn-high-throughput" ]; then
            conntrack_max="524288"
        elif [ "$selected_profile" != "conservative" ]; then
            conntrack_max="262144"
        fi
    fi

    local busy_poll_supported=0
    if sysctl -n net.core.busy_poll >/dev/null 2>&1; then
        busy_poll_supported=1
    fi

    local header_info
    header_info="# Generated: $timestamp (optimizer v$SCRIPT_VERSION)
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

    # Shared block: identical across throughput profiles so concurrent-proxy
    # tuning cannot drift between them.
    local common_net
    common_net="# Ephemeral range: 10000-65535 (~55k ports). Starts ABOVE
# well-known service ports on purpose (see script header). Extend the
# reserved list if you listen on other low ports.
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.ip_local_reserved_ports = 22,53,80,443,853,3128,8000,8080,8443,51820,51821
# NOTE: tcp_tw_reuse deliberately NOT set (outgoing-only since 4.x, no-op
# for servers, risky behind NAT). TIME_WAIT pressure is capped below.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fastopen = 1"

    local common_sec
    common_sec="# rp_filter=2 (loose) is REQUIRED here: tunnels, policy routing
# and asymmetric relay paths legitimately arrive on unexpected interfaces.
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0"

    local conntrack_line=""
    [ -n "$conntrack_max" ] && conntrack_line="net.netfilter.nf_conntrack_max = $conntrack_max"

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
fs.file-max = $file_max

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
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_adv_win_scale = 1
$common_net

# UDP - balanced
net.ipv4.udp_mem = $udp_mem

# VM - RAM-aware balanced
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security
$common_sec
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60
$conntrack_line
kernel.panic = 10
kernel.panic_on_oops = 1

EOF
            ;;
        vpn-high-throughput)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: vpn-high-throughput - High-bandwidth relay/VPN, many conns
################################################################

# File system
fs.file-max = $file_max

# Packet forwarding for VPN/Tunnels/Docker
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - high throughput
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.core.optmem_max = 524288
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_max = 33554432
net.core.wmem_default = 262144

# TCP - high throughput
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.ipv4.tcp_congestion_control = $TCP_CC
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 524288
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_adv_win_scale = 1
$common_net

# UDP - high throughput
net.ipv4.udp_mem = $udp_mem

# VM - RAM-aware high throughput
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security
$common_sec
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_stale_time = 60
$conntrack_line
kernel.panic = 10
kernel.panic_on_oops = 1

EOF
            ;;
        vpn-low-latency)
            cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimize
################################################################
$header_info
################################################################
# Profile: vpn-low-latency - Latency/jitter sensitive, smaller buffers
################################################################

# File system
fs.file-max = $file_max

# Packet forwarding for VPN/Tunnels/Docker
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network core - low latency (smaller buffers)
net.core.default_qdisc = $QDISC
net.core.netdev_max_backlog = 8192
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
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_notsent_lowat = 16384
# NOTE: tcp_sack/tcp_dsack/tcp_window_scaling come from the shared block
# below; do NOT re-add them here (duplicate keys fail the self-check).
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_adv_win_scale = 1
$common_net

# UDP - low latency
net.ipv4.udp_mem = $udp_mem

# VM - RAM-aware low latency
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security
$common_sec
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60
$conntrack_line
kernel.panic = 10
kernel.panic_on_oops = 1

EOF
            if [ "$busy_poll_supported" = "1" ]; then
                {
                    echo "# Busy poll - conservative (low-latency profile only)"
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
fs.file-max = $file_max

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
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_ecn = 2

# VM - minimal
vm.min_free_kbytes = $min_free_kbytes
vm.swappiness = 30
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 20
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# Network security
$common_sec
kernel.panic = 10
kernel.panic_on_oops = 1

EOF
            ;;
    esac

    if [ ! -s "$SYS_OPTIMIZER_PATH" ]; then
        red_msg "Generated sysctl config is empty!"
        return 1
    fi

    # Self-check: no duplicate keys inside the generated file.
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

    # Remove competing definitions from sysctl.conf so exactly ONE definition
    # of each managed key exists on the system.
    local key
    for key in fs.file-max net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.core.default_qdisc net.core.netdev_max_backlog net.core.netdev_budget net.core.optmem_max net.core.somaxconn net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.core.busy_poll net.core.busy_read net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_probes net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_max_orphans net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_mem net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.ipv4.tcp_retries2 net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_ecn net.ipv4.tcp_syncookies net.ipv4.tcp_fastopen net.ipv4.ip_local_port_range net.ipv4.ip_local_reserved_ports net.ipv4.udp_mem vm.min_free_kbytes vm.swappiness vm.vfs_cache_pressure net.ipv4.conf.default.rp_filter net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_source_route net.ipv4.conf.default.accept_source_route net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3 net.ipv4.neigh.default.gc_stale_time kernel.panic kernel.panic_on_oops vm.dirty_ratio vm.dirty_background_ratio vm.overcommit_memory vm.overcommit_ratio net.netfilter.nf_conntrack_max; do
        if grep -q "^${key}[[:space:]]*=" "$SYS_PATH" 2>/dev/null; then
            if grep -q "^${key}[[:space:]]*=" "$SYS_OPTIMIZER_PATH" 2>/dev/null; then
                sed -i "/^${key//./\\.}[[:space:]]*=/d" "$SYS_PATH"
            fi
        fi
    done

    chmod 644 "$SYS_OPTIMIZER_PATH"

    echo
    yellow_msg "Applying sysctl settings (profile: $selected_profile)..."
    local apply_log apply_rc=0
    apply_log=$(new_tmp) || return 1
    if sysctl --system 2>&1 | tee "$apply_log"; then
        apply_rc=0
    else
        apply_rc=$?
    fi
    # PIPESTATUS refinement: with `set -o pipefail` the pipeline status above
    # is sysctl's own status (tee rarely fails); treat non-zero as fatal.
    if [ "$apply_rc" -ne 0 ]; then
        red_msg "sysctl --system exited with status $apply_rc; checking details..."
        grep -i "error\|invalid\|cannot stat\|unknown key\|permission denied\|read-only" "$apply_log" | head -n 20 || true
    elif grep -q -i "error\|invalid\|cannot stat\|unknown key\|permission denied\|read-only" "$apply_log"; then
        yellow_msg "Some sysctl keys reported warnings:"
        grep -i "error\|invalid\|cannot stat\|unknown key\|permission denied\|read-only" "$apply_log" | head -n 20
    else
        green_msg "sysctl --system applied successfully"
        echo
        green_msg "Network is Optimized (profile: $selected_profile). Config: $SYS_OPTIMIZER_PATH"
        echo
        return 0
    fi

    # Self-heal pass 1: comment out keys the kernel does not HAVE
    # (missing /proc entries). Read-only/permission errors are NOT healed —
    # those keys are valid, the container just cannot write them.
    local missing_keys
    missing_keys=$(grep -i "cannot stat\|unknown key\|No such file" "$apply_log" 2>/dev/null \
        | grep -oE "/proc/sys/[A-Za-z0-9_/]+" | sed 's|^/proc/sys/||; s|/|.|g' | sort -u)
    local healed=0
    if [ -n "$missing_keys" ]; then
        yellow_msg "Healing unsupported keys (commenting out, one pass): $missing_keys"
        backup_file "$SYS_OPTIMIZER_PATH"
        local mk
        for mk in $missing_keys; do
            sed -i "s|^${mk//./\\.}[[:space:]]*=|# UNSUPPORTED ON THIS KERNEL: &|" "$SYS_OPTIMIZER_PATH"
        done
        healed=1
    fi

    # Re-apply after healing (or first apply failed without healable keys) and
    # judge the result ONLY by errors that reference keys THIS script manages
    # or by a non-zero exit status. Unrelated sysctl.d noise must not fail us;
    # managed-key failures must not pass us.
    local apply_log2 apply_rc2=0
    apply_log2=$(new_tmp) || return 1
    if sysctl --system 2>&1 | tee "$apply_log2"; then
        apply_rc2=0
    else
        apply_rc2=$?
    fi
    if [ "$apply_rc2" -ne 0 ]; then
        red_msg "sysctl --system failed with status $apply_rc2 after healing; network tuning NOT applied."
        grep -i "error\|invalid\|cannot stat\|unknown key\|permission denied\|read-only" "$apply_log2" | head -n 20 || true
        echo
        red_msg "Network optimization FAILED (profile: $selected_profile). Config kept at: $SYS_OPTIMIZER_PATH"
        echo
        return 1
    fi
    # Collect managed-key failures from the final apply log.
    local managed_fail=""
    managed_fail=$(managed_sysctl_failures "$apply_log2" "$SYS_OPTIMIZER_PATH")
    if [ -n "$managed_fail" ]; then
        # Permission/read-only failures inside a container are the one
        # intentional exception: the file is written for the host/next boot,
        # but the live kernel cannot be tuned from inside. Report honestly.
        if is_container && only_readonly_failures "$apply_log2"; then
            yellow_msg "Container detected: managed keys cannot be applied from inside (host controls them)."
            echo "$managed_fail" | head -n 20
            echo
            yellow_msg "Network config WRITTEN but NOT APPLIED in container (profile: $selected_profile). Config: $SYS_OPTIMIZER_PATH"
            echo
            return 1
        fi
        red_msg "Managed sysctl keys failed to apply:"
        echo "$managed_fail" | head -n 20
        echo
        red_msg "Network optimization FAILED (profile: $selected_profile). Config kept at: $SYS_OPTIMIZER_PATH"
        echo
        return 1
    fi
    if [ "$healed" = "1" ]; then
        green_msg "sysctl applied after healing unsupported keys"
    else
        green_msg "sysctl --system applied successfully"
    fi
    if only_readonly_failures "$apply_log2" && grep -q -i "permission denied\|read-only" "$apply_log2"; then
        yellow_msg "Note: unrelated read-only warnings present (typical inside containers); all MANAGED keys applied."
    fi

    echo
    green_msg "Network is Optimized (profile: $selected_profile). Config: $SYS_OPTIMIZER_PATH"
    echo
    return 0
}

# managed_sysctl_failures <apply-log> <managed-conf>: print managed keys from
# the conf that the apply log reports as failed (unknown key / cannot stat /
# invalid / error referencing the key's /proc path or the key name).
managed_sysctl_failures() {
    local log="$1" conf="$2" key path
    [ -f "$log" ] && [ -f "$conf" ] || return 0
    grep -v "^#" "$conf" 2>/dev/null | grep -v "^$" | cut -d= -f1 \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u | while IFS= read -r key; do
        [ -n "$key" ] || continue
        path="/proc/sys/$(printf '%s' "$key" | sed 's|\.|/|g')"
        if grep -qiF "$path" "$log" 2>/dev/null || grep -qi "unknown key.*${key}\|${key}.*unknown key\|invalid.*${key}\|${key}.*invalid\|error.*${key}\|${key}.*error" "$log" 2>/dev/null; then
            printf '%s\n' "$key"
        fi
    done
    return 0
}

# only_readonly_failures <apply-log>: true when every failure line is a
# permission/read-only failure (no unknown-key/invalid/cannot-stat lines).
only_readonly_failures() {
    local log="$1"
    [ -f "$log" ] || return 1
    if grep -qi "cannot stat\|unknown key\|No such file\|invalid argument\|invalid value" "$log" 2>/dev/null; then
        return 1
    fi
    grep -qi "permission denied\|read-only" "$log" 2>/dev/null
}

# Drop-in support: manage sshd_config.d/00-optimizer.conf when the main config
# actually includes that directory (first-match-wins => lexically early name
# wins over stock 50/60-cloudimg drop-ins). Otherwise fall back to editing the
# main file's global section above any Match block (older systems).
sshd_supports_dropin() {
    grep -Eq '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/\*\.conf' "$SSH_PATH" 2>/dev/null || return 1
    return 0
}

# Ensure the drop-in directory exists when Include references it (minimal
# images may ship the Include line without the directory).
sshd_ensure_dropin_dir() {
    [ -d /etc/ssh/sshd_config.d ] && return 0
    mkdir -p -m 0755 /etc/ssh/sshd_config.d 2>/dev/null || return 1
    [ -d /etc/ssh/sshd_config.d ] || return 1
    return 0
}

# First line number (1-based) of the first ACTIVE (non-comment, non-blank)
# Match directive, or empty when there is none.
sshd_match_start() {
    grep -nE '^[[:space:]]*Match([[:space:]]|$)' "$1" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Remove old SSH config (strip keys WE manage from the GLOBAL section only;
# preserve everything else, including all Match blocks byte-for-byte).
# In drop-in mode the main file must NOT be touched at all: ssh_prep() sets
# SSH_SKIP_MAIN_STRIP=1 BEFORE this runs, so this becomes a no-op.
remove_old_ssh_conf() {
    if [ ! -f "$SSH_PATH" ]; then
        red_msg "SSH config not found, skipping backup"
        return 0
    fi
    if [ "${SSH_SKIP_MAIN_STRIP:-0}" = "1" ]; then
        yellow_msg "Drop-in mode: leaving $SSH_PATH untouched (managed via $SSH_DROPIN_PATH)."
        return 0
    fi
    backup_file "$SSH_PATH"
    SSH_MAIN_SNAP="$BACKUP_LAST"
    echo
    yellow_msg "SSH config backup created (rotated, last $BACKUP_KEEP kept)"
    echo

    # Operate on the global section only: split at the first active Match,
    # transform the head, then rejoin with the untouched tail.
    local _match_at="" _head="" _tail=""
    _match_at=$(sshd_match_start "$SSH_PATH")
    _head=$(mktemp) || return 1
    OPT_TMPFILES+=("$_head")
    if [ -n "$_match_at" ]; then
        _tail=$(mktemp) || return 1
        OPT_TMPFILES+=("$_tail")
        head -n $((_match_at - 1)) "$SSH_PATH" > "$_head"
        tail -n +"$_match_at" "$SSH_PATH" > "$_tail"
    else
        cat "$SSH_PATH" > "$_head"
    fi
    # Character classes (not \s) for portability, and optional whitespace
    # after '#' so '#Key', '# Key' and '   # Key' are all handled.
    # NOTE: UseDNS/Compression normalize first match; the rest are deleted
    # (legacy Ciphers line migration + managed keys re-added by set_sshd_opt).
    sed -i -e 's/^[[:space:]]*#\?[[:space:]]*UseDNS.*/UseDNS no/' \
        -e 's/^[[:space:]]*#\?[[:space:]]*Compression.*/Compression no/' \
        -e '/^[[:space:]]*#\?[[:space:]]*Ciphers.*/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*MaxAuthTries/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*MaxSessions/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*LoginGraceTime/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*TCPKeepAlive/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*ClientAliveInterval/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*ClientAliveCountMax/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*AllowAgentForwarding/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*AllowTcpForwarding/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*GatewayPorts/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*PermitTunnel/d' \
        -e '/^[[:space:]]*#\?[[:space:]]*X11Forwarding/d' "$_head"
    if [ -n "$_match_at" ]; then
        cat "$_head" "$_tail" > "$SSH_PATH"
    else
        cat "$_head" > "$SSH_PATH"
    fi
    # NOTE: the old script appended a hardcoded "Ciphers ..." line; the delete
    # above removes it (migration to distro defaults). Nothing re-adds it.
}

# ssh_prep: decide drop-in vs legacy BEFORE any main-file mutation, so
# remove_old_ssh_conf can skip the main file entirely in drop-in mode.
# Sets SSH_USE_DROPIN and SSH_SKIP_MAIN_STRIP. Never touches file content.
ssh_prep() {
    SSH_USE_DROPIN=0
    SSH_SKIP_MAIN_STRIP=0
    [ -f "$SSH_PATH" ] || return 0
    if sshd_supports_dropin; then
        if sshd_ensure_dropin_dir; then
            SSH_USE_DROPIN=1
            SSH_SKIP_MAIN_STRIP=1
        fi
    fi
    return 0
}

# Update SSH config (idempotent; reload, never restart; rollback on failure)
update_sshd_conf() {
    echo
    yellow_msg 'Optimizing SSH...'
    echo

    [ -f "$SSH_PATH" ] || { red_msg "SSH config missing, aborting SSH step"; return 1; }
    if ! command -v sshd >/dev/null 2>&1; then
        yellow_msg "sshd binary not found (openssh-server not installed). Skipping SSH step."
        return 0
    fi

    # ONE exact pre-run snapshot of the main config for this execution.
    # Rollback restores THIS path — never "newest file" heuristics.
    # NOTE: in legacy mode remove_old_ssh_conf already snapshotted the TRUE
    # pre-run state into SSH_MAIN_SNAP; never overwrite it here (a second
    # snapshot would capture the post-strip file and rollback would lose the
    # original managed-key values).
    SSH_DROPIN_SNAP=""
    SSH_DROPIN_LEGACY_SNAP=""
    if [ -z "${SSH_MAIN_SNAP:-}" ] && [ -f "$SSH_PATH" ]; then
        backup_file "$SSH_PATH" >/dev/null 2>&1 || true
        SSH_MAIN_SNAP="$BACKUP_LAST"
    fi

    # Prefer a managed drop-in when the main config uses Include (Ubuntu
    # 22.04+/Debian 12 default). OpenSSH applies the FIRST obtained value, so
    # keys appended to the tail of the main file would silently lose to any
    # drop-in that sets the same key. Lexically-early 00- name wins over
    # stock 50/60-cloudimg drop-ins.
    # NOTE: ssh_prep() already ran (via the ssh-clean step) and set
    # SSH_USE_DROPIN/SSH_SKIP_MAIN_STRIP. Re-derive defensively in case this
    # function is invoked without the prep step.
    if [ "${SSH_SKIP_MAIN_STRIP:-0}" != "1" ]; then
        ssh_prep
    fi
    if [ "$SSH_USE_DROPIN" = "1" ]; then
        yellow_msg "sshd uses Include; managing $SSH_DROPIN_PATH instead of touching $SSH_PATH."
        if [ -f "$SSH_DROPIN_LEGACY" ] && [ "$SSH_DROPIN_LEGACY" != "$SSH_DROPIN_PATH" ]; then
            yellow_msg "Removing legacy optimizer drop-in $SSH_DROPIN_LEGACY (superseded by $SSH_DROPIN_PATH)."
            backup_file "$SSH_DROPIN_LEGACY" >/dev/null 2>&1 || true
            SSH_DROPIN_LEGACY_SNAP="$BACKUP_LAST"
            rm -f "$SSH_DROPIN_LEGACY"
        fi
        if [ -f "$SSH_DROPIN_PATH" ]; then
            backup_file "$SSH_DROPIN_PATH" >/dev/null 2>&1 || true
            SSH_DROPIN_SNAP="$BACKUP_LAST"
        fi
    fi

    # Rationale:
    #  Compression no            - saves CPU/jitter; oracle-attack history
    #  AllowAgentForwarding no   - a compromised server must not pivot via
    #                              YOUR agent socket (forwarding = lateral risk)
    #  AllowTcpForwarding yes    - REQUIRED for -L/-R/-D tunneling workflows
    #  GatewayPorts no           - remote forwards bind loopback only
    #  PermitTunnel no           - L3 ssh -w tunnels off (you use VPN apps);
    #                              set to yes only if you use 'ssh -w'
    #  MaxAuthTries/MaxSessions/LoginGraceTime - brute-force/DoS surface
    if [ "$SSH_USE_DROPIN" = "1" ]; then
        # Deterministic full-file write: re-running produces the same file.
        local _ssh_tmp
        _ssh_tmp=$(mktemp "$(dirname "$SSH_DROPIN_PATH")/.00-optimizer.XXXXXX") || {
            red_msg "Failed to stage the sshd drop-in."
            return 1
        }
        OPT_TMPFILES+=("$_ssh_tmp")
        {
            echo "# Managed by Linux-Optimize (v$SCRIPT_VERSION) - do not edit."
            echo "# Drop-in overrides $SSH_PATH (first obtained value wins)."
            echo "UseDNS no"
            echo "Compression no"
            echo "TCPKeepAlive yes"
            echo "ClientAliveInterval 300"
            echo "ClientAliveCountMax 3"
            echo "MaxAuthTries 3"
            echo "MaxSessions 10"
            echo "LoginGraceTime 60"
            echo "AllowTcpForwarding yes"
            echo "GatewayPorts no"
            echo "PermitTunnel no"
            echo "X11Forwarding no"
            echo "AllowAgentForwarding no"
        } > "$_ssh_tmp"
        chmod 600 "$_ssh_tmp"
        if ! mv -f "$_ssh_tmp" "$SSH_DROPIN_PATH"; then
            rm -f "$_ssh_tmp"
            red_msg "Failed to install $SSH_DROPIN_PATH."
            return 1
        fi
    else
        # Legacy mode: global keys ONLY above the first active Match block.
        # set_sshd_opt matches/replaces within the global section; new keys
        # are inserted before the Match line, never appended after it.
        set_sshd_opt() {
            local key="$1" val="$2" _at="" _g="" _t=""
            _at=$(sshd_match_start "$SSH_PATH")
            if [ -z "$_at" ]; then
                if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$SSH_PATH"; then
                    sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$SSH_PATH"
                else
                    echo "${key} ${val}" >> "$SSH_PATH"
                fi
                return 0
            fi
            _g=$(mktemp) || return 1
            _t=$(mktemp) || { rm -f "$_g"; return 1; }
            OPT_TMPFILES+=("$_g" "$_t")
            head -n $((_at - 1)) "$SSH_PATH" > "$_g"
            tail -n +"$_at" "$SSH_PATH" > "$_t"
            if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$_g"; then
                sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$_g"
            else
                printf '%s %s\n' "$key" "$val" >> "$_g"
            fi
            cat "$_g" "$_t" > "$SSH_PATH"
            return 0
        }

        set_sshd_opt "UseDNS" "no"
        set_sshd_opt "Compression" "no"
        set_sshd_opt "TCPKeepAlive" "yes"
        set_sshd_opt "ClientAliveInterval" "300"
        set_sshd_opt "ClientAliveCountMax" "3"
        set_sshd_opt "MaxAuthTries" "3"
        set_sshd_opt "MaxSessions" "10"
        set_sshd_opt "LoginGraceTime" "60"
        set_sshd_opt "AllowTcpForwarding" "yes"
        set_sshd_opt "GatewayPorts" "no"
        set_sshd_opt "PermitTunnel" "no"
        set_sshd_opt "X11Forwarding" "no"
        set_sshd_opt "AllowAgentForwarding" "no"
    fi

    # --- Runtime prerequisites (pristine/minimal cloud images) ---
    # 1. Privilege-separation directory: absent before the daemon ever
    #    starts. Without it sshd -t fails for ENVIRONMENT reasons (not a
    #    config error) and would trigger a bogus rollback. Create it first.
    mkdir -p -m 0755 /run/sshd 2>/dev/null || true
    # 2. Host keys: absent when openssh-server was installed but never
    #    started/configured. sshd -t fails without them.
    if ! ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
        yellow_msg "No SSH host keys found, generating (ssh-keygen -A)..."
        ssh-keygen -A 2>/dev/null || yellow_msg "Host-key generation unavailable, continuing anyway."
    fi

    # Capture output: a bare 2>/dev/null hides WHY the test failed.
    local sshd_out=""
    if sshd_out=$(sshd -t 2>&1); then
        # Effective-value check: confirm the daemon actually sees our managed
        # values (catches Include-ordering surprises). A mismatch is a FAILURE:
        # silently reporting success while another drop-in overrides our
        # hardening would be dishonest. If sshd -T is unavailable the check is
        # skipped; sshd -t already passed.
        local _eff_out="" _eff_ok=1 _eff_key _eff_want _eff_got _eff_rest
        if _eff_out=$(sshd -T 2>/dev/null); then
            for _eff_key in usedns compression tcpkeepalive clientaliveinterval clientalivecountmax maxauthtries maxsessions logingracetime allowtcpforwarding gatewayports permittunnel x11forwarding allowagentforwarding; do
                case "$_eff_key" in
                    usedns) _eff_want="no" ;;
                    compression) _eff_want="no" ;;
                    tcpkeepalive) _eff_want="yes" ;;
                    clientaliveinterval) _eff_want="300" ;;
                    clientalivecountmax) _eff_want="3" ;;
                    maxauthtries) _eff_want="3" ;;
                    maxsessions) _eff_want="10" ;;
                    logingracetime) _eff_want="60" ;;
                    allowtcpforwarding) _eff_want="yes" ;;
                    gatewayports) _eff_want="no" ;;
                    permittunnel) _eff_want="no" ;;
                    x11forwarding) _eff_want="no" ;;
                    allowagentforwarding) _eff_want="no" ;;
                esac
                _eff_got=$(printf '%s\n' "$_eff_out" | awk -v k="$_eff_key" 'tolower($1)==k {$1=""; sub(/^ +/,""); print tolower($0); exit}')
                if [ -z "$_eff_got" ]; then
                    yellow_msg "sshd -T does not report '$_eff_key' on this OpenSSH version; skipping that check."
                    continue
                fi
                if [ "$_eff_got" != "$_eff_want" ]; then
                    red_msg "sshd effective value mismatch: $_eff_key is '$_eff_got', expected '$_eff_want' (another drop-in overrides ours)."
                    _eff_ok=0
                fi
            done
            if [ "$_eff_ok" = "1" ]; then
                green_msg "sshd effective values verified (sshd -T matches managed settings)."
            else
                red_msg "SSH hardening NOT effective (overridden by earlier config). Rolling back to the exact pre-run state."
                ssh_rollback
                return 1
            fi
        else
            yellow_msg "sshd -T unavailable for effective-value check (sshd -t passed; continuing)."
        fi
        # reload keeps existing sessions alive; restart would drop yours.
        if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
            green_msg 'SSH is Optimized (reloaded, sessions preserved).'
        else
            yellow_msg 'sshd -t passed but reload unsupported/failed; config saved, will apply on next restart. NOT restarting automatically to protect your session.'
            yellow_msg 'Apply manually when ready: systemctl restart ssh'
        fi
    else
        red_msg 'sshd -t failed:'
        printf '%s\n' "$sshd_out" >&2
        red_msg 'Restoring exact pre-run state (NOT reloading).'
        ssh_rollback
        return 1
    fi
    echo
}

# ssh_rollback: restore the EXACT pre-run sshd state captured in SSH_MAIN_SNAP
# / SSH_DROPIN_SNAP. No "newest file" guessing. Verifies with sshd -t but
# never reloads on failure.
ssh_rollback() {
    if [ "$SSH_USE_DROPIN" = "1" ]; then
        if [ -n "${SSH_DROPIN_SNAP:-}" ] && [ -f "$SSH_DROPIN_SNAP" ]; then
            cp -p "$SSH_DROPIN_SNAP" "$SSH_DROPIN_PATH"
            yellow_msg "Restored drop-in from pre-run snapshot."
        else
            rm -f "$SSH_DROPIN_PATH"
            yellow_msg "Removed new drop-in: $SSH_DROPIN_PATH (no pre-existing drop-in this run)."
        fi
        # A legacy 99- file removed earlier in this run is restored too, so a
        # failed run leaves the on-disk drop-in set exactly as it found it.
        if [ -n "${SSH_DROPIN_LEGACY_SNAP:-}" ] && [ -f "$SSH_DROPIN_LEGACY_SNAP" ] && [ ! -f "$SSH_DROPIN_LEGACY" ]; then
            cp -p "$SSH_DROPIN_LEGACY_SNAP" "$SSH_DROPIN_LEGACY"
            yellow_msg "Restored legacy drop-in from pre-run snapshot: $SSH_DROPIN_LEGACY"
        fi
    fi
    if [ -n "${SSH_MAIN_SNAP:-}" ] && [ -f "$SSH_MAIN_SNAP" ]; then
        cp -p "$SSH_MAIN_SNAP" "$SSH_PATH"
        yellow_msg "Restored $SSH_PATH from pre-run snapshot."
    else
        red_msg "No pre-run snapshot available for $SSH_PATH; leaving current file untouched."
    fi
    if sshd -t >/dev/null 2>&1; then
        green_msg "Rollback verified: restored SSH config passes sshd -t."
    else
        red_msg "WARNING: restored SSH config still fails sshd -t (pre-existing breakage?). NOT reloading; fix manually before restarting sshd."
    fi
    return 0
}

# System Limits Optimizations (finite values — unlimited nproc/memlock/core
# lets one user fork-bomb, mlock the RAM, or fill the disk with core dumps)
limits_optimizations() {
    echo
    yellow_msg 'Optimizing System Limits...'
    echo

    # One-time migration: remove ulimit lines the OLD script version may have
    # left in /etc/profile. We do not add new ones (limits.d is the source).
    local optimizer_ulimits=(
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
    local found_optimizer_entry=false
    local entry
    for entry in "${optimizer_ulimits[@]}"; do
        if grep -qF "$entry" "$PROF_PATH" 2>/dev/null; then
            found_optimizer_entry=true
            break
        fi
    done
    if [ "$found_optimizer_entry" = true ]; then
        yellow_msg "Cleaning old optimizer ulimit entries from $PROF_PATH (preserving custom user entries)"
        backup_file "$PROF_PATH"
        local tmp_prof line trimmed skip
        tmp_prof=$(mktemp "$(dirname "$PROF_PATH")/.profile.linux-optimizer.XXXXXX") || {
            red_msg "Failed to stage a temporary file for $PROF_PATH; leaving it untouched."
            return 1
        }
        OPT_TMPFILES+=("$tmp_prof")
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
        # Atomic replacement: the staged file lives in the same directory
        # (same filesystem), inherits the original permissions/ownership, and
        # is moved into place. A crash can never leave $PROF_PATH truncated.
        chmod --reference="$PROF_PATH" "$tmp_prof" 2>/dev/null || chmod 644 "$tmp_prof"
        chown --reference="$PROF_PATH" "$tmp_prof" 2>/dev/null || true
        if mv -f "$tmp_prof" "$PROF_PATH"; then
            local _kept=() _t
            for _t in "${OPT_TMPFILES[@]}"; do
                [ "$_t" != "$tmp_prof" ] || continue
                _kept+=("$_t")
            done
            OPT_TMPFILES=("${_kept[@]}")
        else
            red_msg "Failed to replace $PROF_PATH atomically; original left untouched."
            return 1
        fi
    else
        yellow_msg "No legacy optimizer ulimit entries in $PROF_PATH, leaving custom entries untouched"
    fi

    cat > "$LIMITS_CONF" <<'EOF'
# /etc/security/limits.d/99-optimizer.conf - managed by Linux-Optimize.
# Finite values on purpose: 'unlimited' nproc/memlock/core = fork-bomb /
# RAM-lock / disk-fill DoS by any single user. Re-running the script
# reproduces this exact file.
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
*               soft    nproc           65536
*               hard    nproc           65536
*               soft    memlock         1048576
*               hard    memlock         1048576
*               soft    core            0
*               hard    core            0
*               soft    stack           32768
*               hard    stack           65536
EOF
    chmod 644 "$LIMITS_CONF"

    local conf
    for conf in /etc/systemd/system.conf /etc/systemd/user.conf; do
        if [ -f "$conf" ]; then
            if ! grep -q "^DefaultLimitNOFILE=1048576" "$conf" \
                || grep -q "^DefaultLimitNPROC=infinity" "$conf" \
                || grep -q "^DefaultLimitMEMLOCK=infinity" "$conf"; then
                backup_file "$conf"
                sed -i '/^DefaultLimitNOFILE/d; /^DefaultLimitNPROC/d; /^DefaultLimitMEMLOCK/d' "$conf"
                {
                    echo "DefaultLimitNOFILE=1048576"
                    echo "DefaultLimitNPROC=65536"
                    echo "DefaultLimitMEMLOCK=1073741824"
                } >> "$conf"
                yellow_msg "Updated $conf (finite limits; needs daemon-reexec + reboot for PID 1)"
            fi
        fi
    done

    local pam
    for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [ -f "$pam" ] && ! grep -q "pam_limits.so" "$pam"; then
            backup_file "$pam"
            echo "session required pam_limits.so" >> "$pam"
        fi
    done

    ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    echo
    green_msg 'System Limits are Optimized. Config: /etc/security/limits.d/99-optimizer.conf (re-login required)'
    echo
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

# Apply Everything (resilient: every stage runs, failures are recorded and
# reported honestly by the caller via print_final_status)
apply_everything() {
    reset_failures
    run_step "update" complete_update
    run_step "terminal-ads" disable_terminal_ads
    run_step "packages" installations
    run_step "enable-packages" enable_packages
    run_step "swap" swap_maker
    run_step "network" sysctl_optimizations "${OPT_PROFILE:-}"
    ssh_prep; run_step "ssh-clean" remove_old_ssh_conf
    run_step "ssh" update_sshd_conf
    run_step "limits" limits_optimizations
}

# Main Execution Loop
main() {
    local choice=""
    while true; do
        show_menu
        if ! read -rp 'Enter Your Choice: ' choice; then
            echo
            exit 0
        fi
        case $choice in
        1)
            apply_everything
            print_final_status
            ask_reboot_guarded
            ;;
        2)
            reset_failures
            run_step "update" complete_update
            run_step "packages" installations
            run_step "enable-packages" enable_packages
            run_step "swap" swap_maker
            run_step "network" sysctl_optimizations
            ssh_prep; run_step "ssh-clean" remove_old_ssh_conf
            run_step "ssh" update_sshd_conf
            run_step "limits" limits_optimizations
            print_final_status
            ask_reboot_guarded
            ;;
        3)
            reset_failures
            run_step "update" complete_update
            run_step "swap" swap_maker
            run_step "network" sysctl_optimizations
            ssh_prep; run_step "ssh-clean" remove_old_ssh_conf
            run_step "ssh" update_sshd_conf
            run_step "limits" limits_optimizations
            print_final_status
            ask_reboot_guarded
            ;;
        4)
            reset_failures
            run_step "update" complete_update
            print_final_status
            ask_reboot_guarded
            ;;
        5)
            # FIX (was: complete_update + installations): the label says
            # "Install Useful Packages" so it installs packages ONLY.
            # A full OS upgrade behind option 5 was surprising and risky.
            reset_failures
            run_step "packages" installations
            run_step "enable-packages" enable_packages
            print_final_status
            ask_reboot_guarded
            ;;
        6)
            reset_failures
            run_step "swap" swap_maker
            print_final_status
            ask_reboot_guarded
            ;;
        7)
            reset_failures
            run_step "network" sysctl_optimizations
            ssh_prep; run_step "ssh-clean" remove_old_ssh_conf
            run_step "ssh" update_sshd_conf
            run_step "limits" limits_optimizations
            print_final_status
            ask_reboot_guarded
            ;;
        8)
            reset_failures
            run_step "network" sysctl_optimizations
            print_final_status
            notify_reboot_if_required
            ;;
        9)
            reset_failures
            ssh_prep; run_step "ssh-clean" remove_old_ssh_conf
            run_step "ssh" update_sshd_conf
            print_final_status
            notify_reboot_if_required
            ;;
        10)
            reset_failures
            run_step "limits" limits_optimizations
            print_final_status
            ask_reboot_guarded
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

# --- CLI ----------------------------------------------------------------------
OPT_PROFILE=""
DO_ALL=0
DO_UPDATE=0 DO_PACKAGES=0 DO_SWAP=0 DO_NETWORK=0 DO_SSH=0 DO_LIMITS=0

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) print_help; exit 0 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --all) DO_ALL=1; shift ;;
            --update) DO_UPDATE=1; shift ;;
            --packages) DO_PACKAGES=1; shift ;;
            --swap) DO_SWAP=1; shift ;;
            --network) DO_NETWORK=1; shift ;;
            --ssh) DO_SSH=1; shift ;;
            --limits) DO_LIMITS=1; shift ;;
            --profile)
                # Guard BEFORE shifting: a missing value must error out, never
                # leave $# unchanged (infinite loop) or eat the next option.
                if [ $# -lt 2 ] || ! require_arg_value "--profile" "${2:-}"; then
                    red_msg "Usage: --profile NAME (balanced | vpn-high-throughput | vpn-low-latency | conservative | auto)"
                    exit 1
                fi
                OPT_PROFILE="$2"; shift 2
                case "$OPT_PROFILE" in
                    balanced|vpn-high-throughput|vpn-low-latency|conservative|auto) ;;
                    *) red_msg "Invalid --profile: $OPT_PROFILE"; exit 1 ;;
                esac
                ;;
            --profile=*) OPT_PROFILE="${1#--profile=}"; shift
                case "$OPT_PROFILE" in
                    balanced|vpn-high-throughput|vpn-low-latency|conservative|auto) ;;
                    *) red_msg "Invalid --profile: $OPT_PROFILE"; exit 1 ;;
                esac
                ;;
            --swap-size)
                # Same guard as --profile: missing value exits, never loops.
                if [ $# -lt 2 ] || ! require_arg_value "--swap-size" "${2:-}"; then
                    red_msg "Usage: --swap-size SIZE (e.g. 2G, 4096M)"
                    exit 1
                fi
                SWAP_SIZE="$2"; shift 2
                validate_swap_size "$SWAP_SIZE" || exit 1
                ;;
            --swap-size=*)
                SWAP_SIZE="${1#--swap-size=}"; shift
                validate_swap_size "$SWAP_SIZE" || exit 1
                ;;
            balanced|vpn-high-throughput|vpn-low-latency|conservative|auto)
                OPT_PROFILE="$1"; shift ;;
            *)
                red_msg "Unknown argument: $1 (see --help)"; exit 1 ;;
        esac
    done
}

check_if_running_as_root
check_supported_os
parse_args "$@"

# Concurrency protection: never let two instances interleave system edits.
acquire_lock || exit 1

if [ "$DO_ALL" = "1" ]; then
    apply_everything
    if print_final_status; then
        ask_reboot
        exit 0
    else
        ask_reboot_guarded
        exit 1
    fi
fi

if [ "$DO_UPDATE$DO_PACKAGES$DO_SWAP$DO_NETWORK$DO_SSH$DO_LIMITS" != "000000" ]; then
    reset_failures
    [ "$DO_UPDATE" = "1" ] && run_step "update" complete_update
    if [ "$DO_PACKAGES" = "1" ]; then run_step "packages" installations; run_step "enable-packages" enable_packages; fi
    [ "$DO_SWAP" = "1" ] && run_step "swap" swap_maker
    [ "$DO_NETWORK" = "1" ] && run_step "network" sysctl_optimizations "$OPT_PROFILE"
    if [ "$DO_SSH" = "1" ]; then ssh_prep; run_step "ssh-clean" remove_old_ssh_conf; run_step "ssh" update_sshd_conf; fi
    [ "$DO_LIMITS" = "1" ] && run_step "limits" limits_optimizations
    # Selective runs never prompt: surface a pending reboot without forcing one.
    if print_final_status; then
        notify_reboot_if_required
        exit 0
    else
        notify_reboot_if_required
        exit 1
    fi
fi

main
