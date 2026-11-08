#!/bin/bash
#
# m17-hotspot-installer.sh - M17 Hotspot Installation Script for Raspberry Pi with CC1200, SX1255 or MMDVM HAT
#
# Authors: DK1MI <dk1mi@qrz.is>, N1ADJ, SP5WWP
# License: GNU General Public License v3.0 (GPLv3)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# ---------------- CONFIGURATION ----------------
REQUIRED_PACKAGES="git nginx php-fpm stm32flash jq"
BOOT_CONFIG_FILE="/boot/firmware/config.txt"
M17_HOME="/opt/m17"
M17_USER="m17"
NGINX_DEFAULT="/etc/nginx/sites-enabled/default"
CMDLINE_FILE="/boot/firmware/cmdline.txt"
HOSTFILE_URL="https://m17-project.github.io/hostfiles/M17Hosts.txt"
INSTALLER_URL="https://raw.githubusercontent.com/M17-Project/m17-hotspot-installer/main/m17-hotspot-installer.sh"
OVERLAYS_DIR="/boot/firmware/overlays"
I2S_OVERLAY_URL="https://github.com/M17-Project/RaspberryPi_I2S_Slave/raw/master/genericstereoaudiocodec.dtbo"
CC1200_FW_URL="https://github.com/M17-Project/CC1200_HAT-fw/releases/latest/download/CC1200_HAT-fw.bin"
HAT_PORT="/dev/ttyAMA0"
# ------------------------------------------------

set -e

update_hostfile() {
    echo "Now taking care of the M17 Hostfile..."

    FILES_DIR="$M17_HOME/rpi-dashboard/files"
    M17_HOSTS="$FILES_DIR/M17Hosts.txt"
    if [ ! -d "$FILES_DIR" ]; then
        mkdir -p "$FILES_DIR"
    fi
    chown "$M17_USER:www-data" $FILES_DIR
    chmod 775 $FILES_DIR

    echo "Downloading hostfile to $M17_HOSTS"
    /usr/bin/curl $HOSTFILE_URL -o $M17_HOSTS -z $M17_HOSTS -A "m17-hotspot-installer Hostfile Updater"

    echo "Setting ownership and permissions of $M17_HOSTS"
    if [ -f $M17_HOSTS ]; then
        chown "$M17_USER:www-data" $M17_HOSTS
        chmod 664 $M17_HOSTS
    fi
}

# Ask a yes/no question. $2 is the default, y or n, which is shown in capitals
# and picked by Enter. Without a terminal the answer is always no.
ask_yes_no() {
    local hint answer
    if [ "$2" = y ]; then hint="Y/n"; else hint="y/N"; fi
    [ -t 0 ] || return 1
    read -rp "$1 ($hint): " answer || return 1
    case "${answer:-$2}" in
        [yY]*) return 0 ;;
        *) return 1 ;;
    esac
}

# true if version $1 is newer than version $2 (dotted numbers)
version_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# Firmware versions, read from an ident string or a firmware file on stdin.
# The firmware files contain the same text the boards report.
#   CC1200:   "... FW v2.3 by ..."                      -> 2.3
cc1200_version() {
    grep -aoE 'FW v[0-9]+(\.[0-9]+)*' | head -n 1 | sed 's/^FW v//' || true
}
#   MMDVM_HS: "MMDVM_HS_Hat-v1.6.1 20251011 14.7456MHz" -> 1.6.1.20251011
mmdvm_hs_version() {
    grep -aoE -e '-v[0-9]+\.[0-9]+\.[0-9]+ [0-9]{8} [0-9.]+MHz' | head -n 1 |
        sed -E 's/^-v([0-9.]+) ([0-9]{8}).*/\1.\2/' || true
}
#   MMDVM:    "MMDVM 20251014 12.0000 MHz ..." or "MMDVM RB_STM32_DVM(446) 20251014 ..." -> 20251014
mmdvm_version() {
    grep -aoE 'MMDVM( [^ ]+)? 20[0-9]{6} ' | head -n 1 | grep -oE '20[0-9]{6}' || true
}
# The same versions, for people: 1.6.1.20251011 -> v1.6.1 20251011
mmdvm_hs_label() {
    if [ -n "$1" ]; then
        echo "$1" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]{8})$/v\1 \2/'
    fi
}

