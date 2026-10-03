---
name: add-agent-support
description: 给 DockTouchBar Vibe 增加对一个新的 AI 编程助手（Claude Code、Codex 之外，比如 Gemini CLI、Cursor 等）的支持，或调整图标上的状态动画（字符雨、OK、CRT 屏幕外框）。只在 vibecoding 分支做。
---

# 给 Vibecoding 版接入一个新助手 / 调整状态动画

只在 `vibecoding` 分支做，不动 `main`（纯净版）。先 `git branch --show-current` 确认。

## 它是怎么工作的（别重新发明）

1. 助手的 **hook** 在开始、工具调用后、做完、会话结束、被打断时执行 `~/Library/Application Support/DockTouchBarVibe/agent-hook.sh <事件名>`。
2. 脚本把 `事件名 \t 父进程号 \t 助手传来的 JSON` 一行写进 Unix socket。
3. `AgentMonitor`（`AgentStatus.swift`）从父进程号一路往上找到第一个有 Dock 图标的 App（终端、VS Code、ChatGPT/Codex 桌面版……），按 App 汇总状态：`idle` / `working` / `done`。
4. `DockModel` 把状态写进 `DockTile.agentState`，`DockTileView` 把它交给 `AgentOverlayLayer`（`AgentOverlay.swift`）画动画。**动画和状态机跟具体助手无关，接新助手不用改它们。**

## 接入一个新助手：步骤

1. **查它的 hook 机制**（先查官方文档，再用本机实测）：配置文件路径和格式、有哪些事件、stdin 里有没有 `session_id`、`Stop` 是每轮触发还是整个会话结束才触发、有没有“被打断”事件、**hook 是否要用户先审核/信任**（Codex 要）、桌面版是否也读同一个配置。不要凭记忆写，查完把结论写进下面第 3 步的注释。
2. **本机实测 hook 会不会触发**：在临时目录写一个只记录 stdin 的脚本（见 `docs/` 里的做法），跑一次最小的助手任务，看事件和字段。注意：`codex exec` 要 `< /dev/null`，否则会卡在等 stdin；会占用用户的额度，只跑一句话的任务。
3. **在 `AgentIntegration.swift` 里加一条** `AgentIntegration(id:name:configPath:events:afterConnectNote:)`，把它加进 `all`。配置格式如果不是“顶层 `hooks` → 事件名 → 分组数组 → `hooks` 数组 → command”这一种，要先扩展 `AgentHookInstaller`（并先补测试）。事件名映射成 App 认的几类语义：`UserPromptSubmit`（开始）、`PostToolUse`（心跳）、`Stop`（做完）、`SessionEnd`（结束）、`Interrupt`（被打断）；名字不一样就在 `AgentMonitor.handle` 里加别名。
4. **需要用户做的一步**（比如审核信任 hook）写进 `afterConnectNote`，设置页会显示。**不要替用户伪造信任或绕过审核**，这是安全边界。
5. **跑验证**：`bash tools/verify-agent-hooks.sh`（必须 `RESULT failures=0`）。新助手会自动被测试覆盖（安装、卸载、保留原配置、坏文件不动、旧脚本迁移）；它特有的行为（比如事件别名）在 `tools/verify-agent-hooks/main.swift` 里补用例。
5b. **Codex 排查**：`python3 tools/check-codex-hooks.py` 问 Codex 我们的 hook 是什么状态（只读）；不是 `trusted` 的它不会执行。另外 App 会把收到的事件记进 `~/Library/Application Support/DockTouchBarVibe/events.log`，没有新行 = hook 没执行，有行但 `app=-` = 进程链没找到 App。
6. **实机连一次**：`bash scripts/install.sh`，在设置里看到“已连接”，让助手干点活，看对应 App 的图标。进程链找不到 App 时，用 `ps -o pid,ppid,comm -p <pid>` 沿父进程往上看实际是谁。
7. **更新** `docs/` 里的记录，提交到 `vibecoding`，需要发版按 `docs/BRANCHES.md`（标签 `vibe-v*`，发布加 `--latest=false`）。

## 调整图标上的动画 / 外观

所有绘制在 `AgentOverlay.swift`，全部是**设备像素级手绘**（Touch Bar 图标只有 56 像素宽，字体渲染会糊）：

- 字符雨：`glyphBitmaps`（5×7 点阵）、`stripVariants/drawStrip`（雨头发光、尾巴曲线渐隐、字符跳变）。
- CRT 屏幕外框：`crtFrame(of:)`，按“离图标边缘几个像素”分层（机身边、玻璃边、内阴影、左上角反光），所以自动贴合任何圆角。
- 8-bit 原图标：`pixelated(_:)`（28×28 格、64 色）。
- OK：`okImage()`（5×7 点阵，每点 1pt）。

**出图流程（每次改完都跑）**：

```bash
swift build 2>&1 | grep -E "error|Build"
bash tools/preview-agent.sh build/agent-preview.png   # 实时窗口截图，已放大，用 Read 打开看
```

看图要点：原图标认不认得出、字符雨密度和亮度、`OK` 在绿色/白色图标上的对比度、边框是否贴合圆角。静态截图看不出动画流畅度和光标闪烁，要说清楚“没看到动画”，让用户在真 Touch Bar 上确认。

App 图标：改 `scripts/make-icon.swift` 后 `bash scripts/make-icon.sh`，再 Read `Resources/AppIcon-1024.png` 检查。

## 提交前

- `swift build` 通过、`bash tools/verify-agent-hooks.sh` 全 PASS。
- `bash scripts/install.sh` 装到 `/Applications/DockTouchBarVibe.app`，确认进程在跑。
- 纯净版在运行时 Vibecoding 版会提示并退出（两者抢 Touch Bar）；测试前先退出纯净版。
