#!/usr/bin/env bash
# Remove the Pi side of pi-netdisk and undo the system tweaks of install-pi.sh.
# The copied/cloned repo directory is left alone.
#   sudo ./uninstall-pi.sh [--remove-packages] [-y]
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

DEL_PKGS=0; YES=0
for a in "$@"; do
    case $a in
        --remove-packages) DEL_PKGS=1 ;;
        -y) YES=1 ;;
        *) echo "unknown option: $a"; exit 1 ;;
    esac
done

BOOT=/boot/firmware/config.txt
G=/sys/kernel/config/usb_gadget/iphone-disk

echo "Will remove the iphone-disk service, gadget, configs and TLS keys,"
echo "switch USB-C back to default mode and restore swap/sysctl/Wi-Fi defaults."
if (( !YES )); then
    read -rp "Continue? [y/N] " r; [[ $r == [yY]* ]] || exit 1
fi

# --- service + live gadget ---------------------------------------------------
systemctl disable --now iphone-disk.service 2>/dev/null
if [[ -d $G ]]; then
    echo "" > $G/UDC 2>/dev/null
    rm -f $G/configs/c.1/mass_storage.0
    rmdir $G/configs/c.1/strings/0x409 $G/configs/c.1 \
          $G/functions/mass_storage.0 $G/strings/0x409 $G 2>/dev/null
fi
nbd-client -d /dev/nbd0 >/dev/null 2>&1
rm -f /etc/systemd/system/iphone-disk.service
systemctl daemon-reload
rm -f /usr/local/sbin/iphone-disk-gadget /usr/local/sbin/iphone-disk-set-pc
rm -rf /etc/iphone-disk

# --- USB-C device mode -------------------------------------------------------
# drop our overlay line and the "[all]" header we added right before it
if grep -q '^dtoverlay=dwc2,dr_mode=peripheral' $BOOT; then
    awk '
        /^\[all\]$/ { held = held $0 "\n"; next }
        /^dtoverlay=dwc2,dr_mode=peripheral$/ { held = ""; next }
        { printf "%s", held; held = ""; print }
        END { printf "%s", held }
    ' $BOOT > $BOOT.tmp && mv $BOOT.tmp $BOOT
    # remove a trailing empty line left behind
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' $BOOT
fi
rm -f $BOOT.bak-iphone-disk
sed -i '/^dwc2$/d' /etc/modules

# --- swap / sysctl / Wi-Fi back to Raspberry Pi OS defaults ------------------
rm -f /etc/rpi/swap.conf.d/90-iphone-disk.conf
rmdir /etc/rpi/swap.conf.d 2>/dev/null
systemctl unmask rpi-zram-writeback.service rpi-zram-writeback.timer rpi-resize-swap-file.service
rm -f /etc/sysctl.d/90-iphone-disk.conf
sysctl -q --system
for c in $(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless"{print $1}'); do
    nmcli con modify "$c" 802-11-wireless.powersave 0
done

(( DEL_PKGS )) && apt-get remove -y --purge nbd-client

echo "Pi side removed. Reboot to apply: sudo reboot"
echo "(the swap file on SD and zram writeback come back after the reboot)"
