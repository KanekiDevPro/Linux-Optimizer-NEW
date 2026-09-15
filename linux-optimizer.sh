#!/bin/bash
#
# Linux-Optimizer launcher (hardened edition, rev. 3).
#
# Non-interactive usage:
#   sudo bash linux-optimizer.sh --dns=2 --yes
#   sudo bash linux-optimizer.sh --dns=15 --dns-v4="1.1.1.1 8.8.8.8" --yes
#   sudo bash linux-optimizer.sh --timezone=Asia/Tehran --yes
#   sudo bash linux-optimizer.sh --no-optimizer   # only hosts+DNS+timezone
#
# Exit codes (bit flags, so they combine):
#   0  everything succeeded
#   1  DNS stage failed / was rolled back
#   2  timezone stage failed
#   4  distro optimizer failed
#
# Design rules enforced in this file:
#   * Every human-readable message goes to STDERR. STDOUT is reserved for
#     function return values, because several helpers are called inside $( ).
#   * Nothing is changed without a snapshot, a verification step and a
#     working rollback path. The host must never be left without a resolver.
#   * The script is idempotent: re-running it must not duplicate state or
#     restart services needlessly.

set -f              # no pathname expansion: IP lists are word-split on purpose
set -o pipefail

# ---------------------------------------------------------------------------
# Options (all of them overridable from the environment)
# ---------------------------------------------------------------------------
OPT_DNS_CHOICE="${OPT_DNS_CHOICE:-}"
OPT_DNS_V4="${OPT_DNS_V4:-}"
OPT_DNS_V6="${OPT_DNS_V6:-}"
OPT_ASSUME_YES="${OPT_ASSUME_YES:-0}"
OPT_TIMEZONE="${OPT_TIMEZONE:-}"
OPT_NO_OPTIMIZER="${OPT_NO_OPTIMIZER:-0}"
OPT_NO_BOOTSTRAP="${OPT_NO_BOOTSTRAP:-0}"
OPT_NETPLAN_APPLY="${OPT_NETPLAN_APPLY:-0}"
OPT_BACKUP_KEEP="${OPT_BACKUP_KEEP:-5}"

# Distro optimizer download.
# NOTE: OPT_OPTIMIZER_REF is a *moving branch* by default. A pinned checksum is
# only meaningful together with an immutable ref, so when you pin a checksum,
# also pin the ref to the matching commit SHA:
#   OPT_OPTIMIZER_REF=ab59c38... OPT_OPTIMIZER_SHA256_UBUNTU=<sha> bash linux-optimizer.sh
OPT_OPTIMIZER_REF="${OPT_OPTIMIZER_REF:-main}"
OPT_OPTIMIZER_URL="${OPT_OPTIMIZER_URL:-}"
OPT_OPTIMIZER_SHA256="${OPT_OPTIMIZER_SHA256:-}"
OPT_OPTIMIZER_SHA256_UBUNTU="${OPT_OPTIMIZER_SHA256_UBUNTU:-}"
OPT_OPTIMIZER_SHA256_DEBIAN="${OPT_OPTIMIZER_SHA256_DEBIAN:-}"
OPT_OPTIMIZER_SHA256_CENTOS="${OPT_OPTIMIZER_SHA256_CENTOS:-}"
OPT_OPTIMIZER_SHA256_FEDORA="${OPT_OPTIMIZER_SHA256_FEDORA:-}"
# Refuse to run any remote optimizer unless a checksum is pinned.
OPT_PIN_SHA256="${OPT_PIN_SHA256:-0}"
# Explicit opt-out that allows running an unverified remote script in
# non-interactive mode. Off by default: --yes alone is no longer enough.
OPT_ALLOW_UNVERIFIED="${OPT_ALLOW_UNVERIFIED:-0}"

EXIT_CODE=0

print_usage() {
    cat <<'USAGE'
Usage: sudo bash linux-optimizer.sh [options]
  --dns=N               DNS preset 1-15 (same as the menu), non-interactive
  --dns-v4="A B"        IPv4 servers (required with --dns=15 --yes)
  --dns-v6="A B"        IPv6 servers (optional, with --dns=15)
  --timezone=TZ         Timezone (e.g. Asia/Tehran), skips auto-detect
  --yes, -y             Assume yes, never prompt
  --no-optimizer        Skip the distro optimizer download/run
  --no-bootstrap        Do not install a temporary resolver when DNS is broken
  --netplan-apply       Run `netplan apply` after writing the netplan override
                        (may briefly disrupt networking; off by default)
  --optimizer-ref=REF   Branch/tag/commit of the optimizer repo (default: main)
  --pin-checksum        Refuse to run the optimizer unless a checksum is pinned
  --allow-unverified    With --yes: allow running an unpinned remote script
  --backup-keep=N       Keep N timestamped backups per file (default: 5)
  -h, --help            Show this help

Environment equivalents: OPT_DNS_CHOICE, OPT_DNS_V4, OPT_DNS_V6, OPT_TIMEZONE,
  OPT_ASSUME_YES, OPT_NO_OPTIMIZER, OPT_NO_BOOTSTRAP, OPT_NETPLAN_APPLY,
  OPT_BACKUP_KEEP, OPT_OPTIMIZER_REF, OPT_OPTIMIZER_URL, OPT_OPTIMIZER_SHA256,
  OPT_OPTIMIZER_SHA256_{UBUNTU,DEBIAN,CENTOS,FEDORA}, OPT_PIN_SHA256,
  OPT_ALLOW_UNVERIFIED, NO_COLOR

Exit code is a bit mask: 1 = DNS failed, 2 = timezone failed, 4 = optimizer failed.
USAGE
}

for _arg in "$@"; do
    case "$_arg" in
        --dns=*)            OPT_DNS_CHOICE="${_arg#--dns=}" ;;
        --dns-v4=*)         OPT_DNS_V4="${_arg#--dns-v4=}" ;;
        --dns-v6=*)         OPT_DNS_V6="${_arg#--dns-v6=}" ;;
        --timezone=*)       OPT_TIMEZONE="${_arg#--timezone=}" ;;
        --yes|-y)           OPT_ASSUME_YES=1 ;;
        --no-optimizer)     OPT_NO_OPTIMIZER=1 ;;
        --no-bootstrap)     OPT_NO_BOOTSTRAP=1 ;;
        --netplan-apply)    OPT_NETPLAN_APPLY=1 ;;
        --optimizer-ref=*)  OPT_OPTIMIZER_REF="${_arg#--optimizer-ref=}" ;;
        --pin-checksum)     OPT_PIN_SHA256=1 ;;
        --allow-unverified) OPT_ALLOW_UNVERIFIED=1 ;;
        --backup-keep=*)    OPT_BACKUP_KEEP="${_arg#--backup-keep=}" ;;
        -h|--help)          print_usage; exit 0 ;;
        *)  printf '[*] ----- Unknown option: %s (see --help)\n' "$_arg" >&2; exit 64 ;;
    esac
done

case "$OPT_BACKUP_KEEP" in
    ''|*[!0-9]*) OPT_BACKUP_KEEP=5 ;;
esac
[ "$OPT_BACKUP_KEEP" -lt 1 ] 2>/dev/null && OPT_BACKUP_KEEP=1

# ---------------------------------------------------------------------------
# Output helpers - everything goes to stderr so that $( ) captures stay clean.
# ---------------------------------------------------------------------------
_COLOR_OK=0
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1; then
    _COLOR_OK=1
fi

_color_msg() {
    local color="$1" text="$2"
    if [ "$_COLOR_OK" = "1" ]; then
        { tput setaf "$color" 2>/dev/null
          printf '[*] ----- %s\n' "$text"
          tput sgr0 2>/dev/null
        } >&2
    else
        printf '[*] ----- %s\n' "$text" >&2
    fi
}

