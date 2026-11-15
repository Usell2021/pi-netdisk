#!/usr/bin/env bash
# Point the Pi at a PC: sudo iphone-disk-set-pc /path/to/iphone-disk-pi-bundle.tar
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
B="${1:?bundle path}"
CFG=/etc/iphone-disk
install -d -m 700 $CFG
tar -C $CFG -xf "$B" ./ca.crt ./client.crt ./client.key ./pc.conf
mv $CFG/pc.conf $CFG/pi.conf
chmod 600 $CFG/*; chown root:root $CFG/*
shred -u "$B" 2>/dev/null || rm -f "$B"
systemctl restart iphone-disk.service
echo "Pi now uses PC $(. $CFG/pi.conf; echo $PC_HOST)"
