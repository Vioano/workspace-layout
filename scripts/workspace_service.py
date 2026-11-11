#!/usr/bin/env python3
"""Local, persistent workspace metadata and explicit window placement API."""
import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import resource
import re
import select
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

import workspace_layout as layout


RUNTIME = Path.home() / ".cache" / "codex-workspace-layout"
DEFAULT_SOCKET = RUNTIME / "service.sock"
MAX_REQUEST_BYTES = 1024 * 1024


class SelectionError(ValueError):
    def __init__(self, message, code, **details):
        super().__init__(message)
        self.details = {"code": code, **details}


class PersistentNativeBackend:
    """Own one JSONL helper; a failed mutation is never automatically replayed."""
    def __init__(self, command=None, timeout=45):
        self.command = command
        self.timeout = timeout
        self.process = None
        self.stderr = None
        self.helper_usage = {}
        self.pending = b""

    def start(self):
        if self.process is not None and self.process.poll() is None:
            return
        self.close()
        if self.command is None and (not layout.NATIVE.exists() or layout.NATIVE.stat().st_mtime < layout.SOURCE.stat().st_mtime):
            subprocess.run(["/usr/bin/clang", "-O2", "-fobjc-arc", "-framework", "AppKit",
                            "-framework", "ApplicationServices", str(layout.SOURCE), "-o", str(layout.NATIVE)], check=True)
        self.stderr = tempfile.TemporaryFile(mode="w+t")
        self.process = subprocess.Popen(self.command or [str(layout.NATIVE), "--stream"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.stderr, text=True, bufsize=1)
        self.helper_usage = {}

    def __call__(self, request):
        self.start()
        try:
            self.process.stdin.write(json.dumps(request) + "\n")
            self.process.stdin.flush()
            deadline = time.monotonic() + self.timeout
            while b"\n" not in self.pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], max(0, remaining))[0]:
                    raise RuntimeError("The owned native helper timed out; completion is unknown and this request was not replayed")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("The owned native helper disconnected; this request was not replayed")
                self.pending += chunk
            raw, self.pending = self.pending.split(b"\n", 1)
            result = json.loads(raw)
            self.helper_usage = result.get("helper_usage", {})
        except (OSError, ValueError, RuntimeError):
            self.close()
            raise
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "Native helper rejected the request"))
        return result

    def usage(self):
        if self.process is None or self.process.poll() is not None:
            return {}
        return {"pid": self.process.pid, **self.helper_usage}

    def close(self):
        process, self.process = self.process, None
        if process is not None:
            if process.stdin is not None:
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=2)
            if process.stdout is not None:
                process.stdout.close()
        if self.stderr is not None:
            self.stderr.close()
            self.stderr = None
        self.helper_usage = {}
        self.pending = b""