green_msg()  { _color_msg 2 "$1"; }
yellow_msg() { _color_msg 3 "$1"; }
red_msg()    { _color_msg 1 "$1"; }
plain_msg()  { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Single-instance lock. The directory is picked before the redirection so that
# `exec` can never fail (and never print an unsuppressable error).
# ---------------------------------------------------------------------------
_pick_lock_path() {
    local d
    for d in /run/lock /var/lock /tmp; do
        if [ -d "$d" ] && [ -w "$d" ]; then
            printf '%s/linux-optimizer.lock' "$d"
            return 0
        fi
    done
    printf '/tmp/linux-optimizer.lock'
}

LOCK_FILE=$(_pick_lock_path)
if command -v flock >/dev/null 2>&1; then
    exec 9>>"$LOCK_FILE"
    if ! flock -n 9; then
        red_msg "Another instance is running (lock: $LOCK_FILE). Exiting."
        exit 75
    fi
fi

# ---------------------------------------------------------------------------
# Paths / global state
# ---------------------------------------------------------------------------
HOST_PATH="/etc/hosts"
TS=$(date +%Y%m%d-%H%M%S)
PROBE_NAMES="example.com cloudflare.com wikipedia.org"
MAXNS=3

DNS_CHOICE=""
DNS_LIST=""
DNS_NAME=""
DNS_V4=""
DNS_V6=""
DOT_PAIRS=""
DOT_MODE="disabled"
DNS_IS_IR=0
METHOD="direct"
DNS_IN_FLIGHT=0
DEPS_OK=1
OS="unknown"
OS_VERSION_ID=""

RESOLV_SNAPSHOT_DONE=0
RESOLV_WAS_SYMLINK=0
RESOLV_SYMLINK_TARGET=""
RESOLV_BAK_FILE="/etc/resolv.conf.bak.$TS"
RESOLV_MODIFIED=0
RESOLV_WAS_IMMUTABLE=0

RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-linux-optimizer-dns.conf"
RESOLVED_DROPIN_WRITTEN=0
RESOLVED_DROPIN_EXISTED=0
RESOLVED_DROPIN_BAK=""
RESOLVED_LINKS_TOUCHED=()

NM_CHANGES=()
NM_APPLIED=0
NM_DNSNONE_DROPIN="/etc/NetworkManager/conf.d/99-linux-optimizer-dnsnone.conf"
NM_DNSNONE_CREATED=0

DNS_STATE_DIR="/var/lib/linux-optimizer"
DNS_STATE_FILE="$DNS_STATE_DIR/dns.env"
NETWORKD_DISPATCHER_HOOK="/etc/networkd-dispatcher/routable.d/70-linux-optimizer-dns"
DNS_STATE_WRITTEN=0
DNS_HOOK_CREATED=0

NETPLAN_DNS_FILE="/etc/netplan/99-linux-optimizer-dns.yaml"
NETPLAN_BAK_FILE=""
NETPLAN_FILE_CREATED=0

# Temporary bootstrap resolver state (used before dependencies are installed)
BS_APPLIED=0
BS_BAK=""
BS_WAS_SYMLINK=0
BS_SYMLINK_TARGET=""
BS_LIST=""
ORIG_DNS_BROKEN=0

TMP_WORKDIR=""

# ---------------------------------------------------------------------------
# Traps: an interrupt must never leave the box half-configured.
# ---------------------------------------------------------------------------
cleanup_tmp() {
    [ -n "$TMP_WORKDIR" ] && [ -d "$TMP_WORKDIR" ] && rm -rf "$TMP_WORKDIR"
    return 0
}

on_signal() {
    trap '' INT TERM
    plain_msg ""
    red_msg "Interrupted - restoring the previous state before exiting."
    if [ "$DNS_IN_FLIGHT" = "1" ]; then
        rollback_dns
    elif [ "$BS_APPLIED" = "1" ]; then
        bootstrap_dns_revert
    fi
    cleanup_tmp
    exit 130
}

trap on_signal INT TERM
trap cleanup_tmp EXIT

# ---------------------------------------------------------------------------
# Input helper: /dev/tty first (works under `curl | sudo bash`), stdin second.
# The prompt goes to stderr, otherwise it would be swallowed by $( ).
# ---------------------------------------------------------------------------
read_input() {
    local _var="$1" _prompt="$2" _line
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf '%s' "$_prompt" >/dev/tty
        IFS= read -r _line </dev/tty || return 1
    else
        printf '%s' "$_prompt" >&2
        IFS= read -r _line || return 1
    fi
    printf -v "$_var" '%s' "$_line"
    return 0
}

confirm() {
    local prompt="$1" ans=""
    [ "$OPT_ASSUME_YES" = "1" ] && return 0
    read_input ans "$prompt" || return 1
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Intro / root check
# ---------------------------------------------------------------------------
plain_msg ""
green_msg '================================================================='
green_msg 'This script will automatically optimize your Linux server.'
green_msg 'Tested on: Ubuntu 20+, Debian 11+, CentOS 8+, AlmaLinux, Rocky, Fedora'
green_msg 'Root access is required.'
green_msg '================================================================='
plain_msg ""

check_if_running_as_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        red_msg 'Error: You must run this script as root!'
        exit 77
    fi
}

check_if_running_as_root

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
prune_backups() {
    # prune_backups <dir> <glob-for-find> - keeps the newest $OPT_BACKUP_KEEP
    local dir="$1" pattern="$2" f
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +$((OPT_BACKUP_KEEP + 1)) | cut -d' ' -f2- \
        | while IFS= read -r f; do
              [ -n "$f" ] && rm -f -- "$f"
          done
    return 0
}

path_is_safe() {
    # Root-owned and neither group- nor world-writable, for the file *and* its
    # directory. Prevents a planted ./optimizer.sh in /tmp from running as root.
    local p="$1" d
    [ -e "$p" ] || return 1
    d=$(dirname -- "$p")
    [ -n "$(find "$p" -maxdepth 0 -user root ! -perm /022 2>/dev/null)" ] || return 1
    [ -n "$(find "$d" -maxdepth 0 -user root ! -perm /022 2>/dev/null)" ] || return 1
    return 0
}

os_release_get() {
    local key="$1"
    [ -f /etc/os-release ] || return 1
    awk -F= -v k="$key" '
        $1 == k {
            sub(/^[^=]*=/, "", $0)
            gsub(/^["'"'"']|["'"'"']$/, "", $0)
            print
            exit
        }' /etc/os-release 2>/dev/null
}

dedup_list() {
    local seen=" " out="" tok
    for tok in $1; do
        [ -z "$tok" ] && continue
        case "$seen" in *" $tok "*) continue ;; esac
        seen="$seen$tok "
        out="${out:+$out }$tok"
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
install_dependencies_debian_based() {
    plain_msg ""
    yellow_msg 'Installing dependencies...'

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -q; then
        yellow_msg "apt-get update failed - continuing with the cached package index."
    fi

    if ! apt-get install -yq wget curl jq net-tools iproute2 ca-certificates; then
        DEPS_OK=0
        yellow_msg "Some base dependencies could not be installed; continuing in degraded mode."
    fi
    # dnsutils is transitional on recent releases; bind9-dnsutils is the new name.
    if ! command -v dig >/dev/null 2>&1; then
        apt-get install -yq dnsutils >/dev/null 2>&1 || apt-get install -yq bind9-dnsutils >/dev/null 2>&1 || true
    fi

    if command -v dig >/dev/null 2>&1; then
        green_msg 'Dependencies installed.'
    else
        DEPS_OK=0
        yellow_msg "dig is unavailable - DNS pre-flight and verification will run in reduced mode."
    fi
}

install_dependencies_rhel_based() {
    plain_msg ""
    yellow_msg 'Installing dependencies...'

    local pm=""
    if command -v dnf >/dev/null 2>&1; then pm="dnf"
    elif command -v yum >/dev/null 2>&1; then pm="yum"
    fi

    if [ -z "$pm" ]; then
        DEPS_OK=0
        yellow_msg "Neither dnf nor yum was found; skipping dependency installation."
        return 0
    fi

    if ! "$pm" install -y wget curl jq net-tools iproute bind-utils ca-certificates; then
        DEPS_OK=0
        yellow_msg "Some dependencies could not be installed; continuing in degraded mode."
    fi

    if command -v dig >/dev/null 2>&1; then
        green_msg 'Dependencies installed.'
    else
        DEPS_OK=0
        yellow_msg "dig is unavailable - DNS pre-flight and verification will run in reduced mode."
    fi
}

# ---------------------------------------------------------------------------
# /etc/hosts
# ---------------------------------------------------------------------------
fix_etc_hosts() {
    plain_msg ""
    yellow_msg "Fixing hosts file..."

    if [ ! -f "$HOST_PATH" ]; then
        red_msg "$HOST_PATH does not exist; skipping."
        return 1
    fi

    if [ ! -f /etc/hosts.bak ]; then
        if cp "$HOST_PATH" /etc/hosts.bak; then
            yellow_msg "Default hosts file saved to /etc/hosts.bak"
        fi
    fi

    local hname esc
    hname=$(hostname 2>/dev/null) || hname=""
    if [ -z "$hname" ]; then
        yellow_msg "Hostname is empty; hosts file left untouched."
        return 1
    fi

    # Escape every regex metacharacter and match only real (uncommented) entries.
    esc=$(printf '%s' "$hname" | sed 's/[^a-zA-Z0-9_-]/\\&/g')
    if grep -Eq "^[[:space:]]*[^#[:space:]]+[[:space:]]+([^#]*[[:space:]])?${esc}([[:space:]]|\$)" "$HOST_PATH"; then
        green_msg "Hosts OK. No changes made."
    else
        if printf '127.0.1.1 %s\n' "$hname" >> "$HOST_PATH"; then
            green_msg "Hosts fixed (added 127.0.1.1 $hname)."
        else
            red_msg "Could not append to $HOST_PATH."
            return 1
        fi
    fi
    return 0
}

# ===========================================================================
# DNS SECTION
# ===========================================================================

get_dns_list() {
    case "$1" in
        1)  printf '%s' "1.1.1.1 1.0.0.1|2606:4700:4700::1111 2606:4700:4700::1001|1.1.1.1=1dot1dot1dot1.cloudflare-dns.com 1.0.0.1=1dot1dot1dot1.cloudflare-dns.com 2606:4700:4700::1111=1dot1dot1dot1.cloudflare-dns.com 2606:4700:4700::1001=1dot1dot1dot1.cloudflare-dns.com" ;;
        2)  printf '%s' "1.1.1.2 1.0.0.2|2606:4700:4700::1112 2606:4700:4700::1002|1.1.1.2=security.cloudflare-dns.com 1.0.0.2=security.cloudflare-dns.com 2606:4700:4700::1112=security.cloudflare-dns.com 2606:4700:4700::1002=security.cloudflare-dns.com" ;;
        3)  printf '%s' "1.1.1.3 1.0.0.3|2606:4700:4700::1113 2606:4700:4700::1003|1.1.1.3=family.cloudflare-dns.com 1.0.0.3=family.cloudflare-dns.com 2606:4700:4700::1113=family.cloudflare-dns.com 2606:4700:4700::1003=family.cloudflare-dns.com" ;;
        4)  printf '%s' "8.8.8.8 8.8.4.4|2001:4860:4860::8888 2001:4860:4860::8844|8.8.8.8=dns.google 8.8.4.4=dns.google 2001:4860:4860::8888=dns.google 2001:4860:4860::8844=dns.google" ;;
        5)  printf '%s' "9.9.9.9 149.112.112.112|2620:fe::fe 2620:fe::9|9.9.9.9=dns.quad9.net 149.112.112.112=dns.quad9.net 2620:fe::fe=dns.quad9.net 2620:fe::9=dns.quad9.net" ;;
        6)  printf '%s' "94.140.14.14 94.140.15.15|2a10:50c0::ad1:ff 2a10:50c0::ad2:ff|94.140.14.14=dns.adguard-dns.com 94.140.15.15=dns.adguard-dns.com 2a10:50c0::ad1:ff=dns.adguard-dns.com 2a10:50c0::ad2:ff=dns.adguard-dns.com" ;;
        7)  printf '%s' "208.67.222.222 208.67.220.220|2620:119:35::35 2620:119:53::53|208.67.222.222=dot.opendns.com 208.67.220.220=dot.opendns.com 2620:119:35::35=dot.opendns.com 2620:119:53::53=dot.opendns.com" ;;
        8)  printf '%s' "178.22.122.100 185.51.200.2||" ;;
        9)  printf '%s' "78.157.42.100 78.157.42.101||" ;;
        10) printf '%s' "10.202.10.202 10.202.10.102||" ;;
        11) printf '%s' "185.55.226.26 185.55.225.25||" ;;
        12) printf '%s' "10.202.10.10 10.202.10.11||" ;;
        13) printf '%s' "178.22.122.100 185.51.200.2 78.157.42.100 78.157.42.101||" ;;
        14) printf '%s' "1.1.1.1 8.8.8.8|2606:4700:4700::1111 2001:4860:4860::8888|1.1.1.1=1dot1dot1dot1.cloudflare-dns.com 8.8.8.8=dns.google 2606:4700:4700::1111=1dot1dot1dot1.cloudflare-dns.com 2001:4860:4860::8888=dns.google" ;;
        15) printf '%s' "custom||" ;;
        *)  printf '%s' "" ;;
    esac
}

get_dns_name() {
    case "$1" in
        1)  printf '%s' "Cloudflare" ;;              2)  printf '%s' "Cloudflare Anti-Malware" ;;
        3)  printf '%s' "Cloudflare Family" ;;       4)  printf '%s' "Google" ;;
        5)  printf '%s' "Quad9" ;;                   6)  printf '%s' "AdGuard" ;;
        7)  printf '%s' "OpenDNS" ;;                 8)  printf '%s' "Shecan (IR)" ;;
        9)  printf '%s' "Electro (IR)" ;;            10) printf '%s' "403.online (IR)" ;;
        11) printf '%s' "Begzar (IR)" ;;             12) printf '%s' "Radar Game (IR)" ;;
        13) printf '%s' "Mix: Shecan + Electro" ;;   14) printf '%s' "Mix: Cloudflare + Google" ;;
        15) printf '%s' "Custom" ;;
        *)  printf '%s' "Unknown" ;;
    esac
}

_ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
_ipv6_regex='^(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:((:[0-9A-Fa-f]{1,4}){1,6})|:((:[0-9A-Fa-f]{1,4}){1,7}|:))$'

valid_ipv4() {
    local ip="$1" oct
    [[ "$ip" =~ $_ipv4_regex ]] || return 1
    for oct in ${ip//./ }; do
        [ "${#oct}" -gt 1 ] && [ "${oct:0:1}" = "0" ] && return 1
        (( 10#$oct <= 255 )) || return 1
    done
    return 0
}

_PY_VALID=""
init_ip_validator() {
    # Runs in the parent shell so the probe result is cached for real.
    valid_ip 4 127.0.0.1 >/dev/null 2>&1
    return 0
}

valid_ip() {
    local fam="$1" ip="$2"
    [ -n "$ip" ] || return 1
    # python3 gives exact validation, but a broken/stubbed python3 must not make
    # every address look invalid: self-test once, then fall back to regexes.
    if [ -z "$_PY_VALID" ]; then
        if command -v python3 >/dev/null 2>&1 && \
           python3 -c 'import ipaddress; ipaddress.IPv4Address("127.0.0.1")' >/dev/null 2>&1; then
            _PY_VALID=1
        else
            _PY_VALID=0
            if command -v python3 >/dev/null 2>&1; then
                yellow_msg "python3 is present but unusable; using the built-in IP validation."
            fi
        fi
    fi
    if [ "$_PY_VALID" = "1" ]; then
        python3 - "$fam" "$ip" <<'PYEOF' >/dev/null 2>&1
import sys, ipaddress
fam, ip = sys.argv[1], sys.argv[2]
try:
    ipaddress.IPv4Address(ip) if fam == "4" else ipaddress.IPv6Address(ip)
except Exception:
    sys.exit(1)
sys.exit(0)
PYEOF
        return $?
    fi
    if [ "$fam" = "4" ]; then
        valid_ipv4 "$ip"
    else
        [[ "$ip" =~ $_ipv6_regex ]]
    fi
}

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*|169.254.*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)          return 0 ;;  # CGNAT 100.64/10
    esac
    return 1
}

filter_valid_dns() {
    local fam="$1" list="$2" ip out=""
    for ip in $list; do
        if valid_ip "$fam" "$ip" && [ "$ip" != "0.0.0.0" ] && [ "$ip" != "::" ]; then
            out="$out$ip "
        fi
    done
    dedup_list "$out"
}

read_validated_dns() {
    local fam="$1" prompt="$2" required="$3"
    local input ip bad valid
    while true; do
        read_input input "$prompt" || return 1
        valid=""
        bad=""
        for ip in $input; do
            if valid_ip "$fam" "$ip" && [ "$ip" != "0.0.0.0" ] && [ "$ip" != "::" ]; then
                case "$ip" in
                    127.*|::1) yellow_msg "Warning: $ip is loopback - only valid if a local DNS service is running." ;;
                esac
                valid="$valid $ip"
            else
                bad="$bad $ip"
            fi
        done
        [ -n "$bad" ] && red_msg "Rejected invalid IPv$fam address(es):$bad"
        valid=$(dedup_list "$valid")
        if [ -n "$valid" ]; then
            printf '%s' "$valid"
            return 0
        fi
        [ "$required" = "0" ] && return 0
        red_msg "At least one valid IPv$fam DNS server is required."
    done
}

choose_dns() {
    if [ -n "$OPT_DNS_CHOICE" ]; then
        DNS_CHOICE="$OPT_DNS_CHOICE"
        DNS_LIST=$(get_dns_list "$DNS_CHOICE")
        if [ -z "$DNS_LIST" ]; then
            red_msg "Invalid --dns value: $OPT_DNS_CHOICE (valid: 1-15)."
            return 1
        fi
        return 0
    fi

    if [ "$OPT_ASSUME_YES" = "1" ]; then
        red_msg "--yes was given without --dns=N; refusing to guess a DNS configuration."
        return 1
    fi

    plain_msg ""
    yellow_msg "Select a DNS configuration:"
    cat >&2 <<'EOF'
 1)  Cloudflare                 (1.1.1.1)
 2)  Cloudflare Anti-Malware    (1.1.1.2)  <- recommended
 3)  Cloudflare Family          (1.1.1.3)
 4)  Google                     (8.8.8.8)
 5)  Quad9                      (9.9.9.9)
 6)  AdGuard AdBlock            (94.140.14.14)
 7)  OpenDNS                    (208.67.222.222)
 8)  Shecan [IR]                (178.22.122.100)
 9)  Electro [IR]               (78.157.42.100)
 10) 403.online [IR]            (10.202.10.202)
 11) Begzar [IR]                (185.55.226.26)
 12) Radar Game [IR]            (10.202.10.10)
 13) Mix: Shecan + Electro [IR]
 14) Mix: Cloudflare + Google
 15) Custom (manual input)
EOF
    plain_msg ""
    while true; do
        read_input DNS_CHOICE "[*] Select DNS [1-15]: " || return 1
        DNS_LIST=$(get_dns_list "$DNS_CHOICE")
        [ -n "$DNS_LIST" ] && return 0
        red_msg "Invalid choice, try again."
    done
}

parse_dns_choice() {
    local ip
    DNS_NAME=$(get_dns_name "$DNS_CHOICE")

    if [ "$DNS_CHOICE" = "15" ]; then
        if [ -n "$OPT_DNS_V4" ] || [ -n "$OPT_DNS_V6" ]; then
            DNS_V4=$(filter_valid_dns 4 "$OPT_DNS_V4")
            DNS_V6=$(filter_valid_dns 6 "$OPT_DNS_V6")
            if [ -z "$DNS_V4" ]; then
                red_msg "No valid IPv4 DNS in --dns-v4 (got: $OPT_DNS_V4)."
                return 1
            fi
            DOT_PAIRS=""
        else
            if [ "$OPT_ASSUME_YES" = "1" ]; then
                red_msg "--dns=15 with --yes needs --dns-v4 (and optionally --dns-v6)."
                return 1
            fi
            DNS_V4=$(read_validated_dns 4 "[*] Enter IPv4 DNS servers (space separated): " 1) \
                || { red_msg "DNS input aborted. Skipping DNS change."; return 1; }
            DNS_V6=$(read_validated_dns 6 "[*] Enter IPv6 DNS servers (optional, blank to skip): " 0)
            DOT_PAIRS=""
            local CUSTOM_DOT=""
            read_input CUSTOM_DOT "[*] DoT hostname(s) for these servers (optional, blank = no DoT): " || CUSTOM_DOT=""
            CUSTOM_DOT=${CUSTOM_DOT//,/ }
            if [ -n "$CUSTOM_DOT" ]; then
                local -a allsrv=()
                local sni idx=0
                for ip in $DNS_V4 $DNS_V6; do allsrv+=("$ip"); done
                for sni in $CUSTOM_DOT; do
                    if [[ ! "$sni" =~ ^[A-Za-z0-9.-]+$ ]]; then
                        red_msg "Ignoring invalid DoT hostname: $sni"
                    elif [ -n "${allsrv[$idx]:-}" ]; then
                        DOT_PAIRS="$DOT_PAIRS${allsrv[$idx]}=$sni "
                    fi
                    idx=$((idx + 1))
                done
                DOT_PAIRS=${DOT_PAIRS% }
            fi
        fi
    else
        DNS_V4="${DNS_LIST%%|*}"
        local rest="${DNS_LIST#*|}"
        case "$rest" in
            *"|"*) DNS_V6="${rest%%|*}"; DOT_PAIRS="${rest#*|}" ;;
            *)     DNS_V6="$rest";       DOT_PAIRS="" ;;
        esac
    fi

    # Iranian / filtering resolvers answer with manipulated records, which a
    # strict DNSSEC setting would reject outright.
    case "$DNS_CHOICE" in
        8|9|10|11|12|13) DNS_IS_IR=1 ;;
    esac
    for ip in $DNS_V4; do
        is_private_ipv4 "$ip" && DNS_IS_IR=1
    done
    return 0
}

systemd_major_version() {
    local v
    v=$(LC_ALL=C systemctl --version 2>/dev/null | awk 'NR==1{print $2}')
    case "$v" in
        ''|*[!0-9]*) printf '%s' "0" ;;
        *)           printf '%s' "$v" ;;
    esac
}

decide_dot_mode() {
    DOT_MODE="disabled"
    [ -n "$DOT_PAIRS" ] || return 0
    local sv
    sv=$(systemd_major_version)
    if [ "$sv" -ge 243 ] 2>/dev/null; then
        DOT_MODE="opportunistic"
    elif [ "$sv" -ge 239 ] 2>/dev/null; then
        DOT_MODE="opportunistic-unknown"
    else
        DOT_MODE="disabled"
    fi
    return 0
}

dot_mode_desc() {
    case "$DOT_MODE" in
        disabled)              printf '%s' "Disabled" ;;
        opportunistic)         printf '%s' "Opportunistic DoT (DNSOverTLS=opportunistic, per-server SNI set)" ;;
        opportunistic-unknown) printf '%s' "Opportunistic DoT (older systemd: no per-server SNI; the server must present a matching certificate)" ;;
        *)                     printf '%s' "Unknown" ;;
    esac
}

build_resolved_dns_value() {
    local pairs="$1" list="$2" ip sni p out=""
    for ip in $list; do
        sni=""
        for p in $pairs; do
            if [ "${p%%=*}" = "$ip" ]; then sni="${p#*=}"; break; fi
        done
        if [ -n "$sni" ]; then out="$out$ip#$sni "; else out="$out$ip "; fi
    done
    printf '%s' "${out% }"
}

print_server_list() {
    local list="$1" i=0 srv
    for srv in $list; do
        i=$((i + 1))
        case $i in
            1) plain_msg "  Primary:   $srv" ;;
            2) plain_msg "  Secondary: $srv" ;;
            *) plain_msg "  Extra $((i - 2)):   $srv" ;;
        esac
    done
}

print_selection_summary() {
    plain_msg ""
    plain_msg "Selected:"
    plain_msg "  $DNS_NAME"
    if [ -n "$DNS_V4" ]; then
        plain_msg "IPv4:"
        print_server_list "$DNS_V4"
    fi
    plain_msg "IPv6:"
    if [ -n "$DNS_V6" ]; then
        print_server_list "$DNS_V6"
    else
        plain_msg "  (none - IPv4 only; existing IPv6 DNS is left untouched)"
    fi
    decide_dot_mode
    plain_msg "DNS-over-TLS:"
    if [ "$METHOD" = "systemd-resolved" ]; then
        plain_msg "  $(dot_mode_desc)"
    else
        plain_msg "  Not applicable ($METHOD cannot carry DoT settings)"
    fi
    plain_msg "DNSSEC:"
    if [ "$METHOD" != "systemd-resolved" ]; then
        plain_msg "  Not applicable ($METHOD has no DNSSEC setting)"
    elif [ "$DNS_IS_IR" = "1" ]; then
        plain_msg "  Disabled for this preset (filtering resolvers return manipulated answers)"
    else
        plain_msg "  Left at the system default"
    fi
    plain_msg "DNS manager:"
    plain_msg "  $METHOD"
    plain_msg ""
}

