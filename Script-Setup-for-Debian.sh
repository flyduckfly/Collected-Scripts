#!/usr/bin/env bash
# ======================================================
# Debian / Ubuntu VPS Configuration Script
# Improved stable version
# Compatible with Debian 12 / Ubuntu 22.x / most systemd VPS
# ======================================================

set -u
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

BASHRC="/root/.bashrc"
DIRCOLORS="/root/.dircolors"
TIMEZONE="Asia/Shanghai"
HOSTS_FILE="/etc/hosts"
RESOLV_FILE="/etc/resolv.conf"
VIRTIO_BALLOON_BLACKLIST="/etc/modprobe.d/blacklist-virtio-balloon.conf"
GITHUB_RAW_PROXY_PREFIX="https://gh-proxy.com/"

TZ_CHANGED="No"
COLOR_LS="Unknown"
TERM_COLOR="Unknown"
DIRCOLOR_FILE="Unknown"
DIRCOLOR_APPLY="Unknown"
DNS_MODE_DESC="Unknown"
DNS_TEST_RESULT="Unknown"
HOSTNAME_CHANGED="No"
REGION="International"
PUBLIC_IP="Unknown"
COUNTRY_ISO="UNKNOWN"
NEW_DNS1=""
NEW_DNS2=""
GITHUB_RAW_MODE="Direct"

# ------------------------------------------------------
# Logging helpers
# ------------------------------------------------------
log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