class WorkspaceService:
    def __init__(self, backend=None, poll_interval=1):
        self.backend = backend or PersistentNativeBackend()
        self.poll_interval = poll_interval
        self.cache_lock = threading.Lock()
        self.backend_lock = threading.Lock()
        self.action_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.state = None
        self.observed_ns = None
        self.last_error = None
        self.reservations = {}
        self.started_ns = time.monotonic_ns()

    def refresh(self):
        with self.backend_lock:
            state = self.backend({"command": "snapshot", "all_windows_metadata": True})
            if not state.get("ok"):
                raise RuntimeError(state.get("error", "Window metadata could not be read"))
            with self.cache_lock:
                self.state = state
                self.observed_ns = time.monotonic_ns()
                self.last_error = None
        return copy.deepcopy(state)

    def planning_state(self, method, arguments):
        """Only explicit identities and destinations can reuse recent metadata.

        The native action still checks the live owner, PID and source Space and
        verifies every result. Selection by position and vacancy need fresh data.
        """
        main = arguments.get("main")
        position_selector = main is not None and not str(main).isdigit()
        if (method in ("move", "arrange") and arguments.get("windows")
                and arguments.get("workspace", "auto") != "auto"
                and not arguments.get("require_empty") and not position_selector):
            with self.cache_lock:
                if (self.state is not None and self.last_error is None
                        and time.monotonic_ns() - self.observed_ns <= 500_000_000):
                    return copy.deepcopy(self.state)
        return self.refresh()

    def remember_verified_windows(self, result):
        """Update the changed rows without pretending all metadata is fresh."""
        with self.cache_lock:
            if self.state is None:
                return
            actual = {window["id"]: window for window in result["results"]}
            for window in self.state["windows"]:
                if window["id"] in actual:
                    for field in ("bounds", "spaces"):
                        window[field] = copy.deepcopy(actual[window["id"]][field])
            self.state["context"] = copy.deepcopy(result.get("afterContext", self.state["context"]))
            for space in self.state["spaces"]:
                space["count"] = sum(space["id"] in window["spaces"]
                    for window in self.state["windows"]
                    if window.get("window_type", "ordinary") == "ordinary")

    def poll(self):
        while not self.stop_event.is_set():
            try:
                self.refresh()
            except Exception as error:
                with self.cache_lock:
                    self.last_error = str(error)
            self.stop_event.wait(self.poll_interval)

    def cached_state(self, arguments):
        with self.cache_lock:
            stale = self.observed_ns is None or time.monotonic_ns() - self.observed_ns > 250_000_000
        if arguments.get("fresh") or stale:
            self.refresh()
        with self.cache_lock:
            if self.state is None:
                raise RuntimeError(self.last_error or "Workspace metadata is initializing")
            result = copy.deepcopy(self.state)
            result["cache_age_ms"] = round((time.monotonic_ns() - self.observed_ns) / 1e6, 3)
            result["metadata_error"] = self.last_error
        apps = set(self.resolve_apps(result, arguments.get("apps", [])))
        ids = set(arguments.get("windows", []))
        if apps or ids:
            result["windows"] = [w for w in result["windows"] if w["app"] in apps or w["id"] in ids]
        return result

    @staticmethod
    def resolve_apps(state, requested, allow_unseen_bundle_ids=False):
        """Resolve exact names only; a name must identify one bundle ID."""
        catalog = {}
        for window in state["windows"]:
            app = window["app"]
            if not app:
                continue
            entry = catalog.setdefault(app, {"app": app, "app_name": window.get("app_name", ""), "aliases": set()})
            entry["aliases"].update(value.strip().casefold() for value in
                (app, app.rsplit(".", 1)[-1], window.get("app_name", ""), window.get("owner_name", "")) if value.strip())
        resolved = []
        for value in requested:
            normalized = value.strip().casefold()
            matches = [app for app in catalog if normalized == app.casefold()]
            if not matches:
                matches = [app for app, entry in catalog.items() if normalized in entry["aliases"]]
            if len(matches) > 1:
                raise SelectionError(f"Application name {value!r} matches multiple apps; choose an exact bundle ID",
                    "ambiguous_application", applications=[{key:catalog[app][key] for key in ("app", "app_name")} for app in sorted(matches)])
            if not matches:
                # Preparing an owned process before its first window still accepts
                # an explicit bundle ID; the native PID/identity check remains mandatory.
                if allow_unseen_bundle_ids and re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", value):
                    matches = [value]
                else:
                    raise SelectionError(f"No exact application name or bundle ID matches {value!r}", "application_not_found")
            if matches[0] not in resolved:
                resolved.append(matches[0])
        return resolved

    @staticmethod
    def kept_destination(state, selected):
        memberships = {sid for window in selected for sid in window["spaces"]}
        ordinary = {space["id"]: space for space in state["spaces"] if space["type"] == 0}
        if len(memberships) == 1:
            sid = next(iter(memberships))
            if sid in ordinary and all(window["spaces"] == [sid] for window in selected):
                return ordinary[sid]
        candidates = [{key:space[key] for key in ("index", "id", "type")}
                      for space in state["spaces"] if space["id"] in memberships]
        raise SelectionError("keep requires selected windows in one ordinary workspace; choose --workspace or --from-workspace explicitly",
            "ambiguous_workspace" if len(memberships) > 1 else "ordinary_workspace_required",
            workspaces=candidates)

    def destination(self, state, requested, task, selected=()):
        if requested != "auto":
            return layout.space_at(state, int(requested))
        active = set(state["context"]["activeSpaces"])
        spaces = [s for s in state["spaces"] if s["type"] == 0 and s["id"] not in active]
        previous = self.reservations.get(task)
        selected_ids = {w["id"] for w in selected}
        for space in spaces:
            if space["id"] != previous:
                continue
            occupants = {w["id"] for w in state["windows"]
                         if w.get("window_type", "ordinary") == "ordinary" and space["id"] in w["spaces"]}
            if not occupants or occupants <= selected_ids:
                return space
        reserved = {space for owner, space in self.reservations.items() if owner != task}
        for space in spaces:
            if space["count"] == 0 and space["id"] not in reserved:
                self.reservations[task] = space["id"]
                return space
        raise ValueError("No confirmed empty inactive workspace is available")

    @staticmethod
    def selected_windows(state, arguments, destination=None, allow_multiple_spaces=False):
        ids, apps = arguments.get("windows", []), arguments.get("apps", [])
        if not ids and not apps:
            raise ValueError("Specify window IDs or an authorized application")
        by_id = {w["id"]: w for w in state["windows"]}
        if ids:
            if len(set(ids)) != len(ids) or any(wid not in by_id for wid in ids):
                raise ValueError("A requested window ID is unavailable or duplicated")
            selected = [by_id[wid] for wid in ids]
            if apps and any(w["app"] not in apps for w in selected):
                raise ValueError("A requested window is outside the authorized application scope")
            if any(w.get("window_type", "ordinary") != "ordinary" for w in selected):
                raise ValueError("Window placement requires ordinary windows, not panels or system surfaces")
        else:
            selected = [w for w in state["windows"] if w["app"] in apps
                        and w.get("window_type", "ordinary") == "ordinary"]
            selected.sort(key=lambda w: (w["bounds"]["Y"], w["bounds"]["X"], w["id"]))
        source_index = arguments.get("from_workspace")
        if source_index is not None:
            source = layout.space_at(state, int(source_index))
            selected = [w for w in selected if w["spaces"] == [source["id"]]]
        elif not ids and destination is not None:
            selected = [w for w in selected if w["spaces"] == [destination["id"]]]
        if not selected:
            raise ValueError("No matching windows exist in the requested workspace")
        if any(w["app"] == layout.PROTECTED for w in selected):
            raise ValueError("WeChat is protected")
        if not allow_multiple_spaces and any(len(w["spaces"]) != 1 for w in selected):
            raise ValueError("Every target window must belong to one ordinary workspace")
        return selected

    @staticmethod
    def prioritize(windows, choice):
        if choice is None:
            return windows
        selectors = {
            "leftmost": lambda w: (w["bounds"]["X"], w["bounds"]["Y"]),
            "rightmost": lambda w: (-w["bounds"]["X"], w["bounds"]["Y"]),
            "topmost": lambda w: (w["bounds"]["Y"], w["bounds"]["X"]),
            "bottommost": lambda w: (-w["bounds"]["Y"], w["bounds"]["X"]),
            "newest": lambda w: -w["id"],
        }
        if str(choice) in selectors:
            primary = min(windows, key=selectors[str(choice)])["id"]
        else:
            primary = int(choice)
        if primary not in {w["id"] for w in windows}:
            raise ValueError("The primary window is outside the selected windows")
        return sorted(windows, key=lambda w: w["id"] != primary)

    @staticmethod
    def verify_results(changes, result):
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "Window placement failed"))
        actual = {w["id"]: w for w in result.get("results", [])}
        for change in changes:
            window = actual.get(change["id"])
            if not window or window.get("spaces") != [change["toSpace"]]:
                raise RuntimeError("The backend did not verify every destination workspace")
            if "frame" in change:
                bounds = window.get("bounds", {})
                for field, native_field in (("x", "X"), ("y", "Y"), ("width", "Width"), ("height", "Height")):
                    if native_field not in bounds or abs(bounds[native_field] - change["frame"][field]) > 2:
                        raise RuntimeError("The backend did not verify every requested rectangle")

    def mutate(self, method, arguments):
        if not self.action_lock.acquire(timeout=.9):
            raise RuntimeError("Another window action is still running; this request made no changes")
        try:
            state = self.planning_state(method, arguments)
            arguments = {**arguments, "apps":self.resolve_apps(state, arguments.get("apps", []),
                                                               allow_unseen_bundle_ids=method in ("prepare", "reserve"))}
            task = str(arguments.get("task", "default"))
            requested = arguments.get("workspace", "auto")
            if method in ("move", "arrange") and requested == "auto" and not arguments.get("windows") and arguments.get("from_workspace") is None:
                raise ValueError("Specify --windows or --from-workspace when automatically allocating a destination")
            selection_hint = [w for w in state["windows"] if w["id"] in arguments.get("windows", [])]
            kept = None
            if requested == "keep":
                kept = self.selected_windows(state, arguments, allow_multiple_spaces=True)
                destination = self.kept_destination(state, kept)
            else:
                destination = self.destination(state, requested, task, selection_hint)
            if method in ("reserve", "prepare"):
                self.reservations[task] = destination["id"]
                result = {"ok": True, "workspace": destination, "reservation_state": "reserved",
                          "binding_state": "unverified", "ready_for_window_creation": False}
                if method == "prepare" and arguments.get("pid"):
                    apps = arguments.get("apps", [])
                    if len(apps) != 1 or apps[0] == layout.PROTECTED:
                        raise ValueError("Process preparation requires one authorized app")
                    with self.backend_lock:
                        binding = self.backend({"command": "bind_process", "pid": int(arguments["pid"]),
                                                "app": apps[0], "toSpace": destination["id"]})
                    if not binding.get("ok"):
                        raise RuntimeError(binding.get("error", "Process workspace binding failed"))
                    result["binding"] = binding
                    result["binding_state"] = binding.get("binding_state", "submitted")
                result["next_action"] = "Use a controlled opening adapter that verifies creation in the reserved workspace"
                return result
            if arguments.get("require_empty") and destination["count"]:
                raise ValueError("The requested destination workspace is occupied")
            if method == "move" and requested != "keep" and not arguments.get("windows") and arguments.get("from_workspace") is None:
                raise ValueError("move requires explicit window IDs or a source workspace")
            selected = kept if kept is not None else self.selected_windows(state, arguments, destination)
            selected = self.prioritize(selected, arguments.get("main"))
            frames = [None] * len(selected)
            if method == "arrange":
                frames = layout.rectangles(len(selected), destination["frame"],
                    arguments.get("layout", "auto"), float(arguments.get("ratio", .55)),
                    float(arguments.get("gap", 4)), float(arguments.get("margin", 12)),
                    arguments.get("columns"))
            changes = []
            for window, frame in zip(selected, frames):
                change = {**layout.identity(window), "fromSpace": window["spaces"][0], "toSpace": destination["id"]}
                if frame is not None:
                    change["frame"] = frame
                changes.append(change)
            if arguments.get("dry_run"):
                return {"ok": True, "dry_run": True, "plan": {"command": "apply", "windows": changes}}
            try:
                with self.backend_lock:
                    result = self.backend({"command": "apply", "windows": changes})
                    self.verify_results(changes, result)
                    self.remember_verified_windows(result)
            except Exception:
                self.refresh()
                raise
            result["context_unchanged"] = result.get("context") == result.get("afterContext")
            result["completion_scope"] = "verified_window_geometry" if method == "arrange" else "verified_window_placement"
            return result
        finally:
            self.action_lock.release()

    def dispatch(self, request):
        started = time.monotonic_ns()
        request_id = request.get("id")
        method = request.get("method")
        arguments = request.get("params", {})
        try:
            if not isinstance(arguments, dict):
                raise ValueError("params must be an object")
            if method == "state":
                result = self.cached_state(arguments)
            elif method == "status":
                with self.cache_lock:
                    own_usage = resource.getrusage(resource.RUSAGE_SELF)
                    child_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
                    native_usage = self.backend.usage() if hasattr(self.backend, "usage") else {}
                    result = {"ok": True, "pid": os.getpid(), "ready": self.state is not None,
                              "uptime_seconds": round((time.monotonic_ns() - self.started_ns) / 1e9, 3),
                              "metadata_error": self.last_error, "poll_interval_seconds": self.poll_interval,
                              "cpu_self_seconds": own_usage.ru_utime + own_usage.ru_stime,
                              "cpu_children_seconds": child_usage.ru_utime + child_usage.ru_stime + native_usage.get("cpu_seconds", 0),
                              "native_helper": native_usage,
                              "max_rss_bytes": own_usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
                                  + native_usage.get("max_rss_bytes", 0)}
            elif method == "stop":
                self.stop_event.set()
                result = {"ok": True, "stopping": True}
            elif method in ("reserve", "prepare", "move", "arrange"):
                result = self.mutate(method, arguments)
            elif method in ("open", "launch", "activate", "click"):
                result = {"ok": False, "code": "route_required", "ready_for_window_creation": False,
                          "error": "Use a controlled application adapter with pre-open workspace binding and actual document verification"}
            else:
                raise ValueError("Supported methods are state, status, reserve, prepare, move, arrange, stop")
        except SelectionError as error:
            result = {"ok": False, "error": str(error), **error.details}
        except Exception as error:
            result = {"ok": False, "error": str(error)}
        elapsed = time.monotonic_ns() - started
        return {"id": request_id, **result, "request_elapsed_ms": round(elapsed / 1e6, 3),
                "deadline_ms": 1000, "deadline_met": bool(result.get("ok") and elapsed <= 1_000_000_000)}


