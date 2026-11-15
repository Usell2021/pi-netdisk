#!/usr/bin/env bash
# iphone-disk (Pi side): USB mass-storage gadget whose only medium is a remote
# NBD export on the PC. Nothing is stored on the Pi.
#   USB host attached + PC reachable -> medium present (/dev/nbd0)
#   otherwise                        -> "card reader without a card"
set -uo pipefail
. /etc/iphone-disk/pi.conf          # PC_HOST, PC_PORT, optional USB_* (see pi.conf.example)
: "${USB_VID:=0x1d6b}" "${USB_PID:=0x0104}" "${USB_BCD:=0x0100}"
: "${USB_MANUFACTURER:=iphone-disk}" "${USB_PRODUCT:=Network Disk}"
: "${USB_SERIAL:=$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null)}"
: "${USB_INQUIRY:=}"                # SCSI "VENDOR  PRODUCT         REV " (8+16+4)
CFG=/etc/iphone-disk
G=/sys/kernel/config/usb_gadget/iphone-disk
NBD=/dev/nbd0
LUN=$G/functions/mass_storage.0/lun.0

log() { echo "$*"; }

setup_gadget() {
    modprobe libcomposite; modprobe nbd nbds_max=1
    [[ -d $G ]] && return
    mkdir -p $G && cd $G
    echo "$USB_VID" > idVendor; echo "$USB_PID" > idProduct
    echo "$USB_BCD" > bcdDevice; echo 0x0200 > bcdUSB
    mkdir -p strings/0x409
    echo "$USB_MANUFACTURER" > strings/0x409/manufacturer
    echo "$USB_PRODUCT" > strings/0x409/product
    echo "$USB_SERIAL" > strings/0x409/serialnumber
    mkdir -p functions/mass_storage.0
    echo 1 > functions/mass_storage.0/stall
    echo 1 > $LUN/removable; echo 0 > $LUN/ro; echo 0 > $LUN/cdrom; echo 0 > $LUN/nofua
    [[ -n $USB_INQUIRY ]] && printf '%s' "$USB_INQUIRY" > $LUN/inquiry_string
    mkdir -p configs/c.1/strings/0x409
    echo "mass storage" > configs/c.1/strings/0x409/configuration
    echo 100 > configs/c.1/MaxPower
    ln -s functions/mass_storage.0 configs/c.1/
    ls /sys/class/udc | head -1 > UDC
}

udc_state() { cat /sys/class/udc/*/state 2>/dev/null | head -1; }
nbd_up()    { [[ -e /sys/block/nbd0/pid ]]; }
medium_in() { [[ -n $(cat $LUN/file) ]]; }

eject() {
    medium_in && { echo 1 > $LUN/forced_eject 2>/dev/null || echo > $LUN/file; log "medium ejected"; }
    nbd_up && nbd-client -d $NBD >/dev/null 2>&1
}

attach() {
    nbd-client "$PC_HOST" "${PC_PORT:-10809}" $NBD -N iphone -b 512 -t 30 -x \
        -certfile $CFG/client.crt -keyfile $CFG/client.key -cacertfile $CFG/ca.crt \
        -tlshostname iphone-disk-server >/dev/null 2>&1 || return 1
    # never keep stale blocks from an earlier session
    blockdev --flushbufs $NBD 2>/dev/null
    echo $NBD > $LUN/file && log "medium inserted ($(blockdev --getsize64 $NBD) bytes from $PC_HOST)"
}

trap 'eject; exit 0' TERM INT
setup_gadget
log "gadget up, PC=$PC_HOST"
last=""; backoff=0
while true; do
    st=$(udc_state)
    [[ $st != "$last" ]] && { log "usb: $st"; last=$st; }
    if [[ $st == configured ]]; then
        if medium_in && ! nbd_up; then
            log "connection to PC lost"; eject
        elif ! medium_in; then
            if (( backoff == 0 )); then
                attach || { eject; backoff=3; }
            else
                ((backoff--))
            fi
        fi
    else
        medium_in || nbd_up && eject
        backoff=0
    fi
    sleep 1
done
