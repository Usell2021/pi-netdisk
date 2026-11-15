#!/usr/bin/env bash
# Install the PC side of iphone-disk (Arch Linux).
#   sudo ./install-pc.sh [pi-ssh-host]
# With pi-ssh-host (e.g. "mypi") the TLS bundle is pushed to the Pi right away.
set -euo pipefail

SIZE="${SIZE:-32G}"
LABEL="${LABEL:-Untitled}"
DIR=/var/lib/iphone-disk
ETC=/etc/iphone-disk
IMAGE=$DIR/disk.img
HERE="$(cd "$(dirname "$0")" && pwd)"
PI_HOST="${1:-}"

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
OWNER="${SUDO_USER:?run via sudo from your user}"
OWNER_UID=$(id -u "$OWNER"); OWNER_GID=$(id -g "$OWNER")
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
MOUNTPOINT="${MOUNTPOINT:-$OWNER_HOME/iPhone}"

pacman -S --needed --noconfirm nbd exfatprogs python psmisc openssl
nbd-server --help 2>&1 | grep -q certfile || echo "WARN: nbd-server may lack TLS support"

id iphone-disk &>/dev/null || useradd -r -s /usr/bin/nologin -d $DIR iphone-disk
install -d -m 750 -o iphone-disk -g iphone-disk $DIR
install -d -m 755 $ETC $ETC/tls

# --- disk image: sparse, MBR + one exFAT partition (what iOS expects) --------
if [[ ! -e $IMAGE ]]; then
    truncate -s "$SIZE" $IMAGE
    printf 'label: dos\n,,7\n' | sfdisk -q $IMAGE
    loop=$(losetup -P --find --show $IMAGE); udevadm settle
    mkfs.exfat -L "$LABEL" "${loop}p1" >/dev/null
    losetup -d "$loop"
    echo "created $IMAGE ($SIZE sparse)"
else
    echo "reusing existing $IMAGE"
fi
# also after an uninstall that kept the image (it was handed to the user)
chown iphone-disk:iphone-disk $DIR $IMAGE; chmod 750 $DIR; chmod 660 $IMAGE

# --- TLS: private CA, server cert, client cert for the Pi -------------------
cd $ETC/tls
if [[ ! -e ca.crt ]]; then
    umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
        -subj /CN=iphone-disk-ca -keyout ca.key -out ca.crt 2>/dev/null
    for n in server client; do
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -subj /CN=iphone-disk-$n -keyout $n.key -out $n.csr 2>/dev/null
        openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
            -extfile <(printf 'subjectAltName=DNS:iphone-disk-%s\nextendedKeyUsage=%s\n' \
                $n "$([[ $n == server ]] && echo serverAuth || echo clientAuth)") \
            -out $n.crt 2>/dev/null
        rm $n.csr
    done
    umask 022
fi
chown root:iphone-disk server.key; chmod 640 server.key; chmod 644 ca.crt server.crt
cd - >/dev/null

# --- nbd-server: localhost only, TLS mandatory ------------------------------
cat > $ETC/nbd-server.conf <<EOF
[generic]
    user = iphone-disk
    group = iphone-disk
    listenaddr = 127.0.0.1
    port = 10810
    certfile = $ETC/tls/server.crt
    keyfile = $ETC/tls/server.key
    cacertfile = $ETC/tls/ca.crt
    force_tls = true
    allowlist = false
[iphone]
    exportname = $IMAGE
    flush = true
    fua = true
EOF

cat > $ETC/gate.env <<EOF
IMAGE=$IMAGE
MOUNTPOINT=$MOUNTPOINT
OWNER_UID=$OWNER_UID
OWNER_GID=$OWNER_GID
PORT=10809
UPSTREAM_PORT=10810
EOF

install -m 755 "$HERE/iphone-disk-gate.py" /usr/local/bin/iphone-disk-gate

cat > /etc/systemd/system/iphone-disk-nbd.service <<EOF
[Unit]
Description=iphone-disk nbd-server (localhost, TLS)
After=network.target

[Service]
ExecStart=/usr/bin/nbd-server -C $ETC/nbd-server.conf -d
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/iphone-disk-gate.service <<EOF
[Unit]
Description=iphone-disk gate (mount on PC <-> serve to Pi)
After=network-online.target iphone-disk-nbd.service local-fs.target
Wants=network-online.target iphone-disk-nbd.service

[Service]
EnvironmentFile=$ETC/gate.env
ExecStart=/usr/bin/python3 /usr/local/bin/iphone-disk-gate
ExecStopPost=-/usr/bin/umount $MOUNTPOINT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

install -d -o "$OWNER" -g "$OWNER" "$MOUNTPOINT"
systemctl daemon-reload
systemctl enable --now iphone-disk-nbd.service iphone-disk-gate.service

# --- bundle for the Pi -----------------------------------------------------
PC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
BUNDLE=$OWNER_HOME/iphone-disk-pi-bundle.tar
tmp=$(mktemp -d)
cp $ETC/tls/{ca.crt,client.crt,client.key} "$tmp/"
echo "PC_HOST=$PC_IP" > "$tmp/pc.conf"
tar -C "$tmp" -cf "$BUNDLE" .
rm -rf "$tmp"; chown "$OWNER": "$BUNDLE"; chmod 600 "$BUNDLE"

echo
echo "PC side ready. Disk is mounted at $MOUNTPOINT when no iPhone is attached."
echo "PC address for the Pi: $PC_IP (port 10809/tcp must be reachable from the Pi)."
if [[ -n $PI_HOST ]]; then
    sudo -u "$OWNER" scp -q "$BUNDLE" "$PI_HOST:/tmp/iphone-disk-pi-bundle.tar"
    sudo -u "$OWNER" ssh -t "$PI_HOST" sudo iphone-disk-set-pc /tmp/iphone-disk-pi-bundle.tar
else
    echo "Push to the Pi:  scp $BUNDLE <pi>:/tmp/ && ssh -t <pi> sudo iphone-disk-set-pc /tmp/$(basename "$BUNDLE")"
fi
