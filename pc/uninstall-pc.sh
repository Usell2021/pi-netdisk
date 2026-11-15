#!/usr/bin/env bash
# Remove the PC side of pi-netdisk. The cloned repo is left alone.
#   sudo ./uninstall-pc.sh [--delete-image] [--remove-packages] [-y]
#     --delete-image     also delete /var/lib/iphone-disk/disk.img (your files!)
#     --remove-packages  also uninstall nbd and exfatprogs
#     -y                 don't ask for confirmation
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

DEL_IMAGE=0; DEL_PKGS=0; YES=0
for a in "$@"; do
    case $a in
        --delete-image) DEL_IMAGE=1 ;;
        --remove-packages) DEL_PKGS=1 ;;
        -y) YES=1 ;;
        *) echo "unknown option: $a"; exit 1 ;;
    esac
done

DIR=/var/lib/iphone-disk
ETC=/etc/iphone-disk
IMAGE=$DIR/disk.img
MOUNTPOINT=$( . $ETC/gate.env 2>/dev/null; echo "${MOUNTPOINT:-}" )
OWNER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)

echo "Will remove: systemd units, $ETC, /usr/local/bin/iphone-disk-gate, user iphone-disk"
(( DEL_IMAGE )) && echo "             AND THE DISK IMAGE $IMAGE (all files on it)" \
               || echo "Disk image is kept: $IMAGE"
if (( !YES )); then
    read -rp "Continue? [y/N] " r; [[ $r == [yY]* ]] || exit 1
fi

systemctl disable --now iphone-disk-gate.service iphone-disk-nbd.service 2>/dev/null
[[ -n $MOUNTPOINT ]] && mountpoint -q "$MOUNTPOINT" && umount "$MOUNTPOINT"
for l in $(losetup -j $IMAGE 2>/dev/null | cut -d: -f1); do losetup -d "$l"; done

rm -f /etc/systemd/system/iphone-disk-gate.service /etc/systemd/system/iphone-disk-nbd.service
systemctl daemon-reload
rm -f /usr/local/bin/iphone-disk-gate
rm -rf $ETC
rm -f "$OWNER_HOME/iphone-disk-pi-bundle.tar"
[[ -n $MOUNTPOINT && -d $MOUNTPOINT ]] && rmdir "$MOUNTPOINT" 2>/dev/null

if (( DEL_IMAGE )); then
    rm -rf $DIR
    userdel iphone-disk 2>/dev/null
else
    # keep the data, hand it to the user so the system account can go
    chown -R "${SUDO_USER:-root}": $DIR 2>/dev/null
    userdel iphone-disk 2>/dev/null
    echo "Image kept at $IMAGE. Open it with:"
    echo "  sudo mount -o loop,offset=1048576 $IMAGE /mnt"
fi

(( DEL_PKGS )) && pacman -Rns --noconfirm nbd exfatprogs

echo "PC side removed."
