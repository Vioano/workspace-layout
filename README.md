# Workspace Layout

A Codex skill and lightweight local service for arranging macOS windows while the user keeps working. An agent specifies the app, desktop and layout in one call. The service resolves window identities, reserves an empty inactive Space when requested, applies the layout, and reads back the actual result.

[简体中文](README.zh-CN.md) · [Skill](SKILL.md) · [Backend](references/backend.md)

## What it does

- Tile authorized windows in their current workspace, with a primary window and adjustable split, gaps and margins.
- Move explicitly selected task windows to a confirmed empty inactive workspace.
- Change which window is primary without dragging or searching again.
- Cache workspace and window metadata locally: ownership, Space membership, bounds, layer, z-order and a geometry-based window-type classification.
- Report actual completion time, verified geometry and whether foreground application and active Spaces changed.

It sends no keyboard or mouse events and takes no screenshots. WeChat window changes are blocked. Window titles and UI contents are absent from the service cache.

## Privacy of the background service

The cache/API contains application names and bundle IDs, process/window IDs, Space membership, window coordinates and dimensions, layer/z-order, alpha, on-screen status and a geometry-based type. It also records the current foreground app/Space to protect focus, plus service timing/resource counters. It does not cache or return window titles, webpage URLs, document paths, text, screenshots, video content or keyboard input. Application names identify software, not the document or browser-tab title.

The service has no arbitrary native-command passthrough. Explicit, separately scoped diagnostic helpers are not part of its polling/API. The cache stays in local memory; the AX-token file contains only process/window/element IDs. No network port or telemetry endpoint is opened by this service.

## Install

Requires an interactive macOS desktop, Python 3, Xcode Command Line Tools, and existing Accessibility permission for the calling host. The native helper compiles on first use. Private macOS APIs are used for Space membership and movement; compatibility must be checked after OS updates.

```sh
git clone https://github.com/Vioano/workspace-layout.git "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
python3 "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout/scripts/workspacectl.py" start
```

The client starts a per-user background service when needed. Its Unix socket is local, permission 0600; it does not listen on a network port. `stop` ends only this service. No login item, system preference or privacy permission is changed.

## One-call layouts

Run from any project directory. Resolve the installed skill path once.

```sh
layout() { python3 "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout/scripts/workspacectl.py" "$@"; }

# Inspect only the authorized application's metadata.
layout state --app com.microsoft.Powerpoint

# Resolve the app and its existing workspace without window IDs.
layout arrange --workspace keep --app PowerPoint \
  --layout main-left --main rightmost --ratio .60 --gap 4

# Relocate explicitly authorized task windows from Desktop 5.
# auto selects an empty inactive desktop; it does not switch to it.
layout arrange --from-workspace 5 --workspace auto --app com.microsoft.Powerpoint \
  --layout main-left --task presentation-review

# Use exact window IDs when the task identifies individual documents.
layout arrange --workspace 2 --windows 1234,1235,1236 \
  --layout main-right --main 1235 --ratio .55 --gap 4 --margin 12
```

`--app` accepts an exact application name, bundle ID, or bundle suffix (case-insensitive). An ambiguous name returns candidates. `--workspace keep` requires the selected windows to occupy one ordinary Space; multiple Spaces return candidates without moving them.

Desktop indices come from `state`; they are not macOS Space IDs. `--dry-run` returns the plan. `--require-empty` refuses an occupied destination. `move` preserves sizes. `--main` accepts an exact ID or leftmost, rightmost, topmost, bottommost, newest. Reservations default to the project directory; `--task` shares a named reservation across directories.

Inspect `ok`, `results`, `completion_scope`, `context_unchanged`, `client_elapsed_ms` and `deadline_met`. A successful geometry operation includes actual destination and rectangle readback. The client marks a call over 1,000 ms as missing the deadline, even if it eventually completes. This timing includes the local client and service work; model and network time are outside it. A queued request, reservation or submitted process binding is not completion.

## New windows and dialogs

A destination must be bound **before** triggering a new application window, document window or expected dialog. Moving it afterward still interrupts the user. `activates=false` and hiding an application did not provide this guarantee in testing.

`prepare --workspace N --app <bundle-id> --pid <owned-worker-pid>` submits a process-to-Space binding for a dedicated inactive worker. It refuses a process with existing windows elsewhere. The response deliberately keeps `ready_for_window_creation:false`: the application adapter must verify creation behavior, native document identity and load state before claiming readiness.

The old generic document `open` command is disabled because it used placement after creation. There is no universal safe-open guarantee for arbitrary third-party applications. A controlled application API or file-processing route is required. Native document loading and export have separate completion states and timings; placing a window does not prove that the document is usable.

## Agent integration

Add to the user-level `AGENTS.md` (normally `~/.codex/AGENTS.md`):

> Before authorized macOS app/window automation, use the workspace-layout skill. Prefer its persistent workspacectl entry, with explicit app/window scope, workspace and layout parameters. Keep the user's current Space, input focus and view uninterrupted. Bind a destination before creating windows or expected dialogs; reservations and submitted bindings are not proof. Verify final state and report actual timing. Resolve technical failures without asking the user to switch desktops or foreground windows. Never target WeChat or inspect unrelated content.

User instructions still define authorization. The service cannot force unrelated tools or agents to follow a document, and AGENTS loading must be verified in the host. A project that deliberately isolates those instructions is outside this routing rule.

## Agent onboarding speed

Program latency and agent readiness are different measurements. The user-level AGENTS quick index points a fresh agent to this skill; its quick start accepts an app name and `keep`, so the agent need not discover bundle IDs, window IDs or desktop numbers.

A fresh-context Luna trial received only the AGENTS path and a natural-language task. It made one batched documentation read and one successful action, with no source search, screenshot or preliminary window lookup. Dispatch to first action took 34.530 seconds including model/orchestration/network time, which was not separately measured. The complete command took 286.883 ms. A fast command must not be presented as an instant agent response. Detailed briefings in earlier Luna trials are not cold-onboarding evidence.

## Compatibility and verification

The native adapter has been exercised on Apple silicon, macOS 27.0. It validates window PID, bundle ID and source Space before mutation. Accessibility resize support depends on the target app and its minimum window size. Window type is a layer/geometry heuristic, not an authoritative Accessibility role. Before/after focus equality alone cannot prove that no transient change occurred; tests must retain failures and state the observation method.

Latest controlled test: 100/100 completed layouts, median 178.505 ms, maximum 225.476 ms; idle daemon plus helper used 0.854% of one core and about 41.4 MB combined peak RSS. These are fixture measurements on one Mac. [All runs and failures](references/benchmark-results.md) remain available. A first startup after copying a rebuilt helper took 1,223.109 ms and missed the target; installation/cold costs are not hidden in the warm result.

See [tests](tests/) for service regression checks. Performance measurements are bounded to their actual fixture and workload; they are not a promise that every application can launch, load a document or export within one second.

Released under the [MIT License](LICENSE). [Third-party notices](THIRD_PARTY_NOTICES.md) attribute the SkyLight symbol lookup to yabai.