# Ask the HAT on $HAT_PORT what it is, before the user is asked. Sets
# DETECTED_TYPE (cc1200 or mmdvm) and DETECTED_IDENT, or leaves both empty.
# Needs m17-gateway stopped, as it holds the port. Only done once this
# installer has set up the UART: before that, the port may belong to the
# Bluetooth chip, which must not be sent anything.
probe_hat() {
    local out
    DETECTED_TYPE=""
    DETECTED_IDENT=""
    command -v python3 > /dev/null || return 0
    grep -q "^enable_uart=1" "$BOOT_CONFIG_FILE" || return 0
    grep -q "^dtoverlay=miniuart-bt" "$BOOT_CONFIG_FILE" || return 0
    [ -c "$HAT_PORT" ] || return 0

    out=$(timeout 15 python3 -c "$PROBE_PY" "$HAT_PORT" 2>/dev/null) || return 0
    case "$out" in
        cc1200$'\t'*|mmdvm$'\t'*)
            DETECTED_TYPE=${out%%$'\t'*}
            DETECTED_IDENT=${out#*$'\t'}
            ;;
    esac
}

# The serial probe used by probe_hat. It prints "cc1200<TAB>ident" or
# "mmdvm<TAB>ident" and exits 0, or exits 1 if nothing answered.
read -r -d '' PROBE_PY <<'EOF' || true
import os, select, sys, termios, time

port = sys.argv[1]

def ask(baud, request, seconds=0.5):
    # Send request at baud, return whatever comes back within seconds
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        a = termios.tcgetattr(fd)
        a[0] = a[1] = a[3] = 0                              # raw
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[4] = a[5] = baud
        a[6][termios.VMIN] = a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        time.sleep(0.05)
        termios.tcflush(fd, termios.TCIOFLUSH)
        os.write(fd, request)
        buf = b""
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                break
            if select.select([fd], [], [], left)[0]:
                try:
                    buf += os.read(fd, 4096)
                except BlockingIOError:
                    pass
        return buf
    finally:
        os.close(fd)

def text(b):
    b = b.split(b"\0")[0].strip()
    if len(b) >= 4 and all(32 <= c < 127 or c in (10, 13) for c in b):
        return b.decode()
    return None

def cc1200_ident(buf):
    # CMD_GET_IDENT reply: 0x80, total length (LE16), text
    i = buf.find(b"\x80")
    while i >= 0:
        if i + 3 <= len(buf):
            n = buf[i + 1] | buf[i + 2] << 8
            if 8 <= n <= 131 and i + n <= len(buf):
                t = text(buf[i + 3:i + n])
                if t:
                    return t
        i = buf.find(b"\x80", i + 1)
    return None

def mmdvm_ident(buf):
    # GetVersion reply: 0xE0, length, 0x00, protocol version, then the
    # description (protocol 1) or capabilities and UDID first (protocol 2)
    i = buf.find(b"\xe0")
    while i >= 0:
        if i + 4 <= len(buf):
            n = buf[i + 1]
            if buf[i + 2] == 0 and n >= 8 and i + n <= len(buf):
                frame = buf[i:i + n]
                desc = {1: frame[4:], 2: frame[23:]}.get(frame[3], b"")
                t = text(desc)
                if t:
                    return t
        i = buf.find(b"\xe0", i + 1)
    return None

try:
    # CC1200 HAT: stop RX streaming (CMD_RX_START 0) if it was left on,
    # then ask for the ident
    for attempt in range(2):
        ask(termios.B460800, b"\x08\x04\x00\x00", 0.1)
        t = cc1200_ident(ask(termios.B460800, b"\x80\x03\x00"))
        if t:
            print("cc1200\t" + t.replace("\r", "").replace("\n", " / "))
            sys.exit(0)
    # MMDVM: GetVersion, at both speeds MMDVM boards commonly use
    for baud in (termios.B115200, termios.B460800):
        t = mmdvm_ident(ask(baud, b"\xe0\x03\x00"))
        if t:
            print("mmdvm\t" + t)
            sys.exit(0)