# --- manager detection ------------------------------------------------------

resolv_conf_is_resolved_stub() {
    if [ -L /etc/resolv.conf ]; then
        case "$(readlink /etc/resolv.conf)" in
            */systemd/resolve/*) return 0 ;;
        esac
    fi
    [ -f /etc/resolv.conf ] && grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null && return 0
    return 1
}

resolvconf_is_managed() {
    [ -L /etc/resolv.conf ] || return 1
    case "$(readlink /etc/resolv.conf)" in
        *resolvconf*) return 0 ;;
    esac
    return 1
}

detect_dns_method() {
    local resolved_active=0 nm_active=0 m="direct"
    if systemctl is-active --quiet systemd-resolved 2>/dev/null && command -v resolvectl >/dev/null 2>&1; then
        resolved_active=1
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        nm_active=1
    fi

    if [ "$resolved_active" = "1" ]; then
        m="systemd-resolved"
        if [ "$nm_active" = "1" ] && [ -L /etc/resolv.conf ]; then
            case "$(readlink /etc/resolv.conf)" in
                *NetworkManager*) m="networkmanager" ;;
            esac
        fi
    elif [ "$nm_active" = "1" ]; then
        m="networkmanager"
    elif command -v resolvconf >/dev/null 2>&1 && resolvconf_is_managed; then
        m="resolvconf"
    fi

    printf '%s' "$m"
    return 0
}

# --- link enumeration -------------------------------------------------------

network_links() {
    local out="" l
    if command -v resolvectl >/dev/null 2>&1; then
        out=$(LC_ALL=C resolvectl status --no-pager 2>/dev/null \
              | awk '/^Link [0-9]+ \(/ {gsub(/[()]/,"",$3); sub(/:$/,"",$3); print $3}')
    fi
    if [ -z "$out" ] && [ -d /sys/class/net ]; then
        out=$(ls -1 /sys/class/net 2>/dev/null)
    fi
    for l in $out; do
        [ -z "$l" ] && continue
        [ "$l" = "lo" ] && continue
        printf '%s\n' "$l"
    done
    return 0
}

has_ipv6() {
    if command -v ip >/dev/null 2>&1; then
        LC_ALL=C ip -6 route show default 2>/dev/null | grep -q '^default' && return 0
        return 1
    fi
    # /proc/net/if_inet6 columns: address ifindex prefixlen scope flags device
    # Scope is field 4; 00 means global.
    if [ -f /proc/net/if_inet6 ]; then
        awk 'NF>=4 && $4 == "00" {found=1} END{exit !found}' /proc/net/if_inet6 2>/dev/null && return 0
    fi
    return 1
}

# --- direct probing ---------------------------------------------------------

have_direct_query_tool() {
    command -v dig >/dev/null 2>&1 && return 0
    command -v nslookup >/dev/null 2>&1 && return 0
    return 1
}

_answer_has_address() {
    local out="$1" line
    [ -n "$out" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
            *:*:*)                       return 0 ;;
        esac
    done <<< "$out"
    return 1
}

dig_answers() {
    local out
    out=$(timeout 8 dig @"$1" "$2" +short +time=3 +tries=1 2>/dev/null) || return 1
    _answer_has_address "$out"
}

nslookup_answers() {
    local out n
    out=$(timeout 8 nslookup "$2" "$1" 2>/dev/null) || return 1
    # The first "Address:" line is always the server itself; a real answer adds more.
    n=$(printf '%s\n' "$out" | grep -c 'Address') || n=0
    [ "${n:-0}" -ge 2 ]
}

# Returns 0 and prints "<server> (<name>)" on success, 1 on failure,
# 2 when no query tool is available at all.
probe_server() {
    local srv="$1" q
    if command -v dig >/dev/null 2>&1; then
        for q in $PROBE_NAMES; do
            if dig_answers "$srv" "$q"; then
                printf '%s (%s)' "$srv" "$q"
                return 0
            fi
        done
        return 1
    fi
    if command -v nslookup >/dev/null 2>&1; then
        for q in $PROBE_NAMES; do
            if nslookup_answers "$srv" "$q"; then
                printf '%s (%s)' "$srv" "$q"
                return 0
            fi
        done
        return 1
    fi
    return 2
}

preflight_dns_servers() {
    local servers="$1" srv ok="" tried=0 good=0 rc

    # This function runs inside $( ), so it must not rely on setting globals.
    if ! have_direct_query_tool; then
        yellow_msg "Neither dig nor nslookup is installed - pre-flight probing was skipped."
        printf '%s' "$(dedup_list "$servers")"
        return 0
    fi

    for srv in $servers; do
        tried=$((tried + 1))
        probe_server "$srv" >/dev/null
        rc=$?
        case "$rc" in
            0|2) ok="$ok$srv "; good=$((good + 1)) ;;
            *)   red_msg "Pre-flight: $srv did not answer any probe (skipped)." ;;
        esac
    done

    if [ "$tried" -gt 0 ] && [ "$good" -eq 0 ]; then
        red_msg "Pre-flight: none of [$servers] answered. Aborting the DNS change (current DNS kept)."
        return 1
    fi

    printf '%s' "$(dedup_list "$ok")"
    return 0
}

dns_query_via_new_server() {
    local srv res rc
    for srv in $DNS_V4 $DNS_V6; do
        res=$(probe_server "$srv")
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s' "$res"
            return 0
        fi
        # 2 = no query tool installed at all; the caller degrades instead of failing.
        [ "$rc" -eq 2 ] && return 2
    done
    return 1
}

dns_query_ok() {
    timeout 6 getent hosts "$1" >/dev/null 2>&1
}

# --- resolv.conf primitives -------------------------------------------------

resolvconf_writable() {
    local attrs
    [ -L /etc/resolv.conf ] && return 0
    [ -e /etc/resolv.conf ] || return 0

    if command -v lsattr >/dev/null 2>&1; then
        attrs=$(lsattr -d -- /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        case "$attrs" in
            *i*)
                if command -v chattr >/dev/null 2>&1 && chattr -i /etc/resolv.conf 2>/dev/null; then
                    RESOLV_WAS_IMMUTABLE=1
                    yellow_msg "Removed the immutable flag from /etc/resolv.conf (it will be restored on rollback)."
                else
                    red_msg "/etc/resolv.conf is immutable (chattr +i) and cannot be cleared."
                    return 1
                fi
                ;;
        esac
    fi

    if [ -f /etc/resolv.conf ] && [ ! -w /etc/resolv.conf ]; then
        red_msg "/etc/resolv.conf is not writable."
        return 1
    fi
    return 0
}

snapshot_resolvconf() {
    [ "$RESOLV_SNAPSHOT_DONE" = "1" ] && return 0
    RESOLV_SNAPSHOT_DONE=1
    if [ -L /etc/resolv.conf ]; then
        RESOLV_WAS_SYMLINK=1
        RESOLV_SYMLINK_TARGET=$(readlink /etc/resolv.conf)
        cp -L /etc/resolv.conf "$RESOLV_BAK_FILE" 2>/dev/null || true
    elif [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$RESOLV_BAK_FILE" 2>/dev/null || true
    fi
    return 0
}

resolv_extra_directives() {
    # search / domain / options / sortlist must survive a rewrite, otherwise
    # short-name and internal-domain resolution breaks.
    local src="$1"
    [ -n "$src" ] && [ -f "$src" ] || return 0
    grep -E '^[[:space:]]*(search|domain|options|sortlist)[[:space:]]' "$src" 2>/dev/null || true
    return 0
}

emit_nameservers() {
    local n=0 total=0 ns
    for ns in $DNS_V4 $DNS_V6; do total=$((total + 1)); done
    for ns in $DNS_V4 $DNS_V6; do
        n=$((n + 1))
        [ "$n" -gt "$MAXNS" ] && break
        printf 'nameserver %s\n' "$ns"
    done
    if [ "$total" -gt "$MAXNS" ]; then
        yellow_msg "glibc reads at most $MAXNS nameservers from resolv.conf; $((total - MAXNS)) entr(y/ies) were not written."
    fi
    return 0
}

write_resolvconf_direct() {
    resolvconf_writable || return 1
    snapshot_resolvconf
    local tmp="/etc/.resolv.conf.linux-optimizer.$$"

    {
        printf '# Generated by Linux-Optimizer (%s)\n' "$TS"
        emit_nameservers
        resolv_extra_directives "$RESOLV_BAK_FILE"
    } > "$tmp" || { rm -f "$tmp"; red_msg "Failed to stage a new /etc/resolv.conf."; return 1; }

    if ! grep -q '^nameserver ' "$tmp"; then
        rm -f "$tmp"
        red_msg "Refusing to install a resolv.conf without any nameserver."
        return 1
    fi

    chmod 644 "$tmp"
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    if ! mv -f "$tmp" /etc/resolv.conf; then
        rm -f "$tmp"
        red_msg "Failed to install /etc/resolv.conf."
        return 1
    fi
    RESOLV_MODIFIED=1
    return 0
}

restore_resolvconf() {
    # Never delete before a restore path is guaranteed.
    if [ "$RESOLV_WAS_SYMLINK" = "1" ] && [ -n "$RESOLV_SYMLINK_TARGET" ]; then
        rm -f /etc/resolv.conf
        ln -s "$RESOLV_SYMLINK_TARGET" /etc/resolv.conf
    elif [ -f "$RESOLV_BAK_FILE" ]; then
        rm -f /etc/resolv.conf
        cp "$RESOLV_BAK_FILE" /etc/resolv.conf
        chmod 644 /etc/resolv.conf
    else
        # Nothing to restore: leave a minimal working file rather than nothing.
        red_msg "No previous /etc/resolv.conf to restore; writing a minimal fallback."
        {
            printf '# Fallback written by Linux-Optimizer (%s)\n' "$TS"
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
        } > /etc/resolv.conf 2>/dev/null || true
        chmod 644 /etc/resolv.conf 2>/dev/null || true
    fi

    if [ "$RESOLV_WAS_IMMUTABLE" = "1" ] && command -v chattr >/dev/null 2>&1; then
        chattr +i /etc/resolv.conf 2>/dev/null && yellow_msg "Restored the immutable flag on /etc/resolv.conf."
    fi
    return 0
}

# --- systemd-resolved -------------------------------------------------------

resolved_conf_files() {
    printf '%s\n' /etc/systemd/resolved.conf
    find /usr/lib/systemd/resolved.conf.d /etc/systemd/resolved.conf.d /run/systemd/resolved.conf.d \
         -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort
    return 0
}

resolved_conf_value() {
    local key="$1" f line v=""
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        line=$(grep -E "^[[:space:]]*${key}=" "$f" 2>/dev/null | tail -n 1) || line=""
        [ -n "$line" ] && v="${line#*=}"
    done < <(resolved_conf_files)
    printf '%s' "$v"
    return 0
}

resolved_stub_active() {
    local v sockets
    v=$(resolved_conf_value DNSStubListener)
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        no|false|0|off) return 1 ;;
    esac
    if command -v ss >/dev/null 2>&1; then
        sockets=$(LC_ALL=C ss -lnu 2>/dev/null; LC_ALL=C ss -lnt 2>/dev/null)
        case "$sockets" in
            *127.0.0.53:53*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

ensure_resolved_stub() {
    local target=""

    if resolved_stub_active && [ -e /run/systemd/resolve/stub-resolv.conf ]; then
        target="/run/systemd/resolve/stub-resolv.conf"
    elif [ -e /run/systemd/resolve/resolv.conf ]; then
        # Stub listener disabled: 127.0.0.53 would be a black hole, so point at
        # the file that lists the real upstream servers instead.
        target="/run/systemd/resolve/resolv.conf"
        yellow_msg "DNSStubListener is disabled; using /run/systemd/resolve/resolv.conf."
    else
        yellow_msg "systemd-resolved runtime files are missing; falling back to a direct /etc/resolv.conf."
        write_resolvconf_direct || return 1
        return 0
    fi

    if [ -L /etc/resolv.conf ] && [ "$(readlink /etc/resolv.conf)" = "$target" ]; then
        return 0
    fi

    snapshot_resolvconf
    resolvconf_writable || return 1
    rm -f /etc/resolv.conf
    if ! ln -s "$target" /etc/resolv.conf; then
        red_msg "Failed to create the resolv.conf symlink to $target."
        return 1
    fi
    RESOLV_MODIFIED=1
    yellow_msg "/etc/resolv.conf now points to $target."
    return 0
}

warn_legacy_resolved_conf() {
    # The 99-* drop-in already overrides /etc/systemd/resolved.conf, and the
    # drop-in resets the list with an empty DNS= before assigning ours, so the
    # main file is intentionally NOT modified here.
    local f="/etc/systemd/resolved.conf"
    [ -f "$f" ] || return 0
    if grep -Eq '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS|DNSSEC)=' "$f" 2>/dev/null; then
        yellow_msg "Note: $f contains its own DNS directives. They are left untouched; the drop-in $RESOLVED_DROPIN overrides them."
    fi
    return 0
}

apply_dns_systemd_resolved() {
    yellow_msg "Method: systemd-resolved"
    decide_dot_mode

    local dns_value new_content
    dns_value="$DNS_V4"
    [ -n "$DNS_V6" ] && dns_value="$DNS_V4 $DNS_V6"

    case "$DOT_MODE" in
        opportunistic)
            dns_value=$(build_resolved_dns_value "$DOT_PAIRS" "$dns_value")
            ;;
    esac

    # "DNS=" with an empty value resets the list inherited from resolved.conf,
    # then our servers are appended. "Domains=~." routes *every* lookup to the
    # global servers, so per-link DHCP DNS can no longer win.
    new_content="# Managed by Linux-Optimizer - do not edit"$'\n'
    new_content+="[Resolve]"$'\n'
    new_content+="DNS="$'\n'
    new_content+="DNS=$dns_value"$'\n'
    new_content+="Domains=~."$'\n'
    case "$DOT_MODE" in
        opportunistic|opportunistic-unknown) new_content+="DNSOverTLS=opportunistic"$'\n' ;;
    esac
    [ "$DNS_IS_IR" = "1" ] && new_content+="DNSSEC=no"$'\n'

    if ! mkdir -p "$(dirname "$RESOLVED_DROPIN")"; then
        red_msg "Could not create $(dirname "$RESOLVED_DROPIN")."
        return 1
    fi

    if [ -f "$RESOLVED_DROPIN" ]; then
        if [ "$(cat "$RESOLVED_DROPIN" 2>/dev/null)" != "${new_content%$'\n'}" ]; then
            RESOLVED_DROPIN_BAK="${RESOLVED_DROPIN}.bak.$TS"
            cp "$RESOLVED_DROPIN" "$RESOLVED_DROPIN_BAK" 2>/dev/null || true
            RESOLVED_DROPIN_EXISTED=1
            printf '%s' "$new_content" > "$RESOLVED_DROPIN" || return 1
            RESOLVED_DROPIN_WRITTEN=1
        fi
    else
        printf '%s' "$new_content" > "$RESOLVED_DROPIN" || return 1
        RESOLVED_DROPIN_WRITTEN=1
    fi
    chmod 644 "$RESOLVED_DROPIN" 2>/dev/null || true

    warn_legacy_resolved_conf

    if [ "$RESOLVED_DROPIN_WRITTEN" = "1" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if ! systemctl restart systemd-resolved; then
            red_msg "systemd-resolved failed to restart."
            return 1
        fi
        green_msg "systemd-resolved restarted with the new configuration."
    else
        green_msg "systemd-resolved drop-in already up to date; no restart needed."
    fi

    ensure_resolved_stub || return 1

    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        nm_apply_dns_to_profiles
    fi

    override_link_dns_runtime "$dns_value"
    persist_dns_state
    configure_netplan_dns
    return 0
}

override_link_dns_runtime() {
    command -v resolvectl >/dev/null 2>&1 || return 0
    local link value="$1"
    RESOLVED_LINKS_TOUCHED=()

    while IFS= read -r link; do
        [ -n "$link" ] || continue
        # The server lists are word-split on purpose.
        # shellcheck disable=SC2086
        if resolvectl dns "$link" $value >/dev/null 2>&1; then
            RESOLVED_LINKS_TOUCHED+=("$link")
        elif resolvectl dns "$link" $DNS_V4 $DNS_V6 >/dev/null 2>&1; then
            RESOLVED_LINKS_TOUCHED+=("$link")
        fi
    done < <(network_links)

    # Flush AFTER the change, never before, or stale answers survive into
    # verification.
    resolvectl flush-caches >/dev/null 2>&1 || true
    return 0
}

networkd_active() {
    systemctl is-active --quiet systemd-networkd 2>/dev/null
}

persist_dns_state() {
    [ -n "$DNS_V4" ] || return 0
    mkdir -p "$DNS_STATE_DIR" 2>/dev/null || return 0

    local all="$DNS_V4"
    [ -n "$DNS_V6" ] && all="$DNS_V4 $DNS_V6"
    printf 'OPT_DNS_ALL="%s"\n' "$all" > "$DNS_STATE_FILE" || return 0
    chmod 644 "$DNS_STATE_FILE"
    DNS_STATE_WRITTEN=1

    networkd_active || return 0
    command -v networkd-dispatcher >/dev/null 2>&1 || return 0
    [ -d /etc/networkd-dispatcher ] || mkdir -p /etc/networkd-dispatcher 2>/dev/null || return 0
    mkdir -p "$(dirname "$NETWORKD_DISPATCHER_HOOK")" 2>/dev/null || return 0

    if [ ! -f "$NETWORKD_DISPATCHER_HOOK" ]; then
        # networkd-dispatcher exports IFACE (NetworkManager's dispatcher uses
        # DEVICE / $1) - accept all three so the hook actually fires.
        cat > "$NETWORKD_DISPATCHER_HOOK" <<'EOF'
#!/bin/sh
DEV="${IFACE:-${DEVICE:-$1}}"
[ -n "$DEV" ] || exit 0
[ "$DEV" = "lo" ] && exit 0
[ -r /var/lib/linux-optimizer/dns.env ] || exit 0
command -v resolvectl >/dev/null 2>&1 || exit 0
. /var/lib/linux-optimizer/dns.env
[ -n "$OPT_DNS_ALL" ] || exit 0
resolvectl dns "$DEV" $OPT_DNS_ALL >/dev/null 2>&1 || true
exit 0
EOF
        chmod 755 "$NETWORKD_DISPATCHER_HOOK"
        DNS_HOOK_CREATED=1
        green_msg "networkd-dispatcher hook installed."
    fi
    systemctl try-restart networkd-dispatcher >/dev/null 2>&1 || true
    return 0
}

# --- netplan ----------------------------------------------------------------

iface_is_plain_ethernet() {
    local l="$1"
    [ -d "/sys/class/net/$l" ] || return 1
    [ -e "/sys/class/net/$l/bonding" ] && return 1
    [ -e "/sys/class/net/$l/bridge" ] && return 1
    [ -e "/sys/class/net/$l/bonding_slave" ] && return 1
    [ -e "/sys/class/net/$l/brport" ] && return 1
    [ -f "/proc/net/vlan/$l" ] && return 1
    case "$l" in
        *.*|veth*|docker*|br-*|tun*|tap*|wg*|zt*) return 1 ;;
    esac
    return 0
}

netplan_unit_for_iface() {
    find /run/systemd/network -maxdepth 1 -type f -name "*-netplan-${1}.network" 2>/dev/null | head -n 1
}

iface_dhcp_mode() {
    # prints: none | v4 | v6 | both
    local f line v
    f=$(netplan_unit_for_iface "$1")
    [ -n "$f" ] || { printf '%s' "none"; return 0; }
    line=$(grep -iE '^[[:space:]]*DHCP=' "$f" 2>/dev/null | tail -n 1) || line=""
    v=$(printf '%s' "${line#*=}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$v" in
        yes|true|1) printf '%s' "both" ;;
        ipv4)       printf '%s' "v4" ;;
        ipv6)       printf '%s' "v6" ;;
        *)          printf '%s' "none" ;;
    esac
    return 0
}

configure_netplan_dns() {
    command -v netplan >/dev/null 2>&1 || return 0
    networkd_active || return 0
    [ -d /etc/netplan ] || return 0

    if grep -rqsE '^[[:space:]]*renderer:[[:space:]]*NetworkManager' /etc/netplan /run/netplan /usr/lib/netplan 2>/dev/null; then
        return 0
    fi

    local -a links=()
    local l
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        [ -n "$(netplan_unit_for_iface "$l")" ] || continue
        if ! iface_is_plain_ethernet "$l"; then
            yellow_msg "Skipping netplan override for $l (not a plain ethernet device)."
            continue
        fi
        links+=("$l")
    done < <(network_links)

    if [ "${#links[@]}" -eq 0 ]; then
        yellow_msg "No netplan-managed ethernet interface found; skipping the netplan override."
        return 0
    fi

    local body="" i ip dhcp
    for i in "${links[@]}"; do
        dhcp=$(iface_dhcp_mode "$i")
        body+="    ${i}:"$'\n'
        case "$dhcp" in
            both|v4) body+="      dhcp4-overrides:"$'\n'"        use-dns: false"$'\n' ;;
        esac
        case "$dhcp" in
            both|v6) body+="      dhcp6-overrides:"$'\n'"        use-dns: false"$'\n' ;;
        esac
        if [ -n "$DNS_V4" ] || [ -n "$DNS_V6" ]; then
            body+="      nameservers:"$'\n'"        addresses:"$'\n'
            for ip in $DNS_V4 $DNS_V6; do
                body+="          - $ip"$'\n'
            done
        fi
    done
    body=${body%$'\n'}

    local new_content="network:"$'\n'"  version: 2"$'\n'"  ethernets:"$'\n'"$body"

    if [ -f "$NETPLAN_DNS_FILE" ] && [ "$(cat "$NETPLAN_DNS_FILE" 2>/dev/null)" = "$new_content" ]; then
        green_msg "Netplan DNS override already up to date."
        return 0
    fi

    if [ -f "$NETPLAN_DNS_FILE" ]; then
        NETPLAN_BAK_FILE="${NETPLAN_DNS_FILE}.bak.$TS"
        cp "$NETPLAN_DNS_FILE" "$NETPLAN_BAK_FILE" || NETPLAN_BAK_FILE=""
    fi

    printf '%s\n' "$new_content" > "$NETPLAN_DNS_FILE" || return 0
    chmod 600 "$NETPLAN_DNS_FILE"
    NETPLAN_FILE_CREATED=1

    if ! netplan generate 2>/dev/null; then
        red_msg "netplan generate rejected the override (interface probably defined as a bond/bridge/VLAN elsewhere) - reverting that file only."
        if [ -n "$NETPLAN_BAK_FILE" ] && [ -f "$NETPLAN_BAK_FILE" ]; then
            mv -f "$NETPLAN_BAK_FILE" "$NETPLAN_DNS_FILE"
        else
            rm -f "$NETPLAN_DNS_FILE"
        fi
        NETPLAN_FILE_CREATED=0
        NETPLAN_BAK_FILE=""
        netplan generate >/dev/null 2>&1 || true
        return 0
    fi

    green_msg "Netplan DNS override written: $NETPLAN_DNS_FILE"
    if [ "$OPT_NETPLAN_APPLY" = "1" ]; then
        yellow_msg "Running netplan apply (this can briefly interrupt networking)..."
        if netplan apply 2>/dev/null; then
            green_msg "netplan apply completed."
        else
            red_msg "netplan apply failed; the override stays on disk and will take effect after a reboot."
        fi
    else
        yellow_msg "Not applied yet - run 'netplan apply' or reboot, or re-run with --netplan-apply."
    fi
    return 0
}

# --- NetworkManager ---------------------------------------------------------

nm_apply_dns_to_profiles() {
    local uuid dev name od4 oi4 od6 oi6 v4c v6c
    NM_APPLIED=0
    v4c="${DNS_V4// /,}"
    v6c="${DNS_V6// /,}"

    while IFS=: read -r uuid dev; do
        [ -n "$uuid" ] || continue
        case "$dev" in lo|--|"") continue ;; esac
        name=$(nmcli -g connection.id connection show "$uuid" 2>/dev/null) || continue
        [ "$name" = "lo" ] && continue

        od4=$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null) || od4=""
        oi4=$(nmcli -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null) || oi4=""
        od6=$(nmcli -g ipv6.dns connection show "$uuid" 2>/dev/null) || od6=""
        oi6=$(nmcli -g ipv6.ignore-auto-dns connection show "$uuid" 2>/dev/null) || oi6=""

        if ! nmcli connection modify "$uuid" ipv4.dns "$v4c" ipv4.ignore-auto-dns yes >/dev/null 2>&1; then
            continue
        fi
        if [ -n "$v6c" ]; then
            nmcli connection modify "$uuid" ipv6.dns "$v6c" ipv6.ignore-auto-dns yes >/dev/null 2>&1 || true
        fi

        NM_CHANGES+=("$uuid|$dev|$od4|$oi4|$od6|$oi6")

        if nmcli device reapply "$dev" >/dev/null 2>&1; then
            NM_APPLIED=1
        elif nmcli connection up "$uuid" >/dev/null 2>&1; then
            # reapply is not enough on DHCP profiles; a full re-up applies DNS.
            NM_APPLIED=1
        fi
    done < <(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null)
    return 0
}

apply_dns_networkmanager() {
    yellow_msg "Method: NetworkManager"
    nm_apply_dns_to_profiles

    if [ "$NM_APPLIED" = "1" ]; then
        if grep -q "nameserver ${DNS_V4%% *}" /etc/resolv.conf 2>/dev/null || resolv_conf_is_resolved_stub; then
            persist_dns_state
            return 0
        fi
    fi

    write_resolvconf_direct || return 1

    if systemctl is-active --quiet NetworkManager 2>/dev/null && [ ! -f "$NM_DNSNONE_DROPIN" ]; then
        # dns=none only as a last resort, and only AFTER resolv.conf already
        # holds working servers, so a failed NM path cannot strand the host.
        if mkdir -p "$(dirname "$NM_DNSNONE_DROPIN")" 2>/dev/null &&
           printf '[main]\ndns=none\n' > "$NM_DNSNONE_DROPIN" 2>/dev/null; then
            NM_DNSNONE_CREATED=1
            nmcli general reload >/dev/null 2>&1 || true
        fi
    fi
    persist_dns_state
    return 0
}

# --- resolvconf -------------------------------------------------------------

apply_dns_resolvconf() {
    yellow_msg "Method: resolvconf"
    # The record name decides priority via /etc/resolvconf/interface-order,
    # where lo.* ranks above DHCP-supplied entries. A random name would be
    # appended after them and silently ignored.
    local iface="lo.linuxoptimizer"

    if command -v resolvconf >/dev/null 2>&1 && resolvconf_is_managed; then
        resolvconf -d "$iface" >/dev/null 2>&1 || true
        if {
                emit_nameservers
                resolv_extra_directives "$RESOLV_BAK_FILE"
           } | resolvconf -a "$iface" >/dev/null 2>&1; then
            RESOLV_MODIFIED=1
            return 0
        fi
        red_msg "resolvconf refused the update; falling back to a direct /etc/resolv.conf."
    fi

    write_resolvconf_direct || return 1
    return 0
}

apply_dns_direct() {
    yellow_msg "Method: direct /etc/resolv.conf"
    write_resolvconf_direct || return 1
    return 0
}

# --- verification / rollback ------------------------------------------------

get_effective_dns() {
    case "$METHOD" in
        systemd-resolved)
            if command -v resolvectl >/dev/null 2>&1; then
                LC_ALL=C resolvectl dns 2>/dev/null | sed -E 's/^[^:]*:[[:space:]]*//' | tr ' ' '\n'
            fi
            ;;
        networkmanager)
            nmcli -f IP4.DNS,IP6.DNS device show 2>/dev/null | sed -nE 's/.*DNS\[[0-9]+\]:[[:space:]]*//p'
            ;;
        *)
            awk '/^nameserver[[:space:]]/ {print $2}' /etc/resolv.conf 2>/dev/null
            ;;
    esac
    return 0
}

