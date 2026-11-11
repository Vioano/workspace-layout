# Workspace Layout

让 Agent 在后台定位、分配和平铺 macOS 窗口，你继续打字、看视频或使用其他软件。给出应用、workspace 和布局参数后，本地服务负责寻找真实窗口、执行和回读结果。

[English](README.md) · [Skill](SKILL.md) · [实现说明](references/backend.md)

## 用途

- 在原 workspace 平铺已授权窗口，设置主窗口、比例、间距和边距。
- 将明确授权的任务窗口移到已确认空闲且不活跃的 workspace。
- 一条命令改变主次，无须拖拽或反复找窗口。
- 本地缓存 workspace、窗口身份、归属、层级、顺序和几何信息；不缓存窗口正文或标题。
- 回读实际位置、尺寸和前台状态，记录真实完成耗时。

不发送键鼠事件、不截图、不切换 workspace、不激活应用。微信窗口改动被直接拒绝。窗口类型由层级和几何信息判断，不能冒充系统无障碍角色。

## 后台服务的隐私范围

缓存/API仅含应用名称和bundleID、进程/窗口ID、Space归属、坐标尺寸、层级顺序、透明度、屏幕可见状态，以及按几何/层级推断的类型。另有防止抢焦点所需的当前前台应用/Space和性能计数。它不缓存或返回窗口标题、网页URL、文档路径、正文、截图、视频内容或键盘输入。应用名称是软件名称，不是正在阅读的文档或标签页标题。

后台API没有任意native命令转发；明确授权的单窗口诊断与自动轮询分开。缓存留在本机内存，AX token文件仅含进程/窗口/元素ID，不打开网络端口或遥测上传。现有采集范围已符合这一边界。

## 安装与使用

需要 Python 3、Xcode Command Line Tools、交互式 macOS 桌面，以及调用宿主已有的辅助功能权限。首次使用编译本机 helper。不会修改系统偏好或隐私权限。

```sh
git clone https://github.com/Vioano/workspace-layout.git "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout"
layout() { python3 "${CODEX_HOME:-$HOME/.codex}/skills/workspace-layout/scripts/workspacectl.py" "$@"; }
layout state --app com.microsoft.Powerpoint
layout arrange --workspace keep --app PowerPoint --layout main-right --main rightmost --ratio .60
layout arrange --from-workspace 5 --workspace auto --app com.microsoft.Powerpoint --task presentation-review
```

`auto` 自动预留已确认空闲且不活跃的桌面，不切换用户桌面。默认间距4点、边距12点、主窗口比例.55。`--main` 可用窗口ID或 leftmost、rightmost、topmost、bottommost、newest。用 `--windows 1234,1235` 精确限定窗口。Desktop序号来自 `state`，不等于底层Space ID。

客户端自动启动每用户持久后台服务，使用权限0600的Unix socket，不开放网络端口。`status` 查看状态，`stop` 只停止本服务。无需为每个项目启动另一套服务。

检查 `ok`、`results`、`completion_scope`、`context_unchanged`、`client_elapsed_ms`、`deadline_met`。只有真实位置和尺寸回读成功才算布局完成；本机完整调用超过1000毫秒就标为未达标，不能拿排队回执冒充完成。

应用名、bundle ID或bundle尾段按不区分大小写的精确匹配解析；不唯一则返回候选。`keep` 自动确定所选窗口的原workspace，跨多个workspace时返回候选，不随便搬动。

## 新窗口与弹窗

打开应用、文件、新窗口，或执行预期可能出现弹窗的操作，必须**先绑定目标 workspace**。弹出后再搬走仍算打扰用户。仅设置 `activates=false` 或隐藏应用，已经在测试中证明不足以保证这一点。

`prepare --workspace N --app <bundle-id> --pid <owned-worker-pid>` 可为专用后台进程提交归属绑定。它会拒绝已有其他workspace窗口的共享进程。返回 `ready_for_window_creation:false` 是有意的：受控应用适配器还须验证新窗口行为、原生文档身份和加载状态。

旧版通用 `open` 已禁用，它采用创建后搬移。任意第三方软件的无打扰打开尚未有通用保证；需要受控应用接口或文件处理路径。窗口放置成功不代表文件完整加载、可操作或导出成功，各阶段分别验证和计时。

## 所有项目的默认入口

在用户级 `~/.codex/AGENTS.md` 索引本 skill，并要求其他软件操作前使用它。例外是明确隔离这些上下文的项目。文档不能强制其他工具遵循规则，实际宿主是否加载约定仍需验证。

遇到技术问题由 Agent 自行排障、切换接口并继续独立工作，不让用户代切workspace或前置窗口。已有执行授权持续有效。若确需前台接管，只协调授权边界，获准后由Agent执行。隐私、微信和不抢焦点的限制保持有效。

## 两种速度分别验收

程序执行速度不等于Agent冷上手速度。AGENTS顶部的短入口与skill快速用法，让新Agent只需应用名和`keep`即可操作，无需事先知道窗口ID或桌面编号。

真正无历史的Luna测试仅收到AGENTS文件位置与自然语言任务：一次批量读文档、一次正确操作，零源码/截图/窗口探路。派发到首次操作34.530秒（含模型、编排、网络，未单独拆分）；程序完整调用286.883毫秒。两者分别记录，不拿程序耗时冒充Agent反应速度。此前给了ID和workspace的Luna试验只证明执行，不证明冷上手。

## 验证边界

已在 Apple silicon、macOS 27.0 上测试窗口适配器。跨Space依赖私有接口，系统更新后须复查。辅助功能支持、应用最小尺寸和加载时间会影响结果。性能测试只证明其实际fixture和负载；不声称任意应用启动、文件加载或导出都能在一秒内完成。仅比较前后焦点也不能证明中途没有变化，失败样本必须保留。

最新受控测试：100/100次真实布局完成且低于一秒，中位178.505毫秒、最大225.476毫秒；空闲占单核0.854%，daemon与helper合计峰值约41.4MB。首次安装新编译helper后的启动曾耗时1223.109毫秒，未达标；保留在[完整测试记录](references/benchmark-results.md)，不混入热调用通过结果。

[MIT许可证](LICENSE) · [第三方来源](THIRD_PARTY_NOTICES.md)