class RequestHandler(socketserver.StreamRequestHandler):
    def handle(self):
        raw = self.rfile.readline(MAX_REQUEST_BYTES + 1)
        try:
            if len(raw) > MAX_REQUEST_BYTES:
                raise ValueError("Request exceeds the local API size limit")
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            result = self.server.service.dispatch(request)
        except (ValueError, TypeError) as error:
            result = {"ok": False, "error": str(error)}
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode() + b"\n")
        if self.server.service.stop_event.is_set():
            threading.Thread(target=self.server.shutdown, daemon=True).start()


class LocalServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def serve(path, poll_interval=1):
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_file = path.with_suffix(".lock").open("a+")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("Workspace service is already running")
    path.unlink(missing_ok=True)
    service = WorkspaceService(poll_interval=poll_interval)
    server = LocalServer(str(path), RequestHandler)
    server.service = service
    os.chmod(path, 0o600)
    poller = threading.Thread(target=service.poll, name="workspace-metadata", daemon=True)
    poller.start()
    def stop(signum, frame):
        service.stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=.1)
    finally:
        service.stop_event.set()
        server.server_close()
        with service.backend_lock:
            if hasattr(service.backend, "close"):
                service.backend.close()
        path.unlink(missing_ok=True)
        lock_file.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    parser.add_argument("--poll-interval", type=float, default=1)
    args = parser.parse_args()
    if args.poll_interval < .05:
        parser.error("poll interval must be at least 0.05 seconds")
    serve(args.socket, args.poll_interval)
