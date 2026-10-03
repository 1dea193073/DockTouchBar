import Foundation

/// 把 hook 装进 Claude Code 的 `~/.claude/settings.json`（用户在设置里点按钮才会装），并能原样卸掉。
///
/// - 只增删带我们脚本路径的那几条，其余配置原样保留；改之前先备份。
/// - 文件不是合法 JSON 时一个字也不动，直接报错。
enum AgentHookInstaller {
    /// 订阅的 Claude Code 事件：提交提问＝开始，工具调用后＝心跳，Stop＝做完，SessionEnd＝会话结束。
    private static let events = ["UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]

    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")
    static let scriptURL = AgentMonitor.supportDirectory.appendingPathComponent("claude-hook.sh")

    struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    static var isInstalled: Bool {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: isOurs) == true
        }
    }

    static func install() throws {
        var root = try loadForWriting()
        try writeScript()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append(["hooks": [["type": "command", "command": "\"\(scriptURL.path)\" \(event)", "timeout": 5]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root)
    }

    /// 已连接时，把 hook 脚本重写成当前版本的内容（不动 settings.json）。
    static func refreshScript() throws { try writeScript() }

    static func uninstall() throws {
        var root = try loadForWriting()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - 内部

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(scriptURL.path) == true
        } == true
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 读出现有配置并备份。文件不存在算空配置；读不懂就报错，不覆盖用户的文件。
    private static func loadForWriting() throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError(errorDescription: L10n.tr("~/.claude/settings.json 不是有效的 JSON，没有改动它。先修好这个文件再试。",
                                                         "~/.claude/settings.json isn't valid JSON, so it was left untouched. Fix the file and try again."))
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: settingsURL, to: settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.\(AppInfo.fileName)-backup-\(stamp)"))
        return root
    }

    private static func save(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// hook 脚本：把事件转给 App 的 socket；App 没开就悄悄退出，永远不影响 Claude Code。
    private static func writeScript() throws {
        let script = """
        #!/bin/bash
        # \(AppInfo.name): forwards Claude Code hook events to the app. Does nothing if the app isn't running.
        SOCK="$HOME/Library/Application Support/\(AppInfo.fileName)/agent.sock"
        [ -S "$SOCK" ] || exit 0
        PAYLOAD="$(/bin/cat | /usr/bin/tr -d '\\n\\r')"
        printf '%s\\t%s\\t%s\\n' "$1" "$PPID" "$PAYLOAD" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0
        """
        try FileManager.default.createDirectory(at: AgentMonitor.supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