verify_dns() {
    sleep 1
    plain_msg ""
    yellow_msg "DNS verification..."
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1

    local effective via rc
    effective=$(dedup_list "$(get_effective_dns 2>/dev/null | tr '\n' ' ')")
    plain_msg "Effective DNS: ${effective:-(none visible yet)}"

    # 1) The new servers themselves must answer - this catches a false PASS
    #    coming from a cache or from /etc/hosts.
    via=$(dns_query_via_new_server)
    rc=$?
    case "$rc" in
        0) plain_msg "Direct query via new DNS: $via" ;;
        2) yellow_msg "Neither dig nor nslookup is available - the direct server probe was skipped." ;;
        *) red_msg "DNS test: FAIL (none of the new servers answered directly)"
           return 1 ;;
    esac

    # 2) The system resolver must work as well.
    if dns_query_ok github.com || dns_query_ok cloudflare.com || dns_query_ok wikipedia.org; then
        green_msg "DNS test: PASS"
        return 0
    fi
    red_msg "DNS test: FAIL (the system resolver cannot resolve names)"
    return 1
}

rollback_dns() {
    plain_msg ""
    red_msg "Rolling back to the previous DNS configuration..."
    local item uuid dev o4 i4 o6 i6 link

    # 1) runtime per-link overrides (they outrank anything written to disk)
    if [ "${#RESOLVED_LINKS_TOUCHED[@]}" -gt 0 ] && command -v resolvectl >/dev/null 2>&1; then
        for link in "${RESOLVED_LINKS_TOUCHED[@]}"; do
            resolvectl revert "$link" >/dev/null 2>&1 || true
        done
        RESOLVED_LINKS_TOUCHED=()
    fi

    # 2) NetworkManager profiles
    if [ "${#NM_CHANGES[@]}" -gt 0 ]; then
        for item in "${NM_CHANGES[@]}"; do
            IFS='|' read -r uuid dev o4 i4 o6 i6 <<< "$item"
            [ -n "$uuid" ] || continue
            nmcli connection modify "$uuid" ipv4.dns "$o4" ipv4.ignore-auto-dns "${i4:-no}" >/dev/null 2>&1 || true
            nmcli connection modify "$uuid" ipv6.dns "$o6" ipv6.ignore-auto-dns "${i6:-no}" >/dev/null 2>&1 || true
            nmcli device reapply "$dev" >/dev/null 2>&1 || true
        done
        NM_CHANGES=()
    fi

    if [ "$NM_DNSNONE_CREATED" = "1" ]; then
        rm -f "$NM_DNSNONE_DROPIN"
        NM_DNSNONE_CREATED=0
        nmcli general reload >/dev/null 2>&1 || true
    fi

    # 3) persistence helpers
    if [ "$DNS_HOOK_CREATED" = "1" ]; then
        rm -f "$NETWORKD_DISPATCHER_HOOK"
        DNS_HOOK_CREATED=0
        systemctl try-restart networkd-dispatcher >/dev/null 2>&1 || true
    fi
    if [ "$DNS_STATE_WRITTEN" = "1" ]; then
        rm -f "$DNS_STATE_FILE"
        DNS_STATE_WRITTEN=0
    fi

    # 4) netplan override
    if [ "$NETPLAN_FILE_CREATED" = "1" ]; then
        if [ -n "$NETPLAN_BAK_FILE" ] && [ -f "$NETPLAN_BAK_FILE" ]; then
            mv -f "$NETPLAN_BAK_FILE" "$NETPLAN_DNS_FILE"
        else
            rm -f "$NETPLAN_DNS_FILE"
        fi
        NETPLAN_FILE_CREATED=0
        NETPLAN_BAK_FILE=""
        command -v netplan >/dev/null 2>&1 && netplan generate >/dev/null 2>&1
    fi

    # 5) systemd-resolved drop-in
    if [ "$RESOLVED_DROPIN_WRITTEN" = "1" ]; then
        if [ "$RESOLVED_DROPIN_EXISTED" = "1" ] && [ -n "$RESOLVED_DROPIN_BAK" ] && [ -f "$RESOLVED_DROPIN_BAK" ]; then
            mv -f "$RESOLVED_DROPIN_BAK" "$RESOLVED_DROPIN"
        else
            rm -f "$RESOLVED_DROPIN"
        fi
        RESOLVED_DROPIN_WRITTEN=0
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi

    # 6) resolv.conf itself
    if [ "$RESOLV_MODIFIED" = "1" ]; then
        restore_resolvconf
        RESOLV_MODIFIED=0
    fi

    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1
    DNS_IN_FLIGHT=0
    green_msg "Rollback completed."
    return 0
}

