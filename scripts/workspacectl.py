#!/usr/bin/env python3
"""One-call client for the persistent local Workspace Layout service."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

from workspace_service import DEFAULT_SOCKET


def exchange(path, request, timeout=60):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        connection.sendall(json.dumps(request).encode() + b"\n")
        with connection.makefile("rb") as response:
            result = json.loads(response.readline())
    if result.get("id") != request["id"]:
        raise RuntimeError("The local API response ID did not match the request")
    return result


def ensure_running(path):
    ping = {"id": uuid.uuid4().hex, "method": "status"}
    try:
        return exchange(path, ping, 1)
    except (OSError, ValueError, RuntimeError):
        pass
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.with_suffix(".start.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            return exchange(path, ping, 1)
        except (OSError, ValueError, RuntimeError):
            pass
        log_path = path.with_suffix(".log")
        log_descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(log_descriptor, "ab") as log:
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("workspace_service.py")),
                                        "--socket", str(path)], stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"Workspace service exited; see {log_path}")
            try:
                return exchange(path, ping, 1)
            except (OSError, ValueError, RuntimeError):
                time.sleep(.025)
        raise RuntimeError(f"Workspace service did not start; see {log_path}")


def window_ids(value):
    return [int(part) for part in value.split(",")]


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    commands = parser.add_subparsers(dest="method", required=True)
    for method in ("status", "start", "stop"):
        commands.add_parser(method)
    state = commands.add_parser("state", help="Instant cached workspace and window metadata")
    state.add_argument("--app", action="append", dest="apps", default=[], help="Exact app name or bundle ID; case-insensitive, unique match only")
    state.add_argument("--windows", type=window_ids, default=[])
    state.add_argument("--fresh", action="store_true", help="Wait for a fresh metadata read")
    for method in ("reserve", "prepare", "move", "arrange"):
        command = commands.add_parser(method)
        command.add_argument("--workspace", default="auto", help="keep: selected windows' original Space; auto: empty inactive Space; or Desktop index")
        command.add_argument("--task", default=hashlib.sha256(str(Path.cwd()).encode()).hexdigest()[:16])
        command.add_argument("--app", action="append", dest="apps", default=[], help="Exact app name or bundle ID; case-insensitive, unique match only")
        command.add_argument("--windows", type=window_ids, default=[])
        if method == "prepare":
            command.add_argument("--pid", type=int, help="Dedicated owned process to bind before opening a window")
        if method in ("move", "arrange"):
            command.add_argument("--from-workspace", type=int)
            command.add_argument("--require-empty", action="store_true")
            command.add_argument("--dry-run", action="store_true")
        if method == "arrange":
            command.add_argument("--layout", choices=["auto", "fill", "columns", "rows", "grid", "main-left", "main-right"], default="auto")
            command.add_argument("--main", help="Window ID, leftmost, rightmost, topmost, bottommost, or newest")
            command.add_argument("--ratio", type=float, default=.55)
            command.add_argument("--gap", type=float, default=4)
            command.add_argument("--margin", type=float, default=12)
            command.add_argument("--columns", type=int)
    return parser


def main():
    started = time.monotonic_ns()
    args = vars(build_parser().parse_args())
    path = args.pop("socket").expanduser()
    method = args.pop("method")
    if method in ("stop", "status"):
        try:
            result = exchange(path, {"id": uuid.uuid4().hex, "method": method})
        except (FileNotFoundError, ConnectionRefusedError):
            result = {"ok": True, "running": False, "ready": False, "deadline_met": True}
    else:
        status = ensure_running(path)
        if not status.get("ready"):
            deadline = time.monotonic() + 8
            while not status.get("ready") and time.monotonic() < deadline:
                time.sleep(.025)
                status = exchange(path, {"id": uuid.uuid4().hex, "method": "status"}, 1)
            if not status.get("ready"):
                raise RuntimeError(status.get("metadata_error") or "Workspace metadata is not ready")
        if method == "start":
            result = status
        else:
            result = exchange(path, {"id": uuid.uuid4().hex, "method": method, "params": args})
    elapsed = time.monotonic_ns() - started
    result["client_elapsed_ms"] = round(elapsed / 1e6, 3)
    result["deadline_met"] = bool(result.get("ok") and result.get("deadline_met") and elapsed <= 1_000_000_000)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
