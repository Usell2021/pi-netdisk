#!/usr/bin/env bash
# Install the Pi side of iphone-disk (Raspberry Pi OS trixie, Pi 4).
#   sudo ./install-pi.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG=/etc/iphone-disk
BOOT=/boot/firmware/config.txt

apt-get install -y nbd-client
install -d -m 700 $CFG
install -m 755 "$HERE/iphone-disk-gadget.sh" /usr/local/sbin/iphone-disk-gadget
install -m 755 "$HERE/iphone-disk-set-pc.sh" /usr/local/sbin/iphone-disk-set-pc

# USB-C in device mode (the existing dwc2 line in [cm5] does not apply to Pi 4)
if ! grep -q '^dtoverlay=dwc2,dr_mode=peripheral' $BOOT; then
    cp $BOOT $BOOT.bak-iphone-disk
    printf '\n[all]\ndtoverlay=dwc2,dr_mode=peripheral\n' >> $BOOT
    REBOOT=1
fi
grep -qx dwc2 /etc/modules || echo dwc2 >> /etc/modules

# --- nothing of the data may land on the SD card ---------------------------
# zram is fine (RAM); its writeback to a swap file on SD is not.
systemctl disable --now rpi-zram-writeback.timer 2>/dev/null || true
systemctl mask rpi-zram-writeback.service rpi-zram-writeback.timer rpi-resize-swap-file.service
install -d /etc/rpi/swap.conf.d
printf '[Main]\nMechanism=zram\n' > /etc/rpi/swap.conf.d/90-iphone-disk.conf
swapoff /var/swap 2>/dev/null || true; rm -f /var/swap
# push writes out of RAM to the PC quickly (small dirty cache)
cat > /etc/sysctl.d/90-iphone-disk.conf <<EOF
vm.dirty_background_bytes = 2097152
vm.dirty_bytes = 8388608
vm.dirty_expire_centisecs = 100
vm.dirty_writeback_centisecs = 50
EOF
sysctl -q --system

# Wi-Fi power saving kills throughput and latency
for c in $(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless"{print $1}'); do
    nmcli con modify "$c" 802-11-wireless.powersave 2
done

cat > /etc/systemd/system/iphone-disk.service <<EOF
[Unit]
Description=iphone-disk USB gadget backed by NBD on the PC
After=network-online.target sys-kernel-config.mount
Wants=network-online.target
ConditionPathExists=$CFG/pi.conf

[Service]
ExecStart=/usr/local/sbin/iphone-disk-gadget
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable iphone-disk.service

echo "Pi side installed. Next: run install-pc.sh on the PC (it pushes the TLS bundle here)."
[[ ${REBOOT:-0} == 1 ]] && echo "REBOOT REQUIRED for USB device mode: sudo reboot"