# --- temporary bootstrap resolver ------------------------------------------

system_dns_works() {
    local h
    for h in $PROBE_NAMES; do
        dns_query_ok "$h" && return 0
    done
    return 1
}

bootstrap_dns_if_needed() {
    [ "$OPT_NO_BOOTSTRAP" = "1" ] && return 0

    if system_dns_works; then
        return 0
    fi

    ORIG_DNS_BROKEN=1
    yellow_msg "Name resolution is currently broken - installing a temporary resolver so packages can be fetched."

    local cands="" l
    if [ -n "$OPT_DNS_V4" ]; then
        cands="$OPT_DNS_V4"
    elif [ -n "$OPT_DNS_CHOICE" ]; then
        l=$(get_dns_list "$OPT_DNS_CHOICE")
        l="${l%%|*}"
        [ "$l" != "custom" ] && cands="$l"
    fi
    cands=$(dedup_list "$cands 1.1.1.1 8.8.8.8 9.9.9.9")
    BS_LIST="$cands"

    bootstrap_dns_apply || return 0

    if system_dns_works; then
        green_msg "Temporary resolver is working."
    else
        yellow_msg "The temporary resolver did not help; restoring the original state."
        bootstrap_dns_revert
    fi
    return 0
}

bootstrap_dns_apply() {
    resolvconf_writable || return 1

    if [ -L /etc/resolv.conf ]; then
        BS_WAS_SYMLINK=1
        BS_SYMLINK_TARGET=$(readlink /etc/resolv.conf)
    fi
    BS_BAK="/etc/resolv.conf.pre-bootstrap.$TS"
    if [ -e /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "$BS_BAK" 2>/dev/null || true
    fi

    local tmp="/etc/.resolv.conf.bootstrap.$$" ns n=0
    {
        printf '# Temporary resolver installed by Linux-Optimizer (%s)\n' "$TS"
        for ns in $BS_LIST; do
            n=$((n + 1))
            [ "$n" -gt "$MAXNS" ] && break
            printf 'nameserver %s\n' "$ns"
        done
        resolv_extra_directives "$BS_BAK"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    chmod 644 "$tmp"
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    mv -f "$tmp" /etc/resolv.conf || { rm -f "$tmp"; return 1; }
    BS_APPLIED=1
    return 0
}

bootstrap_dns_revert() {
    [ "$BS_APPLIED" = "1" ] || return 0
    if [ "$BS_WAS_SYMLINK" = "1" ] && [ -n "$BS_SYMLINK_TARGET" ]; then
        rm -f /etc/resolv.conf
        ln -s "$BS_SYMLINK_TARGET" /etc/resolv.conf
    elif [ -f "$BS_BAK" ]; then
        rm -f /etc/resolv.conf
        cp "$BS_BAK" /etc/resolv.conf
        chmod 644 /etc/resolv.conf
    fi
    BS_APPLIED=0
    return 0
}

bootstrap_dns_reapply() {
    [ -n "$BS_LIST" ] || return 1
    BS_APPLIED=0
    bootstrap_dns_apply || return 1
    if system_dns_works; then
        yellow_msg "The DNS stage failed, so the temporary public resolver was kept so the host stays reachable."
        return 0
    fi
    bootstrap_dns_revert
    return 1
}

# --- DNS driver -------------------------------------------------------------

fix_dns() {
    plain_msg ""
    yellow_msg "DNS configuration."

    init_ip_validator
    choose_dns || return 1
    parse_dns_choice || return 1

    if [ -n "$DNS_V6" ] && ! has_ipv6; then
        yellow_msg "No IPv6 connectivity detected - IPv6 DNS servers skipped."
        DNS_V6=""
    fi

    local ip
    for ip in $DNS_V4; do
        is_private_ipv4 "$ip" && \
            yellow_msg "Note: $ip is a private-range address; it only works if your provider routes it."
    done

    # Pre-flight BEFORE touching anything: drop servers that do not answer.
    local reachable wanted
    wanted=$(dedup_list "$DNS_V4 $DNS_V6")
    reachable=$(preflight_dns_servers "$wanted") || return 1

    if [ "$reachable" != "$wanted" ]; then
        DNS_V4=""; DNS_V6=""
        for ip in $reachable; do
            if valid_ip 4 "$ip"; then
                DNS_V4="${DNS_V4:+$DNS_V4 }$ip"
            elif valid_ip 6 "$ip"; then
                DNS_V6="${DNS_V6:+$DNS_V6 }$ip"
            fi
        done
        if [ -z "$DNS_V4" ]; then
            red_msg "No usable IPv4 DNS server left after pre-flight."
            return 1
        fi
        yellow_msg "Using only the reachable servers: $DNS_V4${DNS_V6:+ $DNS_V6}"
    fi

    METHOD=$(detect_dns_method)
    print_selection_summary
    green_msg "Active DNS manager: $METHOD"

    snapshot_resolvconf
    DNS_IN_FLIGHT=1

    local applied=0
    case "$METHOD" in
        systemd-resolved) apply_dns_systemd_resolved && applied=1 ;;
        networkmanager)   apply_dns_networkmanager   && applied=1 ;;
        resolvconf)       apply_dns_resolvconf       && applied=1 ;;
        *)                apply_dns_direct           && applied=1 ;;
    esac

    if [ "$applied" != "1" ]; then
        red_msg "Failed to apply the selected DNS configuration."
        rollback_dns
        return 1
    fi

    if verify_dns; then
        DNS_IN_FLIGHT=0
        prune_backups /etc 'resolv.conf.bak.*'
        prune_backups /etc 'resolv.conf.pre-bootstrap.*'
        prune_backups /etc/systemd/resolved.conf.d '99-linux-optimizer-dns.conf.bak.*'
        prune_backups /etc/netplan '99-linux-optimizer-dns.yaml.bak.*'
        return 0
    fi

    rollback_dns
    return 1
}

