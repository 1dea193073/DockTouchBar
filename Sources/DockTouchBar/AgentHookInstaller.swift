import Foundation

/// 转发脚本 `agent-hook.sh`：所有智能体（用自己的 hook，或按指令手动）都通过它把事件交给 App。
/// 配置怎么改由智能体自己按“配对智能体”提示词去做，App 不再替任何一个助手改配置。
enum AgentHookInstaller {
    static var supportDirectory: URL { AgentMonitor.supportDirectory }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("agent-hook.sh") }

    /// 把脚本写成当前版本（App 每次启动都写一遍）。
    static func refreshScript() throws {
        let script = """
        #!/bin/bash
        # \(AppInfo.name): forwards AI agent events to the app. Does nothing (and never fails) if the app isn't running.
        # Usage: agent-hook.sh <Event> [agent-id] [session-id] < /dev/null
        #   Event: UserPromptSubmit | PostToolUse | Stop | Interrupt | SessionEnd
        # Agents with their own hooks pipe the hook JSON on stdin; agents that call this by hand pass a session-id instead.
        SOCK="$HOME/Library/Application Support/\(AppInfo.fileName)/agent.sock"
        [ -S "$SOCK" ] || exit 0
        EVENT="$1"
        case "$2" in ""|*[!A-Za-z0-9._-]*) ;; *) EVENT="$1|$2" ;; esac
        PAYLOAD=""
        [ -t 0 ] || PAYLOAD="$(/bin/cat | /usr/bin/tr -d '\\n\\r')"
        case "$3" in ""|*[!A-Za-z0-9._-]*) ;; *) [ -n "$PAYLOAD" ] || PAYLOAD="{\\"session_id\\":\\"$3\\",\\"manual\\":true}" ;; esac
        printf '%s\\t%s\\t%s\\n' "$EVENT" "$PPID" "$PAYLOAD" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0
        """
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        // 早期版本的脚本，没人用了。
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("claude-hook.sh"))
    }
}
