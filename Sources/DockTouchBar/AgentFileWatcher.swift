import Foundation

/// 没有 hook、又不一定听话的智能体（目前是豆包）：不靠它自觉上报，直接看它自己写在磁盘上的会话文件。
///
/// 豆包每个会话在 `.sessions/<会话>/agents/<智能体>/system/` 下有：
/// - `assignment.md`：每个回合一开始就追加一条“需求”→ 相当于 UserPromptSubmit；
/// - `trajectory.jsonl`：每一步（工具调用、工具结果、回复）追加一行 → 相当于 PostToolUse 心跳；
///   最后一行是不带工具调用的 assistant 回复 → 这一回合做完了（Stop）。
/// 回复那一行有时迟迟不写，所以最后一行不是回复、又超过 `quietDoneAfter` 秒没有任何新内容，也按做完处理。
///
/// 只读，不改豆包的任何文件；只有用户已经配对了豆包（登记里有所在 App 是豆包的智能体）才会看。
final class DoubaoSessionWatcher {
    static let bundleID = "com.work.pc.doubao"
    static let quietDoneAfter: TimeInterval = 60

    var root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DoubaoWork/Default/.doubaowork/agent_mode/workspace/.sessions", isDirectory: true)
    /// 已配对的豆包的智能体 id（登记里的所在 App 是豆包，或老登记里 id 以 doubao 开头）；nil＝没配对，不看。
    var agentID: () -> String? = { AgentRegistry.load().first { $0.host == DoubaoSessionWatcher.bundleID || $0.id.hasPrefix("doubao") }?.id }
    /// (事件, 会话 id, 智能体 id)。
    var emit: (String, String, String) -> Void = { _, _, _ in }

    private struct Mark {
        var assignment: Date
        var trajectory: Date
        var working: Bool
    }
    private var marks: [String: Mark] = [:]
    private var baselined = false
    private var cachedAgent: (id: String?, date: Date)?

    func poll(now: Date = Date()) {
        // 配对登记 10 秒才重新读一次。
        if cachedAgent == nil || now.timeIntervalSince(cachedAgent!.date) > 10 { cachedAgent = (agentID(), now) }
        guard let agent = cachedAgent?.id else { marks = [:]; baselined = false; return }
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for sid in sessions {
            let agentsDir = root.appendingPathComponent(sid).appendingPathComponent("agents")
            var assignment = Date.distantPast
            var trajectory = Date.distantPast
            var trajectoryURL: URL?
            for name in (try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? [] {
                let system = agentsDir.appendingPathComponent(name).appendingPathComponent("system")
                if let date = modified(system.appendingPathComponent("assignment.md")), date > assignment { assignment = date }
                let url = system.appendingPathComponent("trajectory.jsonl")
                if let date = modified(url), date > trajectory { trajectory = date; trajectoryURL = url }
            }
            guard assignment > .distantPast || trajectory > .distantPast else { continue }
            var mark = marks[sid]
            if mark == nil {
                // 启动时已有的会话只记下现状，不当成新事件；启动之后新出现的会话从头算。
                guard baselined else { marks[sid] = Mark(assignment: assignment, trajectory: trajectory, working: false); continue }
                mark = Mark(assignment: .distantPast, trajectory: .distantPast, working: false)
            }
            step(session: sid, mark: mark!, assignment: assignment, trajectory: trajectory, url: trajectoryURL, agent: agent, now: now)
        }
        baselined = true
    }

    private func step(session sid: String, mark: Mark, assignment: Date, trajectory: Date, url: URL?, agent: String, now: Date) {
        var mark = mark
        let id = "doubao-" + sid
        if assignment > mark.assignment {
            emit("UserPromptSubmit", id, agent)
            mark.working = true
            mark.assignment = assignment
        }
        if trajectory > mark.trajectory {
            mark.trajectory = trajectory
            if let url, Self.lastRowIsFinalReply(url) {
                if mark.working { emit("Stop", id, agent) }
                mark.working = false
            } else if mark.working {
                emit("PostToolUse", id, agent)
            } else {
                // 没看到这一回合的开头（比如 assignment.md 的写入被错过了）：有新步骤就当它开始了。
                emit("UserPromptSubmit", id, agent)
                mark.working = true
            }
        } else if mark.working, now.timeIntervalSince(trajectory) > Self.quietDoneAfter {
            emit("Stop", id, agent)
            mark.working = false
        }
        marks[sid] = mark
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 记录的最后一行是不是不带工具调用的 assistant 回复。最多读文件末尾 256KB；读不出来（写到一半、行太长）就当不是。
    static func lastRowIsFinalReply(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return false }
        try? handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last,
              let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              json["role"] as? String == "assistant" else { return false }
        return ((json["tool_calls"] as? [Any]) ?? []).isEmpty
    }
}
