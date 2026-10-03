import Foundation

/// 把 hook 装进各个 AI 编程助手的配置文件（用户在设置里点按钮，或第一次启动时自动接一次），并能原样卸掉。
///
/// - 所有助手共用一个转发脚本 `agent-hook.sh`；配置里只增删带它路径的那几条，其余配置原样保留；改之前先备份。
/// - 文件不是合法 JSON 时一个字也不动，直接报错。
/// - 早期版本用过 `claude-hook.sh`，也算“我们的”，重新连接时会被换成新脚本。
enum AgentHookInstaller {
    /// 主目录：测试时可以换成临时目录，不碰真实的配置。
    static var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    static var supportDirectory: URL { AgentMonitor.supportDirectory }
    static var scriptURL: URL { supportDirectory.appendingPathComponent("agent-hook.sh") }

    struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    static func configURL(_ agent: AgentIntegration) -> URL {
        homeDirectory.appendingPathComponent(agent.configPath)
    }

    /// 这个助手的所有事件都已经指向当前脚本。
    static func isInstalled(_ agent: AgentIntegration) -> Bool {
        guard let root = readConfig(agent), let hooks = root["hooks"] as? [String: Any] else { return false }
        return agent.events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: { isCurrent($0) }) == true
        }
    }

    /// 配置里有我们的条目，但指向旧脚本（比如早期的 claude-hook.sh），需要重新连接一次。
    static func needsMigration(_ agent: AgentIntegration) -> Bool {
        guard let root = readConfig(agent), let hooks = root["hooks"] as? [String: Any] else { return false }
        let groups = hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
        return groups.contains(where: isOurs) && !isInstalled(agent)
    }

    /// 配置文件所在的目录存在：这台电脑上装过这个助手。
    static func isPresent(_ agent: AgentIntegration) -> Bool {
        FileManager.default.fileExists(atPath: configURL(agent).deletingLastPathComponent().path)
    }

    static func install(_ agent: AgentIntegration) throws {
        var root = try loadForWriting(agent)
        try writeScript()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // 先把旧的、不在订阅列表里的我们的条目清掉，再按当前列表装。
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for event in agent.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": "\"\(scriptURL.path)\" \(event)", "timeout": 5]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try save(root, agent)
    }

    static func uninstall(_ agent: AgentIntegration) throws {
        var root = try loadForWriting(agent)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root, agent)
        // 所有助手都断开之后，脚本也不用留着。
        if !AgentIntegration.all.contains(where: { isInstalled($0) || needsMigration($0) }) {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    /// 已连接时，把脚本重写成当前版本的内容（不动配置文件）。
    static func refreshScript() throws { try writeScript() }

    // MARK: - 内部

    private static func commands(_ group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    private static func isCurrent(_ group: [String: Any]) -> Bool {
        commands(group).contains { $0.contains(scriptURL.path) }
    }

    /// 我们的条目：命令指向我们支持目录下的 *-hook.sh（含早期的 claude-hook.sh）。
    private static func isOurs(_ group: [String: Any]) -> Bool {
        commands(group).contains { $0.contains(supportDirectory.path) && $0.contains("-hook.sh") }
    }

    private static func readConfig(_ agent: AgentIntegration) -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL(agent)) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 读出现有配置并备份。文件不存在算空配置；读不懂就报错，不覆盖用户的文件。
    private static func loadForWriting(_ agent: AgentIntegration) throws -> [String: Any] {
        let fm = FileManager.default
        let url = configURL(agent)
        guard fm.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError(errorDescription: L10n.tr("~/\(agent.configPath) 不是有效的 JSON，没有改动它。先修好这个文件再试。",
                                                         "~/\(agent.configPath) isn't valid JSON, so it was left untouched. Fix the file and try again."))
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: url, to: url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(AppInfo.fileName)-backup-\(stamp)"))
        return root
    }

    private static func save(_ root: [String: Any], _ agent: AgentIntegration) throws {
        let url = configURL(agent)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// hook 脚本：把事件转给 App 的 socket；App 没开就悄悄退出，永远不影响助手本身。
    private static func writeScript() throws {
        let script = """
        #!/bin/bash
        # \(AppInfo.name): forwards AI coding agent hook events to the app. Does nothing if the app isn't running.
        SOCK="$HOME/Library/Application Support/\(AppInfo.fileName)/agent.sock"
        [ -S "$SOCK" ] || exit 0
        PAYLOAD="$(/bin/cat | /usr/bin/tr -d '\\n\\r')"
        printf '%s\\t%s\\t%s\\n' "$1" "$PPID" "$PAYLOAD" | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0
        """
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
