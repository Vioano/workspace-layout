# Workspace Layout

Workspace Layout 是用于 macOS 的 Codex skill 和本地命令行工具。你可以继续使用当前应用，让助手在另一个 workspace 里准备窗口。排好以后，由你自己切过去查看。

[English](README.md) · [Skill 使用说明](SKILL.md)

- 按窗口 ID 或应用移动窗口，也可以在原 workspace 内平铺。
- 调整主窗口、分栏比例、缝隙和边距。比如左边的 PPT 看完后，把右边两份一起加宽。
- 在后台打开指定文件。新文件可以占用原来的主窗口位置，旧窗口移到空闲 workspace，文档继续保持打开。
- 用 JSON 为多个窗口分别指定 workspace 和矩形位置。

## 不打扰用户正常使用

操作以任务授权的应用、窗口和文件为范围。工具在后台读取窗口元数据并调整位置，整个流程无需截图、模拟键鼠、切换用户的 workspace 或激活应用。完成后回读窗口所在空间、实际位置和大小，同时比较操作前后的当前 workspace 与前台应用。

后台打开文件可能要短暂隐藏目标应用，避免它的新窗口出现在用户面前。目标 workspace 必须在后台，工具也会先检查目标应用是否在当前可见的 workspace 上有窗口。新窗口到达目标后恢复应用原有的可见状态。如果打开失败且恢复可见会让窗口出现在用户面前，应用可能保持隐藏。工具拒绝更改微信窗口。

## 安装与使用

需要可交互的 macOS 桌面、Python 3 和 Xcode Command Line Tools。第一次运行会用 `clang` 编译本地辅助程序。若 macOS 要求授权，请给运行命令的终端或 agent 宿主授予「辅助功能」权限，以便调整窗口大小或应用的可见状态。

```sh
git clone https://github.com/Vioano/workspace-layout.git "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
cd "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
python3 scripts/workspace_layout.py list --app com.microsoft.Powerpoint
```

把 `list` 返回的 Desktop `index` 传给 `--workspace`，用实际窗口 ID 替换示例值。下面把三个 PPT 排成左一右二，右侧约占六成，窗口间距为 4 点。

```sh
python3 scripts/workspace_layout.py arrange --workspace 2 \
  --windows 1234,1235,1236 --layout main-left --main 1234 --ratio .39 --gap 4
```

可先加 `--dry-run` 查看摆放计划。后台打开新文件、替换主窗口位置及自定义矩形的例子见 [英文 README](README.md#examples)。

想让 Codex 在整理窗口时使用这个 skill，可以在用户级 `AGENTS.md` 加入下面这段。

> 已授权的 macOS 窗口移动、平铺和后台打开文件，使用 workspace-layout skill。先确认目标窗口和 workspace，保持我当前的 workspace 和输入焦点。只读取任务需要的窗口元数据，排好以后由我自己切过去。后台操作遇到阻碍时，说明具体原因，在接管前台前先与我协调。

已在 Apple silicon 的 macOS 27.0 上验证移动、平铺和 PowerPoint 后台打开。跨 workspace 移动使用 macOS 私有接口，系统升级后可用性可能变化。参阅[实现说明](references/backend.md)和 [MIT 许可证](LICENSE)。
