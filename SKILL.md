---
name: workspace-layout
description: Arrange, move, tile, and open document windows in the background across macOS Spaces. Use for organizing desktops, adjusting window gaps or primary-window sizes, and preparing a workspace for the user to visit when ready.
---

# Workspace Layout

Use [scripts/workspace_layout.py](scripts/workspace_layout.py) with Python 3. Resolve its path relative to this skill. The user's instructions determine which applications, windows, files, and workspaces you may change.

1. Run `list` with `--app <bundle-id>` or `--windows <id,id>` to identify the authorized windows and the destination. Use `--titles` only if document names are needed. Use the returned Desktop `index` for `--workspace` and `--from-workspace`. Obtain fresh IDs when the desktop arrangement changes.
2. Use `move` to relocate windows and `arrange` to tile them. `--from-workspace` scopes the source. `--require-empty` checks that the destination has no ordinary windows. For in-place tiling, specify the existing workspace and the app or window IDs. Use `--dry-run` when a placement needs review.
3. Choose readable window sizes. `--main` selects the primary window for `main-left` or `main-right`, `--ratio` sets its share, and `--gap` and `--margin` set spacing in points. Use `grid`, `columns`, or `rows` for parallel views. For an existing left-one/right-two arrangement, a `main-left` ratio of `.39` gives more room to the two windows on the right.
4. Check the resulting Spaces and bounds in `results`. Compare `context_unchanged` and, for document opening, `open_context_unchanged`. A changed context can reflect user activity. Leave the user's focus where it is. If background placement is unavailable or incomplete, explain the concrete blocker before any foreground intervention.

`open` takes a local `--file`, an `--app`, and an inactive `--workspace`. Use `--arrange-existing` when the user also wants to tile existing windows of that app there. To reuse one existing window's rectangle, pass `--slot-of <window-id>` and `--park-workspace <empty-desktop-index>`. The displaced document remains open. The command checks for target app windows visible on active Spaces before temporarily hiding the app.

`place --rect x,y,width,height` sets one window's rectangle. `apply --plan path.json` accepts entries like `[{"window":1234,"workspace":2,"rect":[0,0,0.6,1]}]`. Rectangles are relative to the display's usable frame. Omit `rect` for a move without resizing.

Keep the user's normal work uninterrupted. Use scoped metadata and background placement, and let the user switch to the prepared Space. Follow their app exclusions and privacy limits. See [the README](README.md) for examples and [the backend notes](references/backend.md) when investigating compatibility.