# ------------------------------------------------------
# Ensure running as root
# ------------------------------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ------------------------------------------------------
# Safe wrapper for commands
# ------------------------------------------------------
S() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# ------------------------------------------------------
# Helpers
# ------------------------------------------------------
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local input

    if ! is_interactive; then
        [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
    fi

    if [[ "$default" =~ ^[Yy]$ ]]; then
        read -r -p "$prompt [Y/n]: " input
        input="${input:-y}"
    else
        read -r -p "$prompt [y/N]: " input
        input="${input:-n}"
    fi

    input="${input,,}"
    [[ "$input" == "y" || "$input" == "yes" ]]
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

safe_chattr_remove_immutable() {
    local file="$1"
    if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1 && [[ -e "$file" ]]; then
        if lsattr "$file" 2>/dev/null | grep -q 'i'; then
            chattr -i "$file" 2>/dev/null || true
        fi
    fi
}

safe_chattr_add_immutable() {
    local file="$1"
    if command -v chattr >/dev/null 2>&1 && [[ -e "$file" ]]; then
        chattr +i "$file" 2>/dev/null || true
    fi
}

is_pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

apt_install_missing() {
    local missing=()
    local pkg

    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            log "Package already installed: $pkg"
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log "All requested packages are already installed. Skipping apt install."
        return 0
    fi

    log "Installing missing packages: ${missing[*]}"
    S apt-get update -y || return 1
    S apt-get install -y "${missing[@]}"
}

apt_purge_installed() {
    local installed=()
    local pkg

    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            installed+=("$pkg")
        else
            log "Package not installed, skipping purge: $pkg"
        fi
    done

    if (( ${#installed[@]} == 0 )); then
        log "No installed packages need to be purged."
        return 0
    fi

    log "Purging installed packages: ${installed[*]}"
    S apt-get purge -y "${installed[@]}" || true
    S apt-get autoremove -y || true
}

blacklist_virtio_balloon() {
    local module="virtio_balloon"

    if [[ -f "$VIRTIO_BALLOON_BLACKLIST" ]] && grep -qE "^[[:space:]]*blacklist[[:space:]]+$module" "$VIRTIO_BALLOON_BLACKLIST"; then
        log "$module is already blacklisted."
    else
        log "Adding blacklist for $module..."
        cat > "$VIRTIO_BALLOON_BLACKLIST" <<EOF
# Disable virtio balloon memory driver
blacklist virtio_balloon
EOF
        log "Blacklist written to $VIRTIO_BALLOON_BLACKLIST."
    fi

    if lsmod | awk '{print $1}' | grep -qx "$module"; then
        log "$module module is currently loaded. Trying to remove it..."
        if rmmod "$module" 2>/dev/null; then
            log "$module module removed."
        else
            warn "Failed to remove $module. It may be in use. Blacklist will take effect after reboot."
        fi
    else
        log "$module module is not loaded. Skipping rmmod."
    fi
}

detect_physical_memory_mb() {
    local mem_kb mem_mb

    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || (( mem_kb <= 0 )); then
        err "Failed to detect physical memory from /proc/meminfo."
        exit 1
    fi

    # Round up to a whole MB so the swapfile is at least as large as detected RAM.
    mem_mb=$(( (mem_kb + 1023) / 1024 ))
    echo "$mem_mb"
}

swapfile_active() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"
}

swapfile_size_mb() {
    if [[ -f /swapfile ]]; then
        stat -c '%s' /swapfile 2>/dev/null | awk '{printf "%d", $1/1024/1024}'
    else
        echo 0
    fi
}

active_non_swapfile_swap() {
    swapon --show=NAME --noheadings 2>/dev/null | awk '$1 != "/swapfile" {print}' || true
}

fstab_non_swapfile_swap() {
    if [[ -f /etc/fstab ]]; then
        awk 'NF > 0 && $1 !~ /^#/ && $3 == "swap" && $1 != "/swapfile" {print}' /etc/fstab 2>/dev/null || true
    fi
}

ensure_swap_fstab_entry() {
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

    # Keep exactly one standard /swapfile entry to avoid duplicate fstab rows.
    sed -i '/^[[:space:]]*\/swapfile[[:space:]].*[[:space:]]swap[[:space:]]/d' /etc/fstab
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Ensured a single standard /swapfile entry in /etc/fstab."
}

bashrc_has_ls_color() {
    grep -Eq "^[[:space:]]*alias[[:space:]]+ls=['\"]?ls[[:space:]]+--color=auto['\"]?" "$BASHRC" 2>/dev/null
}

bashrc_has_term_color() {
    grep -Eq "^[[:space:]]*export[[:space:]]+TERM=['\"]?xterm-256color['\"]?" "$BASHRC" 2>/dev/null
}

bashrc_has_dircolors_apply() {
    grep -Eq "dircolors[[:space:]]+-b[[:space:]]+.*\.dircolors" "$BASHRC" 2>/dev/null
}

dns_already_configured() {
    [[ -f "$RESOLV_FILE" ]] || return 1
    grep -qE "^[[:space:]]*nameserver[[:space:]]+${NEW_DNS1}[[:space:]]*$" "$RESOLV_FILE" &&
    grep -qE "^[[:space:]]*nameserver[[:space:]]+${NEW_DNS2}[[:space:]]*$" "$RESOLV_FILE"
}

detect_region() {
    local iso ip_info iso_line

    ip_info="$(curl -fsS --max-time 5 https://ipapi.co/json 2>/dev/null || true)"
    iso="$(echo "$ip_info" | jq -r '.country // empty' 2>/dev/null || true)"
    if [[ -n "$iso" && "$iso" != "null" ]]; then
        echo "$iso"
        return 0
    fi

    ip_info="$(curl -fsS --max-time 5 https://ipinfo.io/json 2>/dev/null || true)"
    iso="$(echo "$ip_info" | jq -r '.country // empty' 2>/dev/null || true)"
    if [[ -n "$iso" && "$iso" != "null" ]]; then
        echo "$iso"
        return 0
    fi

    iso_line="$(curl -fsS --max-time 5 https://cip.cc 2>/dev/null | grep '国家' | awk -F ':' '{print $2}' | xargs || true)"
    if echo "$iso_line" | grep -q "中国"; then
        echo "CN"
        return 0
    fi

    echo "UNKNOWN"
}

github_raw_url() {
    local url="$1"

    if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
        if [[ "$REGION" == "China" ]]; then
            echo "${GITHUB_RAW_PROXY_PREFIX}${url}"
        else
            echo "$url"
        fi
    else
        echo "$url"
    fi
}

curl_github_raw_to_stdout() {
    local url="$1"
    local final_url

    final_url="$(github_raw_url "$url")"
    log "Downloading: $final_url" >&2
    curl -fsSL "$final_url"
}

curl_github_raw_to_file() {
    local url="$1"
    local output_file="$2"
    local final_url

    final_url="$(github_raw_url "$url")"
    log "Downloading: $final_url"
    curl -fsSL "$final_url" -o "$output_file"
}

# ------------------------------------------------------
# Start
# ------------------------------------------------------
log "=== Starting Debian/Ubuntu system configuration... ==="

apt_install_missing sudo curl wget unzip dnsutils tree net-tools cron jq nano htop ca-certificates lsb-release iperf3 2>/dev/null \
    || warn "Some base packages failed to install, continuing..."

# ------------------------------------------------------
# [0/6] Detect region by public IP
# Must run before any raw.githubusercontent.com download
# ------------------------------------------------------
log "[0/6] Detecting region based on public IP..."

PUBLIC_IP="$(curl -fsS --max-time 5 https://ipinfo.io/ip 2>/dev/null || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "Unknown")"
COUNTRY_ISO="$(detect_region)"

if [[ "$COUNTRY_ISO" == "CN" ]]; then
    REGION="China"
    GITHUB_RAW_MODE="gh-proxy.com"
else
    REGION="International"
    GITHUB_RAW_MODE="Direct"
    [[ "$COUNTRY_ISO" == "UNKNOWN" ]] && warn "Failed to detect region automatically. Defaulting to International."
fi

log "Detected Public IP: ${PUBLIC_IP}"
log "Detected Country ISO: ${COUNTRY_ISO}"
log "Assigned Region: ${REGION}"
log "GitHub Raw Download Mode: ${GITHUB_RAW_MODE}"

apt_purge_installed lrzsz

blacklist_virtio_balloon

curl_github_raw_to_stdout "https://raw.githubusercontent.com/uselibrary/memoryCheck/main/memoryCheck.sh" | bash

# hash is shell builtin; do not run through sudo
hash -r 2>/dev/null || true

# ------------------------------------------------------
# tcping install / check
# ------------------------------------------------------
log "Checking tcping..."

install_tcping() {
    if command -v tcping >/dev/null 2>&1; then
        log "tcping is already installed."
        return 0
    fi

    if apt-cache search '^tcping$' 2>/dev/null | grep -q '^tcping'; then
        log "Installing tcping from apt..."
        S apt-get install -y tcping && command -v tcping >/dev/null 2>&1 && return 0
    fi

    log "tcping not found. Trying remote installer..."
    local tmp_script
    tmp_script="$(mktemp /tmp/tcping_install.XXXXXX.sh)" || return 1

    if curl_github_raw_to_file "https://raw.githubusercontent.com/nodeseeker/tcping/main/install_cn.sh" "$tmp_script"; then
        chmod +x "$tmp_script"
        bash "$tmp_script" --force || true
        rm -f "$tmp_script"
        hash -r 2>/dev/null || true
        command -v tcping >/dev/null 2>&1 && return 0
    else
        rm -f "$tmp_script" 2>/dev/null || true
    fi

    return 1
}

if install_tcping; then
    log "tcping installation/check passed."
    if command -v tcping >/dev/null 2>&1; then
        tcping -4 --count 3 1.1.1.1 80 >/dev/null 2>&1 || warn "tcping test failed, but script will continue."
    fi
else
    warn "tcping installation failed. Skipping tcping test."
fi

# ------------------------------------------------------
# [1/6] Set timezone + NTP
# ------------------------------------------------------
log "[1/6] Setting timezone..."

CURRENT_TZ=""
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
fi

if [[ -n "$CURRENT_TZ" && "$CURRENT_TZ" != "$TIMEZONE" ]]; then
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
            TZ_CHANGED="Yes"
            log "Timezone set to $TIMEZONE."
        else
            warn "Failed to set timezone via timedatectl."
        fi
    fi
elif [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
    log "Timezone already set to $TIMEZONE."
else
    warn "Could not detect current timezone. Skipping timezone change."
fi

if has_systemd; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        log "Enabled systemd-timesyncd."
    else
        if ! dpkg -s chrony >/dev/null 2>&1; then
            mkdir -p /var/log/chrony
            S apt-get install -y chrony || warn "chrony installation failed."
        fi

        systemctl enable --now chrony >/dev/null 2>&1 || true
        log "Enabled chrony."

        if command -v systemctl >/dev/null 2>&1; then
            systemctl status chrony --no-pager || true
        fi

        if command -v chronyc >/dev/null 2>&1; then
            chronyc tracking || true
        else
            warn "chronyc command not found. Skipping chrony tracking check."
        fi
    fi
else
    warn "systemd not detected; skipping NTP service management."
fi

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl 2>/dev/null || true
fi

# ===========================================================
# SWAP section
# ===========================================================
log "====== Checking current swap status ======"
free -h || true
swapon --show || true
echo

CREATE_SWAP="n"
if ask_yes_no "Do you want to create a swapfile?" "n"; then
    CREATE_SWAP="y"
fi

if [[ "$CREATE_SWAP" != "y" ]]; then
    log "Skipping swapfile creation."
    swapon --show || true
    echo
else
    REQUIRED_MB="$(detect_physical_memory_mb)"
    SWAP_SIZE="${REQUIRED_MB}M"
    log "User selected: create swapfile. Detected RAM: ${REQUIRED_MB} MB. Target swapfile size: ${SWAP_SIZE}."

    ACTIVE_OTHER_SWAP="$(active_non_swapfile_swap)"
    if [[ -n "$ACTIVE_OTHER_SWAP" ]]; then
        warn "Detected active swap that is not /swapfile:"
        echo "$ACTIVE_OTHER_SWAP"
        warn "Skipping /swapfile creation to avoid duplicate swap configuration."
        swapon --show || true
        echo
    else
        FSTAB_OTHER_SWAP="$(fstab_non_swapfile_swap)"
        if [[ -n "$FSTAB_OTHER_SWAP" ]]; then
            warn "Detected non-/swapfile swap entry in /etc/fstab:"
            echo "$FSTAB_OTHER_SWAP"
            warn "Skipping /swapfile creation to avoid conflicting persistent swap configuration."
            swapon --show || true
            echo
        else
            CURRENT_SWAP_MB="$(swapfile_size_mb)"

            if [[ -f /swapfile ]] && swapfile_active && (( CURRENT_SWAP_MB >= REQUIRED_MB )); then
                log "Existing /swapfile is active and size is sufficient (${CURRENT_SWAP_MB} MB >= ${REQUIRED_MB} MB). Keeping it."
                log "Repairing /etc/fstab entry for /swapfile if needed..."
                ensure_swap_fstab_entry
                swapon --show || true
                free -h || true
                echo
            else
                if [[ -f /swapfile ]]; then
                    log "Existing /swapfile detected but not active or size is insufficient (${CURRENT_SWAP_MB} MB < ${REQUIRED_MB} MB). Recreating..."
                    swapoff /swapfile 2>/dev/null || true
                    rm -f /swapfile || true
                fi

                log "Checking disk free space..."
                AVAILABLE_KB="$(df --output=avail / | tail -1 | tr -d ' ' 2>/dev/null || echo 0)"
                AVAILABLE_MB=$((AVAILABLE_KB / 1024))

                # Keep a small safety margin so the root filesystem is not filled completely.
                RESERVED_MB=512

                log "Available space: ${AVAILABLE_MB} MB"
                log "Required swap size: ${REQUIRED_MB} MB"
                log "Reserved free space: ${RESERVED_MB} MB"

                if (( AVAILABLE_MB < REQUIRED_MB + RESERVED_MB )); then
                    err "Not enough disk space for swapfile. Need at least $((REQUIRED_MB + RESERVED_MB)) MB free."
                    exit 1
                fi

                log "Creating swapfile with size ${SWAP_SIZE}..."
                if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
                    warn "fallocate failed, falling back to dd..."
                    if ! dd if=/dev/zero of=/swapfile bs=1M count="$REQUIRED_MB" status=none; then
                        err "Failed to create swapfile."
                        exit 1
                    fi
                fi

                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile

                log "Swap enabled:"
                swapon --show || true
                free -h || true
                echo

                log "Configuring persistent swap..."
                ensure_swap_fstab_entry

                log "Swap setup complete."
                echo
            fi
        fi
    fi
fi

log "Swap configuration finished."

# ------------------------------------------------------
# [2/6] Colored ls output
# ------------------------------------------------------
log "[2/6] Configuring colored ls output..."
touch "$BASHRC"
if ! bashrc_has_ls_color; then
    echo "alias ls='ls --color=auto'" >> "$BASHRC"
    COLOR_LS="Enabled"
else
    COLOR_LS="Already enabled"
fi

# ------------------------------------------------------
# [3/6] 256-color terminal
# ------------------------------------------------------
log "[3/6] Configuring terminal colors..."
if ! bashrc_has_term_color; then
    echo "export TERM=xterm-256color" >> "$BASHRC"
    TERM_COLOR="Enabled"
else
    TERM_COLOR="Already enabled"
fi

# ------------------------------------------------------
# [4/6] dircolors
# ------------------------------------------------------
log "[4/6] Setting up dircolors..."
if [[ ! -f "$DIRCOLORS" ]]; then
    if command -v dircolors >/dev/null 2>&1; then
        dircolors -p > "$DIRCOLORS"
        DIRCOLOR_FILE="Created"
    else
        DIRCOLOR_FILE="Skipped (dircolors missing)"
    fi
else
    DIRCOLOR_FILE="Exists"
fi

if ! bashrc_has_dircolors_apply; then
    echo 'eval "$(dircolors -b ~/.dircolors)"' >> "$BASHRC"
    DIRCOLOR_APPLY="Enabled"
else
    DIRCOLOR_APPLY="Already enabled"
fi

# ------------------------------------------------------
# [5/6] DNS configuration (Static resolv.conf only)
# ------------------------------------------------------
log "[5/6] Updating DNS configuration based on region..."

if [[ "$REGION" == "China" ]]; then
    NEW_DNS1="223.5.5.5"
    NEW_DNS2="223.6.6.6"
    TEST_DOMAIN="www.baidu.com"
else
    NEW_DNS1="1.1.1.1"
    NEW_DNS2="1.0.0.1"
    TEST_DOMAIN="www.google.com"
fi

DNS_MODE_DESC="Static resolv.conf"
log "Using static resolv.conf mode only."

if dns_already_configured; then
    log "DNS already configured as expected. Skipping resolv.conf rewrite."
else
    safe_chattr_remove_immutable "$RESOLV_FILE"

    if has_systemd; then
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
    fi

    if [[ -L "$RESOLV_FILE" ]]; then
        rm -f "$RESOLV_FILE"
    fi

    if [[ -f "$RESOLV_FILE" ]]; then
        cp "$RESOLV_FILE" "${RESOLV_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi

    cat > "$RESOLV_FILE" <<EOF
nameserver $NEW_DNS1
nameserver $NEW_DNS2
EOF
fi

sleep 1

log "Testing DNS resolution for $TEST_DOMAIN..."
if command -v nslookup >/dev/null 2>&1; then
    if nslookup "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
elif command -v getent >/dev/null 2>&1; then
    if getent hosts "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
else
    if ping -c 1 -W 5 "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
fi

safe_chattr_add_immutable "$RESOLV_FILE"
log "DNS Test Result: $DNS_TEST_RESULT"

# ------------------------------------------------------
# [6/6] Hostname handling
# ------------------------------------------------------
log "[6/6] Detecting OS version..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$(echo "${ID:-vps}" | tr '[:upper:]' '[:lower:]')"
    OS_VERSION="$(echo "${VERSION_ID:-0}" | cut -d'.' -f1)"
    AUTO_HOSTNAME="${OS_NAME}${OS_VERSION}"
else
    AUTO_HOSTNAME="vps$(date +%Y%m%d)"
fi

CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"

echo
echo "Hostname Configuration"
echo "-------------------------------------------------------"
echo "Current hostname : $CURRENT_HOSTNAME"
echo "Suggested hostname: $AUTO_HOSTNAME"
echo

if ask_yes_no "Change hostname to '$AUTO_HOSTNAME'?" "n"; then
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$AUTO_HOSTNAME" 2>/dev/null || hostname "$AUTO_HOSTNAME"
    else
        hostname "$AUTO_HOSTNAME"
        echo "$AUTO_HOSTNAME" > /etc/hostname
    fi

    HOSTNAME_CHANGED="Yes ($CURRENT_HOSTNAME -> $AUTO_HOSTNAME)"

    safe_chattr_remove_immutable "$HOSTS_FILE"

    if grep -qE '^127\.0\.1\.1\s+' "$HOSTS_FILE" 2>/dev/null; then
        sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1        $AUTO_HOSTNAME/" "$HOSTS_FILE"
    else
        echo "127.0.1.1        $AUTO_HOSTNAME" >> "$HOSTS_FILE"
    fi

    safe_chattr_add_immutable "$HOSTS_FILE"
else
    HOSTNAME_CHANGED="No (kept: $CURRENT_HOSTNAME)"
    log "Hostname unchanged."
fi

# ------------------------------------------------------
# Enable BBR
# ------------------------------------------------------
log "Checking BBR status..."

current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"

if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    log "BBR and FQ are already enabled."
else
    log "Enabling BBR and FQ..."
    sed -i '/^net\.core\.default_qdisc=/d' /etc/sysctl.conf
    sed -i '/^net\.ipv4\.tcp_congestion_control=/d' /etc/sysctl.conf

    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >> /etc/sysctl.conf

    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

    new_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
    new_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"

    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "fq" ]]; then
        log "BBR and FQ have been successfully enabled."
    else
        warn "Failed to fully enable BBR. Kernel may not support it."
    fi
fi

# ------------------------------------------------------
# Summary
# ------------------------------------------------------
echo
echo "=== Configuration Summary ==="
echo "Region: $REGION"
echo "Public IP: $PUBLIC_IP"
echo "Country ISO: $COUNTRY_ISO"
echo "GitHub Raw Mode: $GITHUB_RAW_MODE"
echo "Timezone: $TIMEZONE (Changed: $TZ_CHANGED)"
echo "Hostname: $(hostname 2>/dev/null || echo unknown) (Changed: $HOSTNAME_CHANGED)"
echo "DNS Mode: $DNS_MODE_DESC"
echo "  Primary DNS: $NEW_DNS1"
echo "  Secondary DNS: $NEW_DNS2"
echo "  DNS Test: $DNS_TEST_RESULT"
echo "Colored ls: $COLOR_LS"
echo "256-color terminal: $TERM_COLOR"
echo "dircolors: $DIRCOLOR_FILE, Applied: $DIRCOLOR_APPLY"
echo

if ask_yes_no "Reboot now?" "n"; then
    reboot
else
    log "Reboot cancelled."
fi
