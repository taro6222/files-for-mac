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


def verify(smbd, smbpasswd, root):
    share, mount, state = (root / name for name in ("share", "mount", "state"))
    for folder in (share, mount, state):
        folder.mkdir()
    root.chmod(0o755)
    share.chmod(0o700)
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
        try:
            result = subprocess.run(["/sbin/mount_smbfs", "-N", "-o", "nobrowse",
                                     f"//{username}:{password}@127.0.0.1:{PORT}/files-qa", mount],
                                    capture_output=True, timeout=25)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Authenticated SMB mount timed out") from None
        if result.returncode:
            raise RuntimeError(f"Authenticated SMB mount failed with status {result.returncode}")
        subprocess.run(["/usr/bin/smbutil", "statshares", "-m", mount], check=True, timeout=15)
        subprocess.run(["bash", "scripts/verify-smb-volume.sh", mount, "--skip-build"], check=True, timeout=200)
    finally:
        try:
            mounts = subprocess.check_output(["/sbin/mount"], text=True, timeout=10)
            if f" on {mount} (" in mounts:
                subprocess.run(["/sbin/umount", "-f", mount], timeout=15, check=True)
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
    arguments = parser.parse_args()
    # Keep Samba's Unix-domain socket paths under the macOS length limit.
    with tempfile.TemporaryDirectory(prefix="files-smb-", dir="/private/tmp") as directory:
        verify(arguments.smbd.resolve(strict=True), arguments.smbpasswd.resolve(strict=True), Path(directory).resolve())