# ===========================================================================
# TIMEZONE
# ===========================================================================

TZ_SET=0

valid_tz() {
    local tz="$1"
    [ -n "$tz" ] || return 1
    case "$tz" in *..*|/*|*' '*) return 1 ;; esac
    [ -f "/usr/share/zoneinfo/$tz" ] && return 0
    LC_ALL=C timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz" && return 0
    return 1
}

set_tz_value() {
    local tz="$1"
    valid_tz "$tz" || { red_msg "Invalid timezone: $tz"; return 1; }

    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$tz" 2>/dev/null; then
        TZ_SET=1
        green_msg "Timezone set to $tz (timedatectl)"
        return 0
    fi

    # Container / no-systemd fallback
    if ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime 2>/dev/null; then
        printf '%s\n' "$tz" > /etc/timezone 2>/dev/null || true
        export TZ="$tz"
        systemctl try-restart rsyslog >/dev/null 2>&1 || systemctl try-restart syslog >/dev/null 2>&1 || true
        systemctl try-restart cron >/dev/null 2>&1 || systemctl try-restart crond >/dev/null 2>&1 || true
        TZ_SET=1
        green_msg "Timezone set to $tz (localtime symlink fallback)"
        return 0
    fi

    red_msg "Failed to set the timezone to $tz"
    return 1
}

detect_public_ip() {
    local src ip
    for src in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ipv4.ident.me" \
               "https://ifconfig.me/ip" "https://api.ip.sb/ip" "http://ip-api.com/line/?fields=query"; do
        ip=$(curl -s --max-time 7 "$src" 2>/dev/null | tr -d '[:space:]') || ip=""
        if valid_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
    done
    if command -v dig >/dev/null 2>&1; then
        ip=$(timeout 8 dig +short myip.opendns.com @resolver1.opendns.com +time=4 +tries=1 2>/dev/null | head -n 1 | tr -d '[:space:]') || ip=""
        valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
        ip=$(timeout 8 dig +short txt ch whoami.cloudflare @1.1.1.1 +time=4 +tries=1 2>/dev/null | tr -d '"[:space:]') || ip=""
        valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    fi
    return 1
}

geo_lookup() {
    local ip="$1" out tz cc
    if command -v jq >/dev/null 2>&1; then
        out=$(curl -s --max-time 8 "http://ip-api.com/json/$ip?fields=status,timezone,countryCode" 2>/dev/null) || out=""
        tz=$(printf '%s' "$out" | jq -r 'select(.status=="success") | .timezone // empty' 2>/dev/null) || tz=""
        cc=$(printf '%s' "$out" | jq -r '.countryCode // empty' 2>/dev/null) || cc=""
        [ -n "$tz" ] && { printf '%s %s' "$tz" "$cc"; return 0; }

        out=$(curl -s --max-time 8 "https://ipinfo.io/$ip/json" 2>/dev/null) || out=""
        tz=$(printf '%s' "$out" | jq -r '.timezone // empty' 2>/dev/null) || tz=""
        cc=$(printf '%s' "$out" | jq -r '.country // empty' 2>/dev/null) || cc=""
        [ -n "$tz" ] && { printf '%s %s' "$tz" "$cc"; return 0; }

        out=$(curl -s --max-time 8 "https://ipapi.co/$ip/json/" 2>/dev/null) || out=""
        tz=$(printf '%s' "$out" | jq -r '.timezone // empty' 2>/dev/null) || tz=""
        cc=$(printf '%s' "$out" | jq -r '.country_code // empty' 2>/dev/null) || cc=""
        [ -n "$tz" ] && { printf '%s %s' "$tz" "$cc"; return 0; }
    else
        out=$(curl -s --max-time 8 "http://ip-api.com/line/$ip?fields=timezone,countryCode" 2>/dev/null | tr -d '\r') || out=""
        tz=$(printf '%s\n' "$out" | sed -n 1p)
        cc=$(printf '%s\n' "$out" | sed -n 2p)
        [ -n "$tz" ] && { printf '%s %s' "$tz" "$cc"; return 0; }
    fi
    return 1
}

country_fallback_tz() {
    case "$1" in
        IR) printf '%s' "Asia/Tehran" ;;      DE) printf '%s' "Europe/Berlin" ;;
        NL) printf '%s' "Europe/Amsterdam" ;; GB|UK) printf '%s' "Europe/London" ;;
        FR) printf '%s' "Europe/Paris" ;;     US) printf '%s' "America/New_York" ;;
        CA) printf '%s' "America/Toronto" ;;  TR) printf '%s' "Europe/Istanbul" ;;
        RU) printf '%s' "Europe/Moscow" ;;    AE) printf '%s' "Asia/Dubai" ;;
        IN) printf '%s' "Asia/Kolkata" ;;     SG) printf '%s' "Asia/Singapore" ;;
        JP) printf '%s' "Asia/Tokyo" ;;       CN) printf '%s' "Asia/Shanghai" ;;
        PL) printf '%s' "Europe/Warsaw" ;;    SE) printf '%s' "Europe/Stockholm" ;;
        FI) printf '%s' "Europe/Helsinki" ;;  AT) printf '%s' "Europe/Vienna" ;;
        CH) printf '%s' "Europe/Zurich" ;;    IT) printf '%s' "Europe/Rome" ;;
        ES) printf '%s' "Europe/Madrid" ;;    *)  printf '%s' "" ;;
    esac
}

set_timezone() {
    plain_msg ""
    yellow_msg 'Setting the timezone...'

    if [ -n "$OPT_TIMEZONE" ]; then
        plain_msg "Requested timezone (--timezone): $OPT_TIMEZONE"
        set_tz_value "$OPT_TIMEZONE" && return 0
        return 1
    fi

    local ip geo tz cc fb current
    ip=$(detect_public_ip) || ip=""

    if [ -n "$ip" ]; then
        plain_msg "Public IP: $ip"
        geo=$(geo_lookup "$ip") || geo=""
        tz="${geo%% *}"
        cc="${geo##* }"
        [ -n "$cc" ] && plain_msg "Geo country: $cc"

        if [ -n "$tz" ] && valid_tz "$tz"; then
            set_tz_value "$tz" && return 0
        elif [ -n "$tz" ]; then
            yellow_msg "The provider returned an unknown zone '$tz'; trying the country fallback."
        fi

        fb=$(country_fallback_tz "$cc")
        if [ -n "$fb" ] && valid_tz "$fb"; then
            yellow_msg "Falling back to $fb for country $cc."
            set_tz_value "$fb" && return 0
        fi
    else
        red_msg "Could not detect the public IP (HTTP egress blocked?)."
    fi

    current=$(timedatectl show -p Timezone --value 2>/dev/null) || current=""
    [ -n "$current" ] || current=$(cat /etc/timezone 2>/dev/null) || current=""
    red_msg "Timezone auto-detect failed. Current timezone left unchanged: ${current:-unknown}"
    yellow_msg "Set it manually with: timedatectl set-timezone Asia/Tehran   (or --timezone=Asia/Tehran)"
    return 1
}

# ===========================================================================
# OS detection
# ===========================================================================

detect_os() {
    local id id_like
    OS="unknown"

    id=$(os_release_get ID) || id=""
    id_like=$(os_release_get ID_LIKE) || id_like=""
    OS_VERSION_ID=$(os_release_get VERSION_ID) || OS_VERSION_ID=""

    case "$id" in
        ubuntu)                   OS="ubuntu" ;;
        debian|raspbian)          OS="debian" ;;
        centos)                   OS="centos" ;;
        almalinux|rocky|rhel|ol)  OS="almalinux" ;;
        fedora)                   OS="fedora" ;;
        *)
            case "$id_like" in
                *ubuntu*)                   OS="ubuntu" ;;
                *debian*)                   OS="debian" ;;
                *rhel*|*fedora*|*centos*)   OS="centos" ;;
                *)                          OS="unknown" ;;
            esac
            ;;
    esac

    case "$OS" in
        ubuntu)    yellow_msg "Detected OS: Ubuntu ${OS_VERSION_ID:-(unknown version)}" ;;
        debian)    yellow_msg "Detected OS: Debian ${OS_VERSION_ID:-(unknown version)}" ;;
        centos)    yellow_msg "Detected OS: CentOS ${OS_VERSION_ID:-(unknown version)}" ;;
        almalinux) yellow_msg "Detected OS: AlmaLinux/RHEL-compatible ${OS_VERSION_ID:-(unknown version)}" ;;
        fedora)    yellow_msg "Detected OS: Fedora ${OS_VERSION_ID:-(unknown version)}" ;;
        *)         red_msg "Unsupported or unknown OS."; exit 78 ;;
    esac
    return 0
}

# ===========================================================================
# Distro optimizer
# ===========================================================================

prepare_sshd_runtime_dir() {
    # Some optimizer scripts restart sshd; on minimal images the privilege
    # separation directory can be missing, which makes sshd refuse to start.
    command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ] || return 0
    [ -d /run/sshd ] && return 0
    mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null
    return 0
}

run_optimizer_file() {
    local f="$1" rc=0
    prepare_sshd_runtime_dir
    chmod +x "$f" 2>/dev/null || true
    # 9>&- keeps the instance lock out of the child process.
    bash "$f" 9>&-
    rc=$?
    if [ "$rc" -ne 0 ]; then
        red_msg "The optimizer script exited with status $rc."
    else
        green_msg "Optimizer finished successfully."
    fi
    return "$rc"
}

optimizer_checksum_for_os() {
    case "$1" in
        ubuntu)    printf '%s' "$OPT_OPTIMIZER_SHA256_UBUNTU" ;;
        debian)    printf '%s' "$OPT_OPTIMIZER_SHA256_DEBIAN" ;;
        centos|almalinux) printf '%s' "$OPT_OPTIMIZER_SHA256_CENTOS" ;;
        fedora)    printf '%s' "$OPT_OPTIMIZER_SHA256_FEDORA" ;;
        *)         printf '%s' "" ;;
    esac
}

optimizer_url_for_os() {
    local base="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/${OPT_OPTIMIZER_REF}/scripts"
    case "$1" in
        ubuntu)           printf '%s/ubuntu-optimizer.sh' "$base" ;;
        debian)           printf '%s/debian-optimizer.sh' "$base" ;;
        centos|almalinux) printf '%s/centos-optimizer.sh' "$base" ;;
        fedora)           printf '%s/fedora-optimizer.sh' "$base" ;;
        *)                printf '%s' "" ;;
    esac
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
        return 0
    fi
    return 1
}

run_distro_optimizer() {
    if [ "$OPT_NO_OPTIMIZER" = "1" ]; then
        yellow_msg "Skipping the distro optimizer (--no-optimizer)."
        return 0
    fi

    plain_msg ""
    local candidate

    # 1) A local script is only trusted from a root-owned, non-world-writable
    #    directory - otherwise a planted ./optimizer.sh in /tmp would run as root.
    for candidate in "./optimizer.sh" "./${OS}-optimizer.sh"; do
        if [ ! -f "$candidate" ] || [ ! -s "$candidate" ]; then
            continue
        fi
        if path_is_safe "$candidate"; then
            green_msg "Found a local optimizer script ($candidate). Executing..."
            run_optimizer_file "$candidate"
            return $?
        fi
        red_msg "Ignoring $candidate: it or its directory is not root-owned, or is group/world-writable."
    done

    # 2) Download into a private temporary directory.
    local url sha256 name file got
    url="${OPT_OPTIMIZER_URL:-$(optimizer_url_for_os "$OS")}"
    sha256="${OPT_OPTIMIZER_SHA256:-$(optimizer_checksum_for_os "$OS")}"

    if [ -z "$url" ]; then
        red_msg "No optimizer URL is known for OS '$OS'."
        return 1
    fi

    TMP_WORKDIR=$(mktemp -d /tmp/linux-optimizer.XXXXXXXX) || {
        red_msg "Could not create a temporary directory."
        return 1
    }
    chmod 700 "$TMP_WORKDIR"
    name="${url##*/}"
    case "$name" in *.sh) ;; *) name="optimizer.sh" ;; esac
    file="$TMP_WORKDIR/$name"

    yellow_msg "Downloading the optimizer script..."
    yellow_msg "Source: $url"
    if ! curl -fsSL --max-time 60 "$url" -o "$file" 2>/dev/null; then
        if ! wget -q --timeout=60 "$url" -O "$file" 2>/dev/null; then
            red_msg "Download failed: $url"
            red_msg "Place your optimizer.sh next to this launcher (root-owned directory) and re-run."
            return 1
        fi
    fi
    [ -s "$file" ] || { red_msg "The downloaded file is empty."; return 1; }

    if [ -n "$sha256" ]; then
        if ! got=$(file_sha256 "$file"); then
            red_msg "Neither sha256sum nor shasum is available; refusing to run an unverified script."
            return 1
        fi
        if [ "$got" != "$sha256" ]; then
            red_msg "Checksum mismatch: expected $sha256, got $got. Aborting."
            return 1
        fi
        green_msg "Checksum verified."
    else
        yellow_msg "No checksum is pinned for this OS."
        if [ "$OPT_PIN_SHA256" = "1" ]; then
            red_msg "--pin-checksum was requested but no checksum is pinned: refusing to run the downloaded script."
            return 1
        fi
        if [ "$OPT_ASSUME_YES" = "1" ]; then
            if [ "$OPT_ALLOW_UNVERIFIED" != "1" ]; then
                red_msg "Non-interactive runs require a pinned checksum."
                red_msg "Set OPT_OPTIMIZER_SHA256[_${OS^^}] (together with --optimizer-ref=<commit>), or pass --allow-unverified."
                return 1
            fi
            yellow_msg "--allow-unverified: running an unverified remote script as root."
        else
            yellow_msg "The script was saved to $file - review it in another shell if you want to."
            if ! confirm "[*] Continue and run this downloaded script as root? [y/N]: "; then
                red_msg "Aborted by the user."
                return 1
            fi
        fi
    fi

    run_optimizer_file "$file"
    return $?
}