except OSError:
    pass
sys.exit(1)
EOF

# Decide whether to flash: only when the file is newer than what the HAT runs,
# unless -f was given. $1 names the HAT, $2/$3 are the installed and available
# versions (comparable), $4/$5 the same for people. Returns 0 to flash.
offer_flash() {
    local what=$1 installed=$2 available=$3 installed_label=$4 available_label=$5
    if [ -z "$installed" ]; then
        echo "❔ Could not read the firmware version of the $what."
        ask_yes_no "💾 Flash the latest firmware${available_label:+ ($available_label)} anyway?" n
        return
    fi
    if [ -z "$available" ]; then
        echo "❔ The $what runs firmware $installed_label; the version of the latest firmware is unknown."
        ask_yes_no "💾 Flash the latest firmware anyway?" n
        return
    fi
    if version_newer "$available" "$installed"; then
        ask_yes_no "💾 Update the $what firmware from $installed_label to $available_label?" y
        return
    fi
    echo "✅ The $what firmware ($installed_label) is up to date."
    if [ "$force" = y ]; then
        ask_yes_no "💾 Flash firmware $available_label anyway (-f)?" y
        return
    fi
    return 1
}

flash_file() {
    echo "⚡ Flashing $(basename "$1") to the HAT..."
    if ! stm32flash -v -R -i "-532&-533&532,533,:-532,-533,533" -w "$1" "$HAT_PORT"; then
        echo "⚠️  Flashing failed. Run this installer again to retry."
    fi
}

update_cc1200_firmware() {
    local fw_file="/tmp/CC1200_HAT-fw.bin" installed="" available
    [ "$DETECTED_TYPE" = cc1200 ] && installed=$(printf '%s' "$DETECTED_IDENT" | cc1200_version)

    # The binary is not kept in the git repository; CI builds it and
    # attaches it to each tagged release
    echo "📥 Downloading the latest CC1200 HAT firmware..."
    rm -f "$fw_file"
    if ! curl -fsSL --max-time 60 -o "$fw_file" "$CC1200_FW_URL" ||
       [ "$(stat -c %s "$fw_file" 2>/dev/null || echo 0)" -lt 4096 ]; then
        echo "⚠️  Could not download the CC1200 firmware, skipping flashing."
        rm -f "$fw_file"
        return 0
    fi
    available=$(cc1200_version < "$fw_file")

    if offer_flash "CC1200 HAT" "$installed" "$available" "${installed:+v$installed}" "${available:+v$available}"; then
        flash_file "$fw_file"
    fi
    rm -f "$fw_file"
}

# Let the user pick an MMDVM firmware file. $1 is hs, rpt or empty for all.
# Prints the chosen path relative to $M17_HOME; the menu goes to stderr.
choose_mmdvm_bin() {
    local bins=() choice i
    local hs=(MMDVM_HS/release/MMDVM_HS_Hat.bin MMDVM_HS/release/MMDVM_HS_Dual_Hat.bin
              MMDVM_HS/release/generic_gpio.bin MMDVM_HS/release/generic_duplex_gpio.bin)
    local rpt=(MMDVM/release/Repeater-Builder_v3.bin MMDVM/release/Repeater-Builder_v4.bin
               MMDVM/release/Repeater-Builder_v5.bin)
    case "$1" in
        hs) bins=("${hs[@]}") ;;
        rpt) bins=("${rpt[@]}") ;;
        *) bins=("${hs[@]}" "${rpt[@]}") ;;
    esac
    echo "Please select your MMDVM board:" >&2
    for i in "${!bins[@]}"; do
        echo "$((i + 1))) $(basename "${bins[$i]}" .bin)" >&2
    done
    while :; do
        read -rp "Enter your choice (1-${#bins[@]}): " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#bins[@]}" ]; then
            echo "${bins[$((choice - 1))]}"
            return 0
        fi
        echo "Invalid choice." >&2
    done
}

