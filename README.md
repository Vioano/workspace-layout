# Workspace Layout

Workspace Layout is a Codex skill and local CLI for arranging windows across macOS Spaces. It lets an agent prepare a workspace while you keep working in your current app. Switch to the prepared desktop yourself when you are ready.

[简体中文](README.zh-CN.md) · [Skill instructions](SKILL.md)

| Task | What it does |
| --- | --- |
| Organize windows | Move selected windows to a specific desktop or tile them where they are. |
| Change the emphasis | Give one window more room or widen the pair next to it. Set the split, spacing, and margins independently. |
| Prepare a document | Open a local file on another desktop. Reuse an existing window's position and move the old window to an empty desktop while keeping its document open. |
| Place windows precisely | Give individual windows a custom rectangle and destination in a JSON plan. |

## Keep the user's desktop usable

Every change targets a window ID or an explicitly selected application and workspace. The CLI uses window metadata and Accessibility to place windows in the background. It sends no keyboard or mouse events, takes no screenshots, and does not switch Spaces or activate the target application. Results include the observed window positions and whether the active Spaces and foreground app matched before and after the operation.

Opening a file has a broader effect because the target app may need to be hidden briefly while macOS creates its window. The command requires a destination outside the active Spaces and checks for visible windows of the app on those Spaces before hiding it. Once the new windows reach their destination, it restores the app's prior visibility. An unsuccessful open can leave the app hidden if restoring it would expose windows on the current desktop. WeChat window changes are blocked.

## Install

Use an interactive macOS desktop, Python 3, and the Xcode Command Line Tools. The first run compiles the native helper with `clang`. Grant Accessibility to the terminal or agent host running the tool if macOS requires it for resizing or changing app visibility. The CLI reports the available capabilities in `list`.

Window movement, tiling, and PowerPoint document opening were exercised on Apple silicon with macOS 27.0. Cross-Space movement uses private macOS interfaces, so availability can change with system updates. `bridgedMoveAvailable` reports whether the interface is present. The tool checks each requested move against the resulting Space.

```sh
git clone https://github.com/Vioano/workspace-layout.git "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
cd "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
python3 scripts/workspace_layout.py list
```

Add this instruction to your user-level `AGENTS.md` if you want Codex to use the skill for window tasks.

> Use the workspace-layout skill for authorized macOS window movement, tiling, and background document opening. Identify the target windows and Space first. Keep my current desktop and input focus available, and let me switch to the prepared workspace myself. Read only the window metadata needed for the task. If background operation is unavailable, report the blocker before attempting anything that would interrupt my work.

## Examples

From the checkout, define a short command for this shell session.

```sh
layout() { python3 scripts/workspace_layout.py "$@"; }
layout list --app com.microsoft.Powerpoint
```

Use the Desktop `index` from `list` for `--workspace`. Replace the sample indices and window IDs below with values from your desktop. Add `--dry-run` to preview changes. Add `--titles` to `list` only when you need to identify particular documents.

```sh
# Move a presentation workspace from Desktop 5 to an empty Desktop 2 and tile it.
layout arrange --from-workspace 5 --workspace 2 --app com.microsoft.Powerpoint \
  --require-empty --layout main-left --main 1234 --ratio .55 --gap 4

# Widen the two windows on the right and keep the left window as a reference.
layout arrange --workspace 2 --windows 1234,1235,1236 \
  --layout main-left --main 1234 --ratio .39 --gap 4

# Put a new deck in the old main window's rectangle and park the old deck.
layout open --workspace 2 --app com.microsoft.Powerpoint --file ./next-deck.pptx \
  --slot-of 1234 --park-workspace 8
```

Use `move` to keep existing window sizes, `place` for a single custom rectangle, or `apply --plan` for a set of placements. `--help` on each subcommand lists its options. See the [skill instructions](SKILL.md) for the plan format and [implementation notes](references/backend.md) for compatibility and recovery details.

Released under the [MIT License](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution to yabai.