# ===========================================================================
# MAIN
# ===========================================================================

main() {
    detect_os

    # DNS must be usable BEFORE the package manager runs, otherwise the very
    # hosts this script exists to repair can never install their dependencies.
    bootstrap_dns_if_needed

    case "$OS" in
        ubuntu|debian)              install_dependencies_debian_based ;;
        centos|fedora|almalinux)    install_dependencies_rhel_based ;;
    esac

    # Hand the original state back to the DNS stage so its snapshot is honest.
    bootstrap_dns_revert

    fix_etc_hosts || true

    if fix_dns; then
        green_msg "DNS stage completed."
    else
        EXIT_CODE=$((EXIT_CODE | 1))
        yellow_msg "The DNS step did not complete successfully (see the messages above)."
        if [ "$ORIG_DNS_BROKEN" = "1" ]; then
            bootstrap_dns_reapply || true
        fi
    fi

    if set_timezone; then
        :
    else
        EXIT_CODE=$((EXIT_CODE | 2))
        yellow_msg "The timezone step did not complete (left unchanged)."
    fi

    if run_distro_optimizer; then
        :
    else
        EXIT_CODE=$((EXIT_CODE | 4))
        yellow_msg "The distro optimizer step did not complete."
    fi

    plain_msg ""
    [ "$DEPS_OK" = "1" ] || yellow_msg "Note: some dependencies were missing, so parts of this run were degraded."
    [ "$TZ_SET" = "1" ] || yellow_msg "Note: the timezone was not changed by this run."
    if [ "$EXIT_CODE" -eq 0 ]; then
        green_msg "All stages completed successfully."
    else
        yellow_msg "Finished with exit code $EXIT_CODE (1=DNS, 2=timezone, 4=optimizer)."
    fi
    return "$EXIT_CODE"
}

main "$@"
exit "$EXIT_CODE"