update_mmdvm_firmware() {
    local ident="" family="" bin="" ref="" installed="" available="" installed_label available_label board tcxo
    [ "$DETECTED_TYPE" = mmdvm ] && ident=$DETECTED_IDENT

    if [ -n "$(printf '%s' "$ident" | mmdvm_hs_version)" ]; then
        family=hs
        installed=$(printf '%s' "$ident" | mmdvm_hs_version)
        # The two HATs name themselves and their clock, so the file is known
        board=$(printf '%s' "$ident" | sed -nE 's/^([A-Za-z0-9_]+)-v[0-9].*/\1/p')
        tcxo=$(printf '%s' "$ident" | grep -oE '[0-9.]+MHz' | head -n 1)
        case "$board" in
            MMDVM_HS_Hat|MMDVM_HS_Dual_Hat)
                if [ "$tcxo" = 12.2880MHz ]; then
                    bin="MMDVM_HS/release/$board-12mhz.bin"
                else
                    bin="MMDVM_HS/release/$board.bin"
                fi
                [ -f "$M17_HOME/$bin" ] || bin=""
                ;;
        esac
        ref=${bin:-MMDVM_HS/release/MMDVM_HS_Hat.bin}
        available=$(mmdvm_hs_version < "$M17_HOME/$ref" 2>/dev/null) || available=""
        installed_label=$(mmdvm_hs_label "$installed")
        available_label=$(mmdvm_hs_label "$available")
    elif [ -n "$(printf '%s' "$ident" | mmdvm_version)" ]; then
        # Repeater boards don't name the board, only the firmware date
        family=rpt
        installed=$(printf '%s' "$ident" | mmdvm_version)
        available=$(mmdvm_version < "$M17_HOME/MMDVM/release/Repeater-Builder_v5.bin" 2>/dev/null) || available=""
        installed_label=$installed
        available_label=$available
    fi

    offer_flash "MMDVM HAT" "$installed" "$available" "$installed_label" "$available_label" || return 0
    if [ -z "$bin" ]; then
        bin=$(choose_mmdvm_bin "$family") || return 0
    else
        echo "📟 Board: $board, $tcxo -> $(basename "$bin")"
    fi
    flash_file "$M17_HOME/$bin"
}

# Restart m17-gateway if this installer stopped it, also when it stops early
restart_gateway() {
    if [ "$restart" = true ]; then
        restart=false
        echo "Restarting m17-gateway service"
        systemctl start m17-gateway.service || true
    fi
}

usage() {
    echo "Usage: sudo $0 [-n] [-f] [-u]"
    echo "  -n  don't flash the HAT firmware"
    echo "  -f  offer to flash the HAT firmware even if it is up to date"
    echo "  -u  don't check for a newer version of this installer"
}

# Offer to switch to the latest installer from GitHub, so a re-run always
# sets up everything the current dashboard and gateway need. Any problem
# (no network, broken download, piped script) just continues with this copy.
self_update() {
    local self new
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || return 0
    [ -f "$self" ] || return 0
    command -v curl > /dev/null || return 0

    # Download next to this script, so the final mv is an atomic rename
    # and never overwrites the file bash is still reading from
    new=$(mktemp "$(dirname "$self")/.m17-hotspot-installer.XXXXXX" 2>/dev/null) || return 0
    if ! curl -fsSL --max-time 30 "$INSTALLER_URL" -o "$new"; then
        echo "⚠️  Could not check for a newer installer, continuing with this one."
        rm -f "$new"
        return 0
    fi
    if ! head -n 1 "$new" | grep -q '^#!/bin/bash' || ! bash -n "$new" 2>/dev/null; then
        echo "⚠️  The downloaded installer looks incomplete, continuing with this one."
        rm -f "$new"
        return 0
    fi
    if cmp -s "$new" "$self"; then
        rm -f "$new"
        return 0
    fi

    echo "🆕 A newer version of this installer is available."
    if ! ask_yes_no "Download it and use it now?" y; then
        echo "Continuing with this version."
        rm -f "$new"
        return 0
    fi

    chown --reference="$self" "$new" 2>/dev/null || true
    chmod --reference="$self" "$new" 2>/dev/null || chmod 755 "$new"
    if ! mv "$new" "$self"; then
        echo "⚠️  Could not replace $self, continuing with this one."
        rm -f "$new"
        return 0
    fi
    echo "🔁 Restarting with the new installer..."
    exec bash "$self" -u "$@"
}

