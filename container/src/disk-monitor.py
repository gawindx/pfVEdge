#!/usr/bin/env python3

import json
import os
import socket
import subprocess
import sys
import tempfile
import time


QMP_SOCKET = "/run/shm/qmp.sock"
QMP_RECONNECT_DELAY = 2
DISK_CHECK_BYTES = 102400


def log(message):
    print(f"[pfVEdge-install-watcher] {message}", flush=True)


def has_data(disk):
    source = disk
    temporary_file = None

    try:
        if disk.lower().endswith(".qcow2"):
            temporary_file = tempfile.NamedTemporaryFile(delete=False)
            temporary_file.close()

            result = subprocess.run(
                [
                    "qemu-img",
                    "dd",
                    "-f", "qcow2",
                    "-O", "raw",
                    f"bs={DISK_CHECK_BYTES}",
                    "count=1",
                    f"if={disk}",
                    f"of={temporary_file.name}",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            if result.returncode != 0:
                log("Unable to inspect disk, assuming it contains data")
                return True

            source = temporary_file.name

        result = subprocess.run(
            [
                "cmp",
                "-s",
                "-n",
                str(DISK_CHECK_BYTES),
                source,
                "/dev/zero",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if result.returncode == 0:
            return False

        if result.returncode == 1:
            return True

        log("Unable to inspect disk, assuming it contains data")
        return True

    finally:
        if temporary_file is not None:
            try:
                os.unlink(temporary_file.name)
            except FileNotFoundError:
                pass


def create_marker(marker):
    marker_dir = os.path.dirname(marker)

    if marker_dir:
        os.makedirs(marker_dir, exist_ok=True)

    with open(marker, "w", encoding="utf-8") as file:
        file.write("installed\n")

    log(f"Installation marker created: {marker}")


def check_disk(disk, marker):
    if os.path.exists(marker):
        return True

    if has_data(disk):
        log("Disk is initialized")
        create_marker(marker)
        return True

    return False


def send_command(sock, command):
    sock.sendall(
        (json.dumps({"execute": command}) + "\r\n").encode()
    )

    buffer = b""

    while True:
        data = sock.recv(65536)

        if not data:
            raise ConnectionError("QMP connection closed")

        buffer += data

        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)

            if not line.strip():
                continue

            message = json.loads(line)

            if "return" in message:
                return message["return"]

            if "error" in message:
                raise RuntimeError(
                    f"QMP command failed: {message['error']}"
                )


def connect_qmp():
    while True:
        sock = None

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(QMP_SOCKET)

            # Read QMP greeting.
            buffer = b""

            while b"\n" not in buffer:
                data = sock.recv(65536)

                if not data:
                    raise ConnectionError("QMP greeting not received")

                buffer += data

            send_command(sock, "qmp_capabilities")

            log("Connected to QMP")
            return sock

        except (FileNotFoundError, ConnectionRefusedError, OSError):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

            time.sleep(QMP_RECONNECT_DELAY)


def check_vm_status(sock, disk, marker):
    status = send_command(sock, "query-status")

    if status.get("running", False):
        log("VM is running")
        return check_disk(disk, marker)

    return False


def watch_qmp(disk, marker):
    while not os.path.exists(marker):
        sock = None

        try:
            sock = connect_qmp()

            if check_vm_status(sock, disk, marker):
                return

            while not os.path.exists(marker):
                data = sock.recv(65536)

                if not data:
                    raise ConnectionError("QMP connection closed")

                for line in data.splitlines():
                    if not line:
                        continue

                    message = json.loads(line)
                    event = message.get("event")

                    if event == "RESET":
                        log("VM reset detected")

                        if check_disk(disk, marker):
                            return

                    elif event == "RESUME":
                        log("VM resumed")

                        if check_disk(disk, marker):
                            return

        except (ConnectionError, OSError, json.JSONDecodeError) as exc:
            log(f"QMP connection lost: {exc}")

        except RuntimeError as exc:
            log(f"QMP error: {exc}")

        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

        if not os.path.exists(marker):
            time.sleep(QMP_RECONNECT_DELAY)


def main():
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} <disk> <marker>",
            file=sys.stderr,
        )
        return 2

    disk = sys.argv[1]
    marker = sys.argv[2]

    if os.path.exists(marker):
        log(f"Installation marker already exists: {marker}")
        return 0

    log(f"Watching disk: {disk}")

    # Check immediately after the disk has been detected.
    if check_disk(disk, marker):
        return 0

    log("Waiting for VM events")

    watch_qmp(disk, marker)

    return 0


if __name__ == "__main__":
    sys.exit(main())