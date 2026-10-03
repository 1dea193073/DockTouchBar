import Foundation

/// 一个 AI 编程助手怎么接进来：它的 hook 配置文件在哪、订阅哪些事件、第一次用要注意什么。
/// 支持新的助手 = 在 `AgentIntegration.all` 里加一条（流程见 .claude/skills/add-agent-support）。
struct AgentIntegration: Identifiable {
    let id: String
    let name: String
    /// 相对用户主目录的 hook 配置文件（JSON，顶层 `hooks` 对象：事件名 → 分组数组 → `hooks` 数组 → command）。
    let configPath: String
    /// 要订阅的事件。App 只认下面这几类语义：
    /// `UserPromptSubmit` 开始、`PostToolUse` 心跳、`Stop` 做完、`SessionEnd` 会话结束、`Interrupt` 被用户打断。
    let events: [String]
    /// 连接之后用户还要做的一步（比如在助手里审核并信任 hook），显示在设置页里；不需要就是 nil。
    let afterConnectNote: (() -> String)?

    static let claudeCode = AgentIntegration(
        id: "claude", name: "Claude Code", configPath: ".claude/settings.json",
        events: ["UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"], afterConnectNote: nil)

    /// Codex（命令行和桌面版共用 ~/.codex）。它会先让用户审核 hook、信任之后才执行，所以连接后要在 Codex 里信任一次（桌面版：设置 → Hooks → Trust all；命令行：/hooks）。
    static let codex = AgentIntegration(
        id: "codex", name: "Codex", configPath: ".codex/hooks.json",
        events: ["UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd", "Interrupt"],
        afterConnectNote: {
            L10n.tr("Codex 要你先审核再信任 hook，没信任之前不会发事件。打开 ChatGPT 的设置 → Hooks，点“全部信任”（命令行版：运行 codex，输入 /hooks），然后重启 ChatGPT。已经信任过就不用管。",
                    "Codex needs you to review and trust hooks before they run, so no events are sent until then. Open ChatGPT's Settings → Hooks and click “Trust all” (CLI: run codex and type /hooks), then restart ChatGPT. Skip this if you've already trusted them.")
        })

    static let all: [AgentIntegration] = [claudeCode, codex]
}