# Must be run as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root. Please use sudo."
    exit 1
fi


# Check for Raspberry Pi OS Bookworm or Trixie
if ! grep -q "trixie\|bookworm" /etc/os-release; then
    echo "❌ This script is intended for Raspberry Pi OS Bookworm or Trixie only."
    exit 1
fi

# The m17-gateway package is built for 64-bit ARM only
if [ "$(dpkg --print-architecture)" != "arm64" ]; then
    echo "❌ This script requires the 64-bit version of Raspberry Pi OS."
    exit 1
fi

# Check for -n (don't flash), -f (offer flashing even if up to date) and
# -u (don't update the installer) options
while getopts "nfu" opt; do
    case $opt in
        n) flash='n' ;;
        f) force='y' ;;
        u) no_self_update='y' ;;
        *) usage; exit 1 ;;
    esac
done

if [ "$no_self_update" != "y" ]; then
    self_update "$@"
fi

# Stop m17-gateway if it's running: it holds the HAT's serial port, which is
# needed to identify the HAT and to flash it. It is started again at the
# end, also if this script stops early.
restart=false
trap restart_gateway EXIT
if systemctl is-active --quiet m17-gateway.service 2>/dev/null; then
    systemctl stop m17-gateway.service
    echo "Stopped m17-gateway service"
    restart=true
fi

# See which HAT answers, to suggest it below
probe_hat
case "$DETECTED_TYPE" in
    cc1200) DEFAULT_CHOICE=1 ;;
    mmdvm) DEFAULT_CHOICE=3 ;;
    *) DEFAULT_CHOICE="" ;;
esac
if [ -n "$DETECTED_TYPE" ]; then
    echo "🔎 Found a HAT: $DETECTED_IDENT"
fi

# Ask user for HAT type
echo "Please select your HAT type:"
echo "1) CC1200"
echo "2) SX1255"
echo "3) MMDVM"
while :; do
    if [ -n "$DEFAULT_CHOICE" ]; then
        read -rp "Enter your choice (1-3) [$DEFAULT_CHOICE]: " HAT_CHOICE || { echo; echo "❌ No choice made."; exit 1; }
        HAT_CHOICE=${HAT_CHOICE:-$DEFAULT_CHOICE}
    else
        read -rp "Enter your choice (1-3): " HAT_CHOICE || { echo; echo "❌ No choice made."; exit 1; }
    fi
    case $HAT_CHOICE in
        1) HAT_TYPE="CC1200"; break ;;
        2) HAT_TYPE="SX1255"; break ;;
        3) HAT_TYPE="MMDVM"; break ;;
        *) echo "Invalid choice." ;;
    esac
done
echo "Selected HAT type: $HAT_TYPE"

# Update and check if reboot is needed
echo "📦 Updating system packages..."
apt update && apt -y dist-upgrade

if [ -f /var/run/reboot-required ]; then
    echo "🔁 A system reboot is required to continue."
    echo "ℹ️  Please reboot the system and run this script again."
    exit 0
fi

# Configure boot settings based on HAT type
CONFIG_CHANGED=false

if ! grep -q "^dtoverlay=miniuart-bt" "$BOOT_CONFIG_FILE"; then
    echo "dtoverlay=miniuart-bt" >> "$BOOT_CONFIG_FILE"
    CONFIG_CHANGED=true
fi

if ! grep -q "^enable_uart=1" "$BOOT_CONFIG_FILE"; then
    echo "enable_uart=1" >> "$BOOT_CONFIG_FILE"
    CONFIG_CHANGED=true
fi

if grep -q "console=serial0,115200" "$CMDLINE_FILE"; then
    sed -i 's/console=serial0,115200 *//' "$CMDLINE_FILE"
    CONFIG_CHANGED=true
fi

