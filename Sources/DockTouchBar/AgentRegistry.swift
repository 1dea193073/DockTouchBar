import Foundation

/// 通过“配对智能体”提示词自己接进来的智能体：它们验证通过之后，会把一份登记 JSON 写进 `agents/<id>.json`。
/// 登记只是给设置页的“配对列表”看的；真正让动画出现的是它们调用转发脚本发来的事件。
struct PairedAgent: Identifiable, Equatable {
    let id: String
    let name: String
    /// 怎么接的：hook（用它自己的 hook 机制）或 instructions（写进它的长期指令里）。
    let method: String
    /// 它改过的文件（绝对路径），取消配对时要还原。
    let files: [String]
    let notes: String
}

/// 某个智能体最近一次发来的事件。
struct AgentActivity: Equatable {
    let date: Date
    let event: String
    /// 事件解析到的所在 App 的 bundleID；nil＝没找到。
    let bundleID: String?
}

enum AgentRegistry {
    static var directory: URL { AgentMonitor.supportDirectory.appendingPathComponent("agents", isDirectory: true) }
    static var logURL: URL { AgentMonitor.supportDirectory.appendingPathComponent("events.log") }

    /// id 只能是小写字母、数字、短横线（也是登记文件名，不能带路径）。
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// 读所有登记。坏文件、id 不合法或和文件名不一致的直接跳过，不报错。
    static func load() -> [PairedAgent] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url -> PairedAgent? in
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["id"] as? String, isValidID(id), url.deletingPathExtension().lastPathComponent == id else { return nil }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? id
            return PairedAgent(id: id, name: name,
                               method: String(((json["method"] as? String) ?? "").prefix(40)),
                               files: ((json["files"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(20).map { String($0.prefix(300)) },
                               notes: String(((json["notes"] as? String) ?? "").prefix(300)))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 只删登记，不动它改过的配置——那要让它自己还原（列表里有“复制取消配对提示词”）。
    static func remove(id: String) {
        guard isValidID(id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    /// 从事件日志里找每个智能体最近一次事件（日志是 `时间 事件 agent=… session=… pid=… app=…`，一行一个）。
    static func lastActivity() -> [String: AgentActivity] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [:] }
        let formatter = ISO8601DateFormatter()
        var result: [String: AgentActivity] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, let date = formatter.date(from: String(fields[0])) else { continue }
            func value(_ key: String) -> String? {
                fields.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
            }
            guard let agent = value("agent"), agent != "-" else { continue }
            let app = value("app").flatMap { $0 == "-" ? nil : $0 }
            result[agent] = AgentActivity(date: date, event: String(fields[1]), bundleID: app)
        }
        return result
    }
}
