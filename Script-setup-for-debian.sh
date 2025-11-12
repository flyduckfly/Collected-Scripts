#!/bin/bash
# ======================================================
# Debian / Ubuntu VPS Configuration Script (Final Stable Version)
# Auto OS Version Detection + Safe File Lock Handling + Region DNS
# Fully compatible with Ubuntu 22.x / Debian 12
# ======================================================

BASHRC="$HOME/.bashrc"
DIRCOLORS="$HOME/.dircolors"
TIMEZONE="Asia/Shanghai"
HOSTS_FILE="/etc/hosts"
RESOLV_FILE="/etc/resolv.conf"
RESOLVED_CONF="/etc/systemd/resolved.conf"
SYSTEMD_RESOLV="/run/systemd/resolve/resolv.conf"

# ------------------------------------------------------
# Ensure running as root
# ------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

echo "=== Starting Debian/Ubuntu system configuration... ==="

apt update -y
apt install -y sudo curl wget unzip dnsutils net-tools cron jq

# ------------------------------------------------------
# [0/6] Detect region by public IP
# ------------------------------------------------------
echo "[0/6] Detecting region based on public IP..."

detect_region() {
    local COUNTRY IP_INFO
    IP_INFO=$(curl -s --max-time 5 https://ipapi.co/json)
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country_name')
    if [ -n "$COUNTRY" ] && [ "$COUNTRY" != "null" ]; then echo "$COUNTRY"; return; fi

    IP_INFO=$(curl -s --max-time 5 https://ipinfo.io/json)
    COUNTRY=$(echo "$IP_INFO" | jq -r '.country')
    if [ -n "$COUNTRY" ] && [ "$COUNTRY" != "null" ]; then
        if [ "$COUNTRY" = "CN" ]; then echo "China"; else echo "$COUNTRY"; fi
        return
    fi

    COUNTRY=$(curl -s --max-time 5 cip.cc | grep "µØÖ·" | awk -F : '{print $2}' | xargs)
    if echo "$COUNTRY" | grep -q "ÖÐ¹ú"; then echo "China"; return; fi

    echo "Unknown"
}

PUBLIC_IP=$(curl -s --max-time 5 https://ipinfo.io/ip || curl -s --max-time 5 https://api.ipify.org)
COUNTRY=$(detect_region)

if [ "$COUNTRY" = "China" ]; then
    REGION="China"
elif [ "$COUNTRY" = "Unknown" ]; then
    REGION="International"
    echo "Warning: Failed to detect region automatically. Defaulting to 'International'."
else
    REGION="International"
fi

echo "Detected Public IP: ${PUBLIC_IP:-Unknown}"
echo "Detected Country: ${COUNTRY:-Unknown}"
echo "Assigned Region: ${REGION}"

# ------------------------------------------------------
# [1/6] Set timezone
# ------------------------------------------------------
echo "[1/6] Setting timezone..."
CURRENT_TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
if [ "$CURRENT_TZ" != "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE"
    echo "Timezone set to $TIMEZONE."
    TZ_CHANGED="Yes"
else
    echo "Timezone already set to $TIMEZONE."
    TZ_CHANGED="No"
fi

# ------------------------------------------------------
# [2/6] Enable colored ls output
# ------------------------------------------------------
echo "[2/6] Configuring colored ls output..."
if ! grep -q "alias ls='ls --color=auto'" "$BASHRC"; then
    echo "alias ls='ls --color=auto'" >> "$BASHRC"
    COLOR_LS="Enabled"
else
    COLOR_LS="Already enabled"
fi

# ------------------------------------------------------
# [3/6] Enable 256-color terminal
# ------------------------------------------------------
echo "[3/6] Configuring terminal colors..."
if ! grep -q "export TERM=xterm-256color" "$BASHRC"; then
    echo "export TERM=xterm-256color" >> "$BASHRC"
    TERM_COLOR="Enabled"
else
    TERM_COLOR="Already enabled"
fi

# ------------------------------------------------------
# [4/6] Configure dircolors
# ------------------------------------------------------
echo "[4/6] Setting up dircolors..."
if [ ! -f "$DIRCOLORS" ]; then
    dircolors -p > "$DIRCOLORS"
    DIRCOLOR_FILE="Created"
else
    DIRCOLOR_FILE="Exists"
fi
if ! grep -q "dircolors" "$BASHRC"; then
    echo 'eval "$(dircolors -b ~/.dircolors)"' >> "$BASHRC"
    DIRCOLOR_APPLY="Enabled"
else
    DIRCOLOR_APPLY="Already enabled"
fi

# ------------------------------------------------------
# [5/6] Update DNS based on region
# ------------------------------------------------------
echo "[5/6] Updating DNS configuration based on region..."

if [ "$REGION" = "China" ]; then
    NEW_DNS1="223.5.5.5"
    NEW_DNS2="223.6.6.6"
    TEST_DOMAIN="baidu.com"
else
    NEW_DNS1="8.8.8.8"
    NEW_DNS2="8.8.4.4"
    TEST_DOMAIN="google.com"
fi

echo ""
echo "Select DNS configuration mode:"
echo "-----------------------------------"
echo "1) Use systemd-resolved (recommended for Ubuntu22/Debian12)"
echo "2) Use static resolv.conf (manual configuration)"
echo "-----------------------------------"
read -p "Enter choice [1-2]: " DNS_MODE

if lsattr "$RESOLV_FILE" 2>/dev/null | grep -q 'i'; then
    echo "Removing immutable flag from $RESOLV_FILE..."
    chattr -i "$RESOLV_FILE"
fi

if [ "$DNS_MODE" = "1" ]; then
    echo "Selected: systemd-resolved mode"

    if systemctl list-unit-files | grep -q "^systemd-resolved"; then
        systemctl enable systemd-resolved >/dev/null 2>&1
        systemctl start systemd-resolved 2>/dev/null || true

        cp "$RESOLVED_CONF" "${RESOLVED_CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sed -i '/^DNS=/d' "$RESOLVED_CONF" 2>/dev/null || true
        sed -i '/^FallbackDNS=/d' "$RESOLVED_CONF" 2>/dev/null || true
        if ! grep -q "^\[Resolve\]" "$RESOLVED_CONF"; then echo "[Resolve]" > "$RESOLVED_CONF"; fi
        sed -i '/^\[Resolve\]/a DNS='"$NEW_DNS1 $NEW_DNS2" "$RESOLVED_CONF"

        systemctl restart systemd-resolved 2>/dev/null || true
        rm -f "$RESOLV_FILE"
        ln -sf "$SYSTEMD_RESOLV" "$RESOLV_FILE"
        DNS_MODE_DESC="Systemd-resolved (symlink)"
    else
        DNS_MODE="2"
    fi
fi

if [ "$DNS_MODE" = "2" ]; then
    echo "Selected: static resolv.conf mode"
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    if [ -L "$RESOLV_FILE" ]; then rm -f "$RESOLV_FILE"; fi
    cat > "$RESOLV_FILE" <<EOF
nameserver $NEW_DNS1
nameserver $NEW_DNS2
EOF
    DNS_MODE_DESC="Static resolv.conf"
fi

if [ -L "$RESOLV_FILE" ]; then
    echo "/etc/resolv.conf is symbolic link, skipping chattr lock."
else
    chattr +i "$RESOLV_FILE" 2>/dev/null || true
fi

if ping -c1 -W3 "$TEST_DOMAIN" >/dev/null 2>&1; then
    DNS_TEST_RESULT="Success"
else
    DNS_TEST_RESULT="Failed"
fi

# ------------------------------------------------------
# [6/6] Auto-detect OS and set hostname
# ------------------------------------------------------
echo "[6/6] Detecting OS version and renaming hostname..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
    NEW_HOSTNAME="${OS_NAME}${OS_VERSION}"
else
    NEW_HOSTNAME="vps$(date +%Y%m%d)"
fi
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    HOSTNAME_CHANGED="Yes ($CURRENT_HOSTNAME -> $NEW_HOSTNAME)"
else
    HOSTNAME_CHANGED="No change ($CURRENT_HOSTNAME)"
fi

if lsattr "$HOSTS_FILE" 2>/dev/null | grep -q 'i'; then
    chattr -i "$HOSTS_FILE"
fi
if grep -qE "^127\.0\.1\.1\s+" "$HOSTS_FILE"; then
    sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1        $NEW_HOSTNAME/" "$HOSTS_FILE"
else
    echo "127.0.1.1        $NEW_HOSTNAME" >> "$HOSTS_FILE"
fi
chattr +i "$HOSTS_FILE"

# ------------------------------------------------------
# Summary
# ------------------------------------------------------
echo ""
echo "=== Configuration Summary ==="
echo "Region: $REGION"
echo "Timezone: $TIMEZONE (Changed: $TZ_CHANGED)"
echo "Hostname: $(hostname) (Changed: $HOSTNAME_CHANGED)"
echo "/etc/hosts updated: Yes"
echo "DNS Mode: $DNS_MODE_DESC"
echo "  Primary DNS: $NEW_DNS1"
echo "  Secondary DNS: $NEW_DNS2"
echo "  DNS Test: $DNS_TEST_RESULT"
echo "Colored ls: $COLOR_LS"
echo "256-color terminal: $TERM_COLOR"
echo "dircolors: $DIRCOLOR_FILE, Applied: $DIRCOLOR_APPLY"
echo ""
echo "Please run 'source ~/.bashrc' or reopen terminal to apply new color settings."
echo "System will reboot in 7 seconds (Ctrl+C to cancel)..."
sleep 7
reboot