if [ "$HAT_TYPE" = "SX1255" ]; then
    # Ensure SPI and I2S are enabled for SX1255 HAT
    if ! grep -q "^dtparam=spi=on" "$BOOT_CONFIG_FILE"; then
        echo "dtparam=spi=on" >> "$BOOT_CONFIG_FILE"
        CONFIG_CHANGED=true
    fi

    if ! grep -q "^dtparam=i2s=on" "$BOOT_CONFIG_FILE"; then
        echo "dtparam=i2s=on" >> "$BOOT_CONFIG_FILE"
        CONFIG_CHANGED=true
    fi

    # Download and enable I2S audio codec overlay
    if [ ! -f "$OVERLAYS_DIR/genericstereoaudiocodec.dtbo" ]; then
        echo "📥 Downloading I2S audio codec overlay..."
        curl -L -o "$OVERLAYS_DIR/genericstereoaudiocodec.dtbo" "$I2S_OVERLAY_URL"
    fi

    if ! grep -q "^dtoverlay=genericstereoaudiocodec" "$BOOT_CONFIG_FILE"; then
        echo "dtoverlay=genericstereoaudiocodec" >> "$BOOT_CONFIG_FILE"
        CONFIG_CHANGED=true
    fi

    # Turn off HDMI audio. Its sound device comes before the SX1255's and its
    # name also contains "i2s", so m17-gateway could pick it for transmit.
    # A hotspot has no use for HDMI audio anyway.
    if grep -Eq '^dtoverlay=vc4-f?kms-v3d' "$BOOT_CONFIG_FILE" &&
       grep -E '^dtoverlay=vc4-f?kms-v3d' "$BOOT_CONFIG_FILE" | grep -vq 'noaudio'; then
        echo "🔇 Disabling HDMI audio..."
        sed -i -E '/noaudio/!s/^(dtoverlay=vc4-f?kms-v3d[^[:space:]#]*)/\1,noaudio/' "$BOOT_CONFIG_FILE"
        CONFIG_CHANGED=true
    fi
fi

if $CONFIG_CHANGED; then
    echo "⚙️  Boot configuration updated. A reboot is required."
    echo "🔁 Please reboot the system and rerun this script."
    exit 0
fi

# Install required packages
echo "📦 Installing required packages: $REQUIRED_PACKAGES"
apt install -y $REQUIRED_PACKAGES

# Create M17 user
if ! id "$M17_USER" >/dev/null 2>&1; then
    echo "👤 Creating user '$M17_USER' with home at $M17_HOME..."
    useradd -m -d "$M17_HOME" -s /bin/bash "$M17_USER"
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    echo "$M17_USER:$PASSWORD" | chpasswd
    echo "User '$M17_USER' created with password: $PASSWORD"
    echo "$M17_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$M17_USER"
fi
mkdir -p "$M17_HOME"
chown -R "$M17_USER:$M17_USER" "$M17_HOME"

# Add m17 user to the groups dialout and gpio
usermod -aG dialout,gpio "$M17_USER"
echo "User '$M17_USER' has been added to the 'dialout' and 'gpio' groups."

# Use a subshell to switch to m17 user
sudo -u "$M17_USER" bash <<EOF
set -e
cd "$M17_HOME"
if [ ! -d MMDVM ]; then
    echo "📥 Cloning MMDVM..."
    git clone https://github.com/M17-Project/MMDVM.git
else
    cd "$M17_HOME/MMDVM"
    echo "📥 Updating MMDVM firmware..."
    git pull
fi

cd "$M17_HOME"
if [ ! -d MMDVM_HS ]; then
    echo "📥 Cloning MMDVM_HS..."
    git clone https://github.com/M17-Project/MMDVM_HS.git
else
    cd "$M17_HOME/MMDVM_HS"
    echo "📥 Updating MMDVM_HS firmware..."
    git pull
fi
EOF

# Update the HAT firmware if there is a newer one (the SX1255 has none).
# m17-gateway was stopped at the start.
if [ "$flash" != n ]; then
    case "$HAT_TYPE" in
        CC1200) update_cc1200_firmware ;;
        MMDVM) update_mmdvm_firmware ;;
    esac
fi

# Install dashboard
sudo -u "$M17_USER" bash <<EOF
cd "$M17_HOME"
if [ ! -d rpi-dashboard ]; then
    echo "📥 Cloning rpi-dashboard..."
    git clone https://github.com/M17-Project/rpi-dashboard
