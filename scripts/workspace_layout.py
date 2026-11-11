#!/usr/bin/env python3
"""Background, window-ID-scoped macOS Spaces and layout control."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
NATIVE = HERE / "windowbridge"
SOURCE = HERE / "windowbridge.m"
PROTECTED = "com.tencent.xinWeChat"


def native(request):
    if not NATIVE.exists() or NATIVE.stat().st_mtime < SOURCE.stat().st_mtime:
        subprocess.run(["/usr/bin/clang", "-O2", "-fobjc-arc", "-framework", "AppKit",
                        "-framework", "ApplicationServices", str(SOURCE), "-o", str(NATIVE)], check=True)
    proc = subprocess.run([str(NATIVE)], input=json.dumps(request), text=True,
                          capture_output=True, timeout=45)
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        raise RuntimeError(proc.stderr.strip() or "Native helper returned no JSON")
    if proc.returncode or not result.get("ok"):
        raise RuntimeError(result.get("error", proc.stderr))
    return result


def snapshot(apps=(), ids=(), titles=False):
    return native({"command": "snapshot", "apps": list(apps), "ids": list(ids), "titles": titles})


def space_at(state, index):
    match = next((s for s in state["spaces"] if s["index"] == index), None)
    if not match or match["type"] != 0:
        raise ValueError(f"Desktop {index} is not an existing ordinary workspace")
    return match


def rectangles(count, frame, layout="auto", ratio=.55, gap=12, margin=12, columns=None):
    if count < 1:
        raise ValueError("No windows selected")
    if not 0.2 <= ratio <= 0.8 or gap < 0 or margin < 0:
        raise ValueError("Use ratio 0.2..0.8 and nonnegative gap/margin")
    x, y = frame["x"] + margin, frame["y"] + margin
    width, height = frame["width"] - 2 * margin, frame["height"] - 2 * margin
    if width <= 0 or height <= 0:
        raise ValueError("Margins leave no usable screen area")
    if layout == "auto":
        layout = "fill" if count == 1 else "columns" if count == 2 else "main-left" if count == 3 else "grid"

    def rect(a, b, w, h):
        if min(w, h) < 100:
            raise ValueError("Layout is too dense; select fewer windows or another workspace")
        return dict(zip(("x", "y", "width", "height"), map(round, (a, b, w, h))))

    if layout == "fill":
        if count != 1:
            raise ValueError("fill requires exactly one selected window")
        return [rect(x, y, width, height)]
    if layout in ("main-left", "main-right") and count > 1:
        primary = round((width - gap) * ratio)
        secondary = width - gap - primary
        h = (height - gap * (count - 2)) / (count - 1)
        main_x = x if layout == "main-left" else x + secondary + gap
        side_x = x + primary + gap if layout == "main-left" else x
        return [rect(main_x, y, primary, height)] + [rect(side_x, y + i * (h + gap), secondary, h) for i in range(count - 1)]
    if layout == "rows":
        cols = 1
    elif layout == "columns":
        cols = count
    else:
        cols = columns or math.ceil(math.sqrt(count))
    if cols < 1:
        raise ValueError("columns must be positive")
    rows = math.ceil(count / cols)
    w, h = (width - gap * (cols - 1)) / cols, (height - gap * (rows - 1)) / rows
    return [rect(x + (i % cols) * (w + gap), y + (i // cols) * (h + gap), w, h) for i in range(count)]


def apply_changes(changes, dry_run=False):
    for c in changes:
        if c["app"] == PROTECTED:
            raise ValueError("WeChat is protected")
    plan = {"command": "apply", "windows": changes}
    if dry_run:
        return {"ok": True, "dry_run": True, "plan": plan}
    start = time.monotonic()
    result = native(plan)
    result["elapsed_seconds"] = round(time.monotonic() - start, 3)
    result["context_unchanged"] = result["context"] == result["afterContext"]
    return result


def identity(window):
    return {k: window[k] for k in ("id", "pid", "app")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list", help="Workspace occupancy and only the requested windows; no screenshots")
    listing.add_argument("--app", action="append", default=[])
    listing.add_argument("--titles", action="store_true")
    listing.add_argument("--windows", type=lambda s: [int(i) for i in s.split(",")], default=[])
    for name in ("move", "arrange", "place", "open"):
        p = sub.add_parser(name)
        p.add_argument("--workspace", required=True, type=int)
        p.add_argument("--app", action="append", default=[])
        p.add_argument("--windows", type=lambda s: [int(i) for i in s.split(",")], default=[])
        p.add_argument("--from-workspace", type=int)
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--require-empty", action="store_true")
        if name in ("arrange", "open"):
            p.add_argument("--layout", choices=["auto", "fill", "columns", "rows", "grid", "main-left", "main-right"], default="auto")
            p.add_argument("--main", type=int)
            p.add_argument("--ratio", type=float, default=.55)
            p.add_argument("--gap", type=float, default=12)
            p.add_argument("--margin", type=float, default=12)
            p.add_argument("--columns", type=int)
        if name == "place":
            p.add_argument("--rect", required=True, help="Normalized x,y,width,height in the usable display frame")
        if name == "open":
            p.add_argument("--file", action="append", required=True)
            p.add_argument("--arrange-existing", action="store_true", help="Include existing windows of the requested app on the destination")
            p.add_argument("--slot-of", type=int, help="Put one new document in this existing window's exact rectangle")
            p.add_argument("--park-workspace", type=int, help="Empty workspace for the displaced slot window")
    custom = sub.add_parser("apply", help="Apply per-window workspace/frame placements from a JSON plan")
    custom.add_argument("--plan", type=Path, required=True)
    custom.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.command == "open":
        raise ValueError("Generic document opening is disabled: use a controlled application adapter with workspace binding before window creation")

    if args.command == "list":
        result = snapshot(args.app, args.windows, args.titles)
    elif args.command == "apply":
        placements = json.loads(args.plan.read_text())
        if not isinstance(placements, list) or not placements:
            raise ValueError("Plan must be a nonempty array of {window, workspace, rect?}")
        state = snapshot(ids=[p["window"] for p in placements])
        windows = {w["id"]: w for w in state["windows"]}
        changes = []
        for p in placements:
            w = windows[p["window"]]
            d = space_at(state, p["workspace"])
            c = {**identity(w), "toSpace": d["id"]}
            if len(w["spaces"]) == 1:
                c["fromSpace"] = w["spaces"][0]
            if "rect" in p:
                c["frame"] = normalized_rect(p["rect"], d["frame"])
            changes.append(c)
        result = apply_changes(changes, args.dry_run)
    else:
        if not args.app and not args.windows:
            raise ValueError("Specify --app or explicit --windows; never target the current front window implicitly")
        if PROTECTED in args.app:
            raise ValueError("WeChat is protected")
        state = snapshot(args.app, args.windows)
        dest = space_at(state, args.workspace)
        if args.require_empty and dest["count"]:
            raise ValueError(f"Desktop {args.workspace} is occupied")
        selected = state["windows"]
        if args.windows:
            selected = [w for w in selected if w["id"] in args.windows]
            if len(selected) != len(set(args.windows)):
                raise ValueError("Some requested window IDs are unavailable")
        if args.from_workspace is not None:
            source = space_at(state, args.from_workspace)
            selected = [w for w in selected if w["spaces"] == [source["id"]]]
        elif not args.windows:
            selected = [w for w in selected if w["spaces"] == [dest["id"]]]
        if args.command == "move" and not args.windows and args.from_workspace is None:
            raise ValueError("move requires explicit --windows or --from-workspace")
        if not selected:
            raise ValueError("No matching ordinary windows in the specified workspace")
        if getattr(args, "main", None):
            if args.main not in [w["id"] for w in selected]:
                raise ValueError("--main is not one of the selected windows")
            selected.sort(key=lambda w: w["id"] != args.main)
        if args.command == "arrange":
            frames = rectangles(len(selected), dest["frame"], args.layout, args.ratio, args.gap, args.margin, args.columns)
        elif args.command == "place":
            if len(selected) != 1:
                raise ValueError("place requires exactly one selected window")
            frames = [normalized_rect([float(n) for n in args.rect.split(",")], dest["frame"])]
        else:
            frames = [None] * len(selected)
        changes = []
        for w, f in zip(selected, frames):
            if len(w["spaces"]) != 1:
                raise ValueError(f"Window {w['id']} is not in one ordinary workspace")
            c = {**identity(w), "fromSpace": w["spaces"][0], "toSpace": dest["id"]}
            if f:
                c["frame"] = f
            changes.append(c)
        result = apply_changes(changes, args.dry_run)
    print(json.dumps(result, ensure_ascii=False, indent=2))


def normalized_rect(values, f):
    if len(values) != 4:
        raise ValueError("rect requires four numbers")
    x, y, w, h = values
    if min(x, y) < 0 or min(w, h) <= 0 or x + w > 1.00001 or y + h > 1.00001:
        raise ValueError("Normalized rectangle must fit within [0,1] x [0,1]")
    return dict(x=round(f["x"] + x * f["width"]), y=round(f["y"] + y * f["height"]),
                width=round(w * f["width"]), height=round(h * f["height"]))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, KeyError, subprocess.SubprocessError, OSError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
