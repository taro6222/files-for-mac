#!/usr/bin/env python3
"""Exercise an isolated Samba share on a disposable macOS runner."""

import argparse
import os
from pathlib import Path
import pwd
import re
import secrets
import socket
import subprocess
import tempfile
import time


PORT = 15445


def wait_for_server(server):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"Samba exited before accepting connections: {server.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.5):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("Samba did not open its loopback port")


def mount_share(name, mount, username, password):
    try:
        result = subprocess.run(["/sbin/mount_smbfs", "-N", "-o", "nobrowse",
                                 f"//{username}:{password}@127.0.0.1:{PORT}/{name}", mount],
                                capture_output=True, timeout=25)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Authenticated SMB mount of {name} timed out") from None
    if result.returncode:
        raise RuntimeError(f"Authenticated SMB mount of {name} failed with status {result.returncode}")
    subprocess.run(["/usr/bin/smbutil", "statshares", "-m", mount], check=True, timeout=15)


def reconnect_count(mount):
    output = subprocess.check_output(["/usr/bin/smbutil", "statshares", "-m", mount], text=True, timeout=6)
    count = re.search(r"^\s*SESSION_RECONNECT_COUNT\s+(\d+)\s*$", output, re.MULTILINE)
    if count is None:
        raise RuntimeError("SMB mount did not report a session reconnect count")
    return int(count.group(1))


def verify_reconnect(smbcontrol, config, share, mount):
    before = share / "reconnect-before.txt"
    after = share / "reconnect-after.txt"
    before_payload = b"before Samba disconnect"
    after_payload = b"after Samba disconnect"
    before.write_bytes(before_payload)
    if subprocess.check_output(["/bin/cat", mount / before.name], timeout=8) != before_payload:
        raise RuntimeError("The mounted share did not return the initial reconnect fixture")
    device = mount.stat().st_dev
    count = reconnect_count(mount)
    subprocess.run(["sudo", "-n", smbcontrol, "--configfile", config, "smbd", "kill-client-ip", "127.0.0.1"],
                   check=True, timeout=10)
    after.write_bytes(after_payload)
    before.unlink()

    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        try:
            contents = subprocess.check_output(["/bin/cat", mount / after.name], stderr=subprocess.DEVNULL, timeout=6)
            reconnected = reconnect_count(mount)
        except subprocess.SubprocessError:
            time.sleep(0.5)
            continue
        if contents == after_payload and reconnected > count:
            if mount.stat().st_dev != device:
                raise RuntimeError("SMB reconnected on a different mount device")
            print(f"SMB verification: reconnect count {count} -> {reconnected} on the original mount", flush=True)
            return
        time.sleep(0.5)
    raise RuntimeError("The original SMB mount did not reconnect and read the new server fixture")


def verify(smbd, smbpasswd, root, smbcontrol=None):
    share, mount, state = (root / name for name in ("share", "mount", "state"))
    readonly_share, readonly_mount = (root / name for name in ("readonly-share", "readonly-mount"))
    for folder in (share, mount, state, readonly_share, readonly_mount):
        folder.mkdir()
    root.chmod(0o755)
    share.chmod(0o700)
    readonly_share.chmod(0o700)
    (readonly_share / "replace.txt").write_bytes(b"existing read-only SMB destination")
    username = pwd.getpwuid(os.getuid()).pw_name
    if re.fullmatch(r"[A-Za-z0-9_.-]+", username) is None:
        raise ValueError("The runner account cannot be represented in the fixture configuration")
    password = secrets.token_hex(24)
    config = root / "smb.conf"
    config.write_text(f"""[global]
    server role = standalone server
    interfaces = 127.0.0.1
    bind interfaces only = yes
    smb ports = {PORT}
    server min protocol = SMB2_10
    fruit:aapl = yes
    fruit:nfs_aces = yes
    passdb backend = tdbsam:{state / "passdb.tdb"}
    state directory = {state}
    cache directory = {state}
    lock directory = {state}
    pid directory = {state}
    private dir = {state}
    ncalrpc dir = {state / "rpc"}
    log level = 3
    log file = {root / "smb.log"}
[files-qa]
    path = {share}
    read only = no
    valid users = {username}
    vfs objects = fruit streams_xattr
    # The runner's filesystem rejects Samba's temporary directory rename.
    vfs mkdir use tmp name = no
[files-readonly]
    path = {readonly_share}
    read only = yes
    valid users = {username}
    vfs objects = fruit streams_xattr
""", encoding="utf-8")
    with socket.socket() as port:
        port.bind(("127.0.0.1", PORT))
    server = None
    try:
        subprocess.run(["sudo", "-n", smbpasswd, "-c", config, "-s", "-a", username],
                       input=f"{password}\n{password}\n", text=True, check=True, timeout=15)
        # A foreground Samba treats EOF on an inherited pipe as a request to exit.
        server = subprocess.Popen(["sudo", "-n", smbd, "--foreground", "--no-process-group", "--configfile", config],
                                  stdin=subprocess.DEVNULL, start_new_session=True)
        wait_for_server(server)
        mount_share("files-qa", mount, username, password)
        mount_share("files-readonly", readonly_mount, username, password)
        environment = dict(os.environ, FILES_TEST_SMB_READONLY_VOLUME=str(readonly_mount))
        if smbcontrol is not None:
            verify_reconnect(smbcontrol, config, share, mount)
            environment["FILES_TEST_SMB_RECONNECT_VOLUME"] = str(mount)
        subprocess.run(["bash", "scripts/verify-smb-volume.sh", mount, "--skip-build"],
                       env=environment, check=True, timeout=200)
    finally:
        try:
            mounts = subprocess.check_output(["/sbin/mount"], text=True, timeout=10)
            failed = []
            for mount_path in (readonly_mount, mount):
                if f" on {mount_path} (" in mounts:
                    try:
                        subprocess.run(["/sbin/umount", "-f", mount_path], timeout=15, check=True)
                    except (OSError, subprocess.SubprocessError):
                        failed.append(mount_path.name)
            if failed:
                raise RuntimeError("Could not unmount SMB fixture: " + ", ".join(failed))
        finally:
            if server is not None and server.poll() is None:
                server.terminate()
                server.wait(timeout=15)
            log = root / "smb.log"
            if log.exists():
                print(log.read_text(errors="replace")[-8000:])
            subprocess.run(["sudo", "-n", "/usr/sbin/chown", "-R", str(root.stat().st_uid), root], check=True, timeout=15)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("smbd", type=Path)
    parser.add_argument("smbpasswd", type=Path)
    parser.add_argument("--smbcontrol", type=Path)
    arguments = parser.parse_args()
    # Keep Samba's Unix-domain socket paths under the macOS length limit.
    with tempfile.TemporaryDirectory(prefix="files-smb-", dir="/private/tmp") as directory:
        control = arguments.smbcontrol.resolve(strict=True) if arguments.smbcontrol else None
        verify(arguments.smbd.resolve(strict=True), arguments.smbpasswd.resolve(strict=True), Path(directory).resolve(), control)