else
    cd "$M17_HOME/rpi-dashboard"
    echo "📥 Updating rpi-dashboard..."
    git pull
fi
EOF

update_hostfile

# Configure Nginx and PHP
echo "🛠️  Configuring nginx and PHP..."
systemctl enable nginx
if grep -q "bookworm" /etc/os-release; then
    systemctl enable php8.2-fpm
else
    systemctl enable php8.4-fpm
fi

if ! grep -q 'root /opt/m17/rpi-dashboard' "$NGINX_DEFAULT"; then
    tee "$NGINX_DEFAULT" > /dev/null << 'EOF'
server {
        listen 80 default_server;
        listen [::]:80 default_server;

        root /opt/m17/rpi-dashboard;
        access_log off;

    index index.php index.html index.htm;

        server_name _;

        location / {
                try_files $uri $uri/ =404;
        }

        # The dashboard reads these files itself; don't serve them
        location ^~ /files/ {
                deny all;
        }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        }
}
EOF
    echo "🔁 Restarting nginx..."
    systemctl restart nginx
elif ! grep -q 'location \^~ /files/' "$NGINX_DEFAULT"; then
    # Existing installation: stop serving the dashboard's files/ directory
    echo "🛠️  Blocking web access to the dashboard's files/ directory..."
    cp "$NGINX_DEFAULT" /tmp/nginx-default.bak
    sed -i 's|^\([[:space:]]*\)root /opt/m17/rpi-dashboard;|&\n\1location ^~ /files/ {\n\1        deny all;\n\1}|' "$NGINX_DEFAULT"
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        echo "⚠️  nginx rejected the change, restoring the previous configuration"
        cp /tmp/nginx-default.bak "$NGINX_DEFAULT"
    fi
fi

# Install M17 Gateway and configure links
echo "📥 Downloading and installing m17-gateway..."
curl -s https://api.github.com/repos/jancona/m17/releases/latest | jq -r '.assets[].browser_download_url | select(. | contains("_arm64.deb") and contains("m17-gateway"))' | xargs -I {} curl -L -o /tmp/m17-gateway.deb {}

# Avoid intermittent dpkg frontend lock errors
max_attempts=5
attempt=1
success=false

while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts..."

    if dpkg -i /tmp/m17-gateway.deb; then
        success=true
        break
    fi

    if [ $attempt -lt $max_attempts ]; then
        echo "Failed, retrying in 2 seconds..."
        sleep 2
    fi

    ((attempt++))
done

if [ "$success" = false ]; then
    echo "Failed after $max_attempts attempts"
    exit 1
fi

echo "👥 Adding 'www-data' to 'm17-gateway-control' group..."
usermod -aG m17-gateway-control www-data

