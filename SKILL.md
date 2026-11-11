---
name: workspace-layout
description: Background macOS window placement without switching the user's Space or focus. Use before native desktop automation; identify apps by name and keep their workspace in one call. Files, connectors and browser DOM tasks need no desktop scan.
---

# Workspace Layout

## Quick start

A self-contained window request uses live runtime state. Do not search project history or memory to identify current windows or learn this command.

Choose the route before opening or observing a native window:

| Task | Route |
| --- | --- |
| Files, connector, or content API | Use that interface directly; no desktop scan. |
| Browser page | Use the in-app browser, scoped to the authorized tab. |
| Inspect current window distribution | `state --app "Name"`; returns metadata without titles or content. |
| Move or tile existing native windows | Call the command below directly. The tool resolves names, IDs, workspace and final geometry. |
| Create a native window or expected dialog | Bind its destination before triggering it; see the boundary below. |

Ordinary layout recipes are complete here; do not run `--help`, inspect source, or query windows to reconfirm them:

- Equal-width side by side: `--layout columns`.
- Equal-height stacked: `--layout rows`.
- One large window beside smaller ones: `--layout main-left` or `main-right`, plus `--main`.

The tool counts selected windows. `columns` needs no `--columns N`; that option only customizes a grid.

For “make the right window more important”, one call suffices:

```sh
python3 "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout/scripts/workspacectl.py" arrange --workspace keep --app "PowerPoint" --layout main-right --main rightmost --ratio .60
```

Replace the app name with the authorized app. No bundle ID, window ID, desktop number, source inspection, preliminary screenshot or separate `state` call is needed when its windows occupy one workspace. `keep` preserves that workspace. Ambiguous app names or multiple workspaces return candidates; use scoped `state --app "Name"` only when needed. Never guess or switch desktops to discover them.

Set only the needed parameters: `--layout auto|main-left|main-right|columns|rows|grid`, `--main leftmost|rightmost|topmost|bottommost|newest|ID`, `--ratio .20..80`. Default gap is 4 points, margin 12. Preserve known spacing. For explicitly authorized relocation, use `--workspace N`, or `--from-workspace N --workspace auto` for a confirmed empty inactive desktop. Desktop indices are not Space IDs.

The service starts automatically. Read `ok`, `results`, `context_unchanged`, `client_elapsed_ms`, `deadline_met`, and `completion_scope`. Success must include actual geometry/Space readback; a queued request is not completion. Do not read implementation or other references for a normal successful call.

## Boundaries

Never activate/raise apps, switch Spaces, send global input, or capture unrelated content as a fallback. Never target WeChat (`com.tencent.xinWeChat`); its presence does not block other apps. Only authorized apps, windows and files are in scope.

New windows and expected dialogs must be bound **before** the trigger. A reservation, process assignment, `activates=false`, or hiding does not prove safe creation. Generic `open` is disabled. Use a verified application adapter or file-processing route; resolve technical failures without asking the user to foreground a window or switch desktops. Read [backend details](references/backend.md) only when implementing such an adapter or diagnosing an actual failure.

A context change during a batch stops remaining changes. Read scoped state and handle the affected step without blindly replaying or restoring an earlier focus. A different earlier snapshot alone does not prove focus theft; before/after equality also does not exclude a transient change. Keep failed and over-one-second results.

Measure two things separately: native execution latency, and a fresh agent's time/tool calls from task receipt to its first correct action. A fast command after a detailed briefing proves only the first. See [measured scope and failures](references/benchmark-results.md) when reporting performance, not before ordinary operation.
