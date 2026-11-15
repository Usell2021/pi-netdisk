#!/usr/bin/env python3
"""iphone-disk gate (PC side).

Guarantees the disk image is never used by the PC and the Pi at the same time:
  * no Pi connected  -> image is mounted at MOUNTPOINT for the local user
  * Pi connects      -> unmount (refuse the Pi if files are busy), then proxy the
                        TCP stream to the local nbd-server (TLS is end-to-end)
  * Pi disconnects   -> fsck + mount again

Config comes from environment (see /etc/iphone-disk/gate.env).
"""
import asyncio
import os
import socket
import subprocess
import sys

IMAGE = os.environ.get("IMAGE", "/var/lib/iphone-disk/disk.img")
MOUNTPOINT = os.environ["MOUNTPOINT"]
OWNER_UID = os.environ["OWNER_UID"]
OWNER_GID = os.environ["OWNER_GID"]
LISTEN = os.environ.get("LISTEN", "0.0.0.0")
PORT = int(os.environ.get("PORT", "10809"))
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "10810"))

loopdev = None
client_active = False


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip() or r.returncode}")
    return r


def is_mounted():
    return run("mountpoint", "-q", MOUNTPOINT, check=False).returncode == 0


def mount_disk():
    global loopdev
    if is_mounted():
        return
    # Fresh loop device every time: a lingering one would serve stale cached
    # blocks after the Pi has written to the image through nbd-server.
    loopdev = run("losetup", "-P", "--find", "--show", IMAGE).stdout.strip()
    part = loopdev + "p1"
    for _ in range(50):
        if os.path.exists(part):
            break
        run("udevadm", "settle", check=False)
    fsck = run("fsck.exfat", "-p", part, check=False)
    if fsck.returncode not in (0, 1):
        log(f"fsck.exfat rc={fsck.returncode}: {fsck.stdout.strip()} {fsck.stderr.strip()}")
    os.makedirs(MOUNTPOINT, exist_ok=True)
    run("mount", "-t", "exfat", "-o",
        f"uid={OWNER_UID},gid={OWNER_GID},umask=022", part, MOUNTPOINT)
    log(f"mounted {part} at {MOUNTPOINT}")


def unmount_disk():
    """Return True when the image is free. Never lazy-unmounts: a still-mounted
    filesystem plus remote writes would corrupt the disk."""
    global loopdev
    if is_mounted():
        run("sync", check=False)
        r = run("umount", MOUNTPOINT, check=False)
        if r.returncode != 0:
            users = run("fuser", "-vm", MOUNTPOINT, check=False).stderr.strip()
            log(f"umount refused ({r.stderr.strip()}); busy:\n{users}")
            return False
    if loopdev:
        run("losetup", "-d", loopdev, check=False)
        loopdev = None
    # detach any other loop devices on the image (e.g. after a crash)
    for line in run("losetup", "-j", IMAGE, check=False).stdout.splitlines():
        run("losetup", "-d", line.split(":")[0], check=False)
    log("image released")
    return True


def keepalive(sock):
    # Pi is powered by the iPhone: unplugging kills it without a FIN.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 2)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_USER_TIMEOUT, 20000)


async def pipe(reader, writer):
    try:
        while data := await reader.read(256 * 1024):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(c_reader, c_writer):
    global client_active
    peer = c_writer.get_extra_info("peername")
    if client_active:
        log(f"reject {peer}: another client is active")
        c_writer.close()
        return
    client_active = True
    try:
        keepalive(c_writer.get_extra_info("socket"))
        if not await asyncio.to_thread(unmount_disk):
            c_writer.close()  # Pi retries; iPhone sees "no medium" meanwhile
            return
        log(f"client {peer} connected")
        u_reader, u_writer = await asyncio.open_connection("127.0.0.1", UPSTREAM_PORT)
        await asyncio.gather(pipe(c_reader, u_writer), pipe(u_reader, c_writer))
        await u_writer.wait_closed()
        log(f"client {peer} gone")
    except Exception as e:
        log(f"client {peer} error: {e}")
        c_writer.close()
    finally:
        await asyncio.sleep(1)  # let nbd-server finish flushing
        try:
            await asyncio.to_thread(mount_disk)
        except Exception as e:
            log(f"mount failed: {e}")
        client_active = False


async def main():
    try:
        mount_disk()
    except Exception as e:
        log(f"initial mount failed: {e}")
    server = await asyncio.start_server(handle, LISTEN, PORT)
    log(f"listening on {LISTEN}:{PORT}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