# Let the dashboard's Device control buttons reboot and shut down the Pi.
# Only www-data gets this, and shutdown inhibitors (e.g. a running package
# upgrade) are still respected. Rewritten on every run to keep it current.
echo "🔌 Allowing the dashboard to reboot and shut down the Raspberry Pi..."
mkdir -p /etc/polkit-1/rules.d
tee /etc/polkit-1/rules.d/58-m17-dashboard-power.rules > /dev/null << 'EOF'
// Allow the M17 dashboard (running as www-data) to reboot and shut down
polkit.addRule(function(action, subject) {
    if (subject.user == "www-data" &&
        (action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions")) {
        return polkit.Result.YES;
    }
});
EOF
chmod 644 /etc/polkit-1/rules.d/58-m17-dashboard-power.rules

if [ "$HAT_TYPE" = "SX1255" ]; then
    echo "👥 Adding 'm17-gateway' to 'spi' and 'audio' groups..."
    usermod -aG spi,audio m17-gateway
fi

echo "🚚 Moving host files to dashboard..."
if [ ! -f /opt/m17/rpi-dashboard/files/OverrideHosts.txt ]; then
    mv /opt/m17/m17-gateway/OverrideHosts.txt /opt/m17/rpi-dashboard/files/
    chown m17:www-data /opt/m17/rpi-dashboard/files/OverrideHosts.txt
    chmod 664 /opt/m17/rpi-dashboard/files/OverrideHosts.txt
fi

# The web server may write only config.php and files/, not the dashboard code
echo "Setting dashboard permissions for www-data..."
chgrp -R www-data /opt/m17/rpi-dashboard/
chmod -R g-w /opt/m17/rpi-dashboard/
touch /opt/m17/rpi-dashboard/config.php
chgrp www-data /opt/m17/rpi-dashboard/config.php
chmod 664 /opt/m17/rpi-dashboard/config.php
chmod -R g+w /opt/m17/rpi-dashboard/files/

if ! grep -q 'HostFile=/opt/m17/rpi-dashboard/files/M17Hosts.txt' /etc/m17-gateway.ini; then
    echo "Updating m17-gateway.ini..."
    sed \
        -e 's|HostFile=/opt/m17/m17-gateway/M17Hosts.txt|HostFile=/opt/m17/rpi-dashboard/files/M17Hosts.txt|g' \
        -e 's|OverrideHostFile=/opt/m17/m17-gateway/OverrideHosts.txt|OverrideHostFile=/opt/m17/rpi-dashboard/files/OverrideHosts.txt|g' \
        /etc/m17-gateway.ini > /tmp/m17-gateway.ini
    cp /tmp/m17-gateway.ini /etc/m17-gateway.ini
fi

# Set the modem type in the [Modem] section to match the selected HAT.
# Only the Type line changes; a CC1200 variant such as cc1200v2 is kept.
MODEM_TYPE=$(echo "$HAT_TYPE" | tr '[:upper:]' '[:lower:]')
echo "Setting modem type '$MODEM_TYPE' in m17-gateway.ini..."
awk -v t="$MODEM_TYPE" '
    /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section) }
    section == "Modem" && /^[[:space:]]*Type[[:space:]]*=/ {
        if (!(t == "cc1200" && $0 ~ /=[[:space:]]*cc1200/)) $0 = "Type=" t
    }
    { print }
' /etc/m17-gateway.ini > /tmp/m17-gateway.ini
cp /tmp/m17-gateway.ini /etc/m17-gateway.ini

echo "🔗 Creating symlinks to expose gateway data to dashboard..."
ln -sf /opt/m17/m17-gateway/dashboard.log /opt/m17/rpi-dashboard/files/dashboard.log
ln -sf /etc/m17-gateway.ini /opt/m17/rpi-dashboard/files/m17-gateway.ini

if [ -f $M17_HOME/m17-gateway/dashboard.log ]; then
    # Ensure dashboard.log is accessible
    chmod 644 $M17_HOME/m17-gateway/dashboard.log
fi

# The dashboard's configuration pages need an admin password
if ! grep -q "'admin_password_hash' => '[^']" /opt/m17/rpi-dashboard/config.php 2>/dev/null; then
    if [ -t 0 ]; then
        echo "🔐 Choose a password for the dashboard's configuration pages (at least 8 characters)."
        until sudo -u www-data php /opt/m17/rpi-dashboard/set_password.php; do
            echo "Please try again."
        done
    else
        echo "⚠️  No dashboard admin password is set. Set one with:"
        echo "   sudo -u www-data php /opt/m17/rpi-dashboard/set_password.php"
    fi
fi

# Restart m17-gateway if we stopped it
restart_gateway

IP_ADDRESS=$(hostname -I | awk '{print $1}')

# Final Instructions
echo -e "\n🎉 All done!"
echo -e "\n* If this is a new installation, PLEASE REBOOT YOUR RASPBERRY PI NOW!"
echo -e "\n* To access the dashboard go to: http://$IP_ADDRESS/ or http://$(hostname).local/"
echo -e "  There, to configure your node (call sign, frequency etc), click on 'Gateway'."
echo -e "\n* The modem type has been set to '$MODEM_TYPE'. If you have an SX1255 or MMDVM HAT, check the other settings, e.g. duplex mode."
echo -e "  See the README for details: https://github.com/M17-Project/m17-hotspot-installer/tree/main#sx1255-configuration"
echo -e "\nYou will find further information under 'Help' in the dashboard."
