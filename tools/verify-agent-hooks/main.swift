// 验证 AI 助手接入：事件状态机、配对智能体的宽松收尾、打断检测、登记和最近活动、旧 hook 迁移、提示词和脚本。
// 全程在临时目录里做，不碰真实的 ~/.claude、~/.codex 和应用支持目录。由 tools/verify-agent-hooks.sh 编译运行。
import AppKit

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print(ok ? "PASS \(message)" : "FAIL \(message)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let temp = fm.temporaryDirectory.appendingPathComponent("verify-agent-hooks-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: temp) }
AgentMonitor.supportDirectory = temp.appendingPathComponent("support", isDirectory: true)
AgentRegistry.homeDirectory = temp
try fm.createDirectory(at: AgentMonitor.supportDirectory, withIntermediateDirectories: true)

func makeMonitor(_ owner: @escaping (pid_t) -> String? = { _ in "app.one" }) -> AgentMonitor {
    let monitor = AgentMonitor()
    monitor.ownerResolver = owner
    return monitor
}

// 1. 状态机（内置 hook 风格：会话 id 来自 hook，严格）。
do {
    let monitor = makeMonitor { $0 == 100 ? "app.one" : ($0 == 200 ? "app.two" : nil) }
    var changes = 0
    monitor.onChange = { changes += 1 }
    func send(_ event: String, _ session: String, _ pid: pid_t, agent: String? = nil) {
        monitor.handle(event: event, sessionID: session, from: pid, agent: agent)
    }
    check(monitor.state(for: "app.one") == .idle, "状态: 初始空闲")
    send("UserPromptSubmit", "a", 100)
    check(monitor.state(for: "app.one") == .working && monitor.state(for: "app.two") == .idle, "状态: 提问后只有这个 App 在工作")
    send("PostToolUse", "a", 100)
    check(monitor.state(for: "app.one") == .working, "状态: 心跳不改变状态")
    send("Stop", "a", 100)
    check(monitor.state(for: "app.one") == .done, "状态: Stop 后是做完")
    send("PostToolUse", "a", 100)
    check(monitor.state(for: "app.one") == .done, "状态: 做完后迟到的心跳不会翻回工作中")
    monitor.acknowledge(bundleID: "app.one")
    check(monitor.state(for: "app.one") == .idle, "状态: 点图标后回到空闲")
    send("PostToolUse", "a", 100)
    check(monitor.state(for: "app.one") == .idle, "状态: 点掉之后迟到的心跳不会造出永远不结束的“工作中”")
    send("UserPromptSubmit", "a", 100); send("UserPromptSubmit", "b", 100); send("Stop", "a", 100)
    check(monitor.state(for: "app.one") == .working, "状态: 同一个 App 里还有会话在工作，就还是工作中")
    send("Stop", "b", 100)
    check(monitor.state(for: "app.one") == .done, "状态: 都做完才算做完")
    monitor.acknowledge(bundleID: "app.one")
    send("UserPromptSubmit", "c", 200); send("Interrupt", "c", 200)
    check(monitor.state(for: "app.two") == .idle, "状态: Interrupt 直接回到空闲，不显示做完")
    send("UserPromptSubmit", "d", 200); send("SessionEnd", "d", 200)
    check(monitor.state(for: "app.two") == .idle, "状态: SessionEnd 回到空闲")
    send("UserPromptSubmit", "e", 999)
    check(monitor.state(for: "app.one") == .idle && monitor.state(for: "app.two") == .idle, "状态: 找不到所在 App 的事件被忽略")
    // 用 hook 的助手有多个会话同时在跑：一个 Stop 不能带走另一个。
    send("UserPromptSubmit", "s1", 100, agent: "claude-code"); send("UserPromptSubmit", "s2", 100, agent: "claude-code")
    send("Stop", "s1", 100, agent: "claude-code")
    check(monitor.state(for: "app.one") == .working, "严格: 用 hook 的助手，一个会话 Stop 不影响另一个会话")
    monitor.resetAll()
    check(monitor.state(for: "app.one") == .idle, "重置: 一键清掉所有动画状态")
    monitor.isEnabled = false
    send("UserPromptSubmit", "f", 100)
    check(monitor.state(for: "app.one") == .idle, "状态: 总开关关掉后一律显示空闲")
    check(changes > 0, "状态: 变化会通知刷新")
}

// 2. 手动调脚本的智能体：会话 id 对不上、漏发 Stop 都不会卡住。
do {
    let monitor = makeMonitor()
    monitor.handle(event: "UserPromptSubmit", sessionID: "a", from: 1, agent: "bot", lenient: true)
    monitor.handle(event: "UserPromptSubmit", sessionID: "b", from: 2, agent: "bot", lenient: true)
    monitor.handle(event: "Stop", sessionID: "zzz", from: 3, agent: "bot", lenient: true)
    check(monitor.state(for: "app.one") == .done, "宽松: Stop 带了对不上的会话 id，它名下工作中的会话一起算做完")
    monitor.acknowledge(bundleID: "app.one")
    monitor.handle(event: "UserPromptSubmit", sessionID: "c", from: 1, agent: "bot", lenient: true)
    monitor.handle(event: "Interrupt", sessionID: "other", from: 1, agent: "bot", lenient: true)
    check(monitor.state(for: "app.one") == .idle, "宽松: Interrupt 清掉它所有工作中的会话")
    monitor.handle(event: "UserPromptSubmit", sessionID: "d", from: 1, agent: "bot", lenient: true)
    monitor.dropStaleSessions(now: Date().addingTimeInterval(AgentMonitor.pairedStaleAfter - 5))
    check(monitor.state(for: "app.one") == .working, "宽松: 3 分钟以内还算工作中")
    monitor.dropStaleSessions(now: Date().addingTimeInterval(AgentMonitor.pairedStaleAfter + 5))
    check(monitor.state(for: "app.one") == .idle, "宽松: 3 分钟没有事件就当中断")
    monitor.handle(event: "UserPromptSubmit", sessionID: "x", from: 1, agent: "claude-code")
    monitor.dropStaleSessions(now: Date().addingTimeInterval(AgentMonitor.pairedStaleAfter + 5))
    check(monitor.state(for: "app.one") == .working, "严格: 用 hook 的助手 3 分钟不会被清掉")
    monitor.dropStaleSessions(now: Date().addingTimeInterval(AgentMonitor.staleAfter + 5))
    check(monitor.state(for: "app.one") == .idle, "严格: 10 分钟没有事件才清掉")
}

// 3. 打断检测：Claude Code 按 Esc 不发事件，但会往聊天记录追加一句。
do {
    let monitor = makeMonitor()
    let transcript = temp.appendingPathComponent("transcript.jsonl")
    try "{\"type\":\"user\",\"text\":\"[Request interrupted by user]\"}\n".write(to: transcript, atomically: true, encoding: .utf8)  // 旧的一句，不能算
    monitor.handle(event: "UserPromptSubmit", sessionID: "t1", from: 1, agent: "claude-code", transcriptPath: transcript.path)
    monitor.scanTranscriptsForInterrupts()
    check(monitor.state(for: "app.one") == .working, "打断: 开始之前记录里的旧打断标记不算")
    let handle = try FileHandle(forWritingTo: transcript)
    handle.seekToEndOfFile()
    handle.write(Data("{\"type\":\"assistant\",\"text\":\"working\"}\n".utf8))
    monitor.scanTranscriptsForInterrupts()
    check(monitor.state(for: "app.one") == .working, "打断: 记录有新内容但没有打断标记，还在工作中")
    handle.write(Data("{\"type\":\"user\",\"text\":\"[Request interrupted by user for tool use]\"}\n".utf8))
    try handle.close()
    monitor.scanTranscriptsForInterrupts()
    check(monitor.state(for: "app.one") == .idle, "打断: 开始之后出现打断标记，直接回到空闲（不显示做完）")
}

// 4. 认出是谁、最近活动落盘。
check(AgentMonitor.inferAgent(["transcript_path": "/Users/x/.claude/projects/p/a.jsonl"]) == "claude-code", "识别: .claude 下的记录是 Claude Code")
check(AgentMonitor.inferAgent(["transcript_path": "/Users/x/.codex/sessions/a.jsonl"]) == "codex", "识别: .codex 下的记录是 Codex")
check(AgentMonitor.inferAgent(["turn_id": "t"]) == "codex" && AgentMonitor.inferAgent(["session_id": "s"]) == nil, "识别: 带 turn_id 的是 Codex，什么都没有就不猜")
do {
    let monitor = makeMonitor()
    monitor.handle(event: "UserPromptSubmit", sessionID: "s1", from: 1, agent: "workbuddy", lenient: true)
    monitor.handle(event: "Stop", sessionID: "s1", from: 1, agent: "workbuddy", lenient: true)
    monitor.handle(event: "Stop", sessionID: "s9", from: 1)
    let activity = AgentRegistry.lastActivity()
    check(activity["workbuddy"]?.event == "Stop" && activity["workbuddy"]?.bundleID == "app.one", "活动: 每个智能体最近一次事件和所在 App 存进 activity.json")
    check(activity.count == 1, "活动: 没带 agent id 的事件不进配对列表")
    try? fm.removeItem(at: AgentRegistry.logURL)
    check(AgentRegistry.lastActivity()["workbuddy"] != nil, "活动: 日志没了（比如被挪走）验证状态也不丢")
    let lost = makeMonitor { _ in nil }
    lost.handle(event: "Stop", sessionID: "s2", from: 1, agent: "lost", lenient: true)
    check(AgentRegistry.lastActivity()["lost"]?.bundleID == nil, "活动: 找不到所在 App 时 bundleID 为空，列表会提示")
}

// 5. 登记文件。
let agentsDir = AgentRegistry.directory
try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
try #"{"id":"workbuddy","name":"WorkBuddy","method":"hook","files":["/tmp/a.json"],"notes":"ok"}"#
    .write(to: agentsDir.appendingPathComponent("workbuddy.json"), atomically: true, encoding: .utf8)
try #"{"id":"other","name":"Mismatch"}"#.write(to: agentsDir.appendingPathComponent("wrongname.json"), atomically: true, encoding: .utf8)
try #"{"id":"../evil","name":"Evil"}"#.write(to: agentsDir.appendingPathComponent("evil.json"), atomically: true, encoding: .utf8)
try "{ broken".write(to: agentsDir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
try #"{"id":"nameless"}"#.write(to: agentsDir.appendingPathComponent("nameless.json"), atomically: true, encoding: .utf8)
let registered = AgentRegistry.load()
check(registered.map(\.id).sorted() == ["nameless", "workbuddy"], "登记: 只读到合法的两份（坏文件、id 和文件名不一致、路径穿越都被跳过）")
check(registered.first { $0.id == "workbuddy" }?.files == ["/tmp/a.json"], "登记: files 读出来了")
check(registered.first { $0.id == "nameless" }?.name == "nameless", "登记: 没有 name 时用 id")
check(AgentRegistry.isValidID("work-buddy2") && !AgentRegistry.isValidID("Work") && !AgentRegistry.isValidID("a/b") && !AgentRegistry.isValidID(""), "登记: id 的合法性判断")

// 6. 早期自动连接的 Claude Code / Codex：补登记，不动它们的配置。
let script = AgentHookInstaller.scriptURL.path
let claudeConfig = temp.appendingPathComponent(".claude/settings.json")
try fm.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
let claudeText = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"\#(script)\" Stop"}]}]}}"#
try claudeText.write(to: claudeConfig, atomically: true, encoding: .utf8)
let codexConfig = temp.appendingPathComponent(".codex/hooks.json")
try fm.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo someone-else"}]}]}}"#.write(to: codexConfig, atomically: true, encoding: .utf8)
let created = AgentRegistry.migrateLegacyHooks()
check(created == ["claude-code"], "迁移: 只给配置里真有我们 hook 的 Claude Code 补登记，Codex（没有我们的 hook）不补")
check(AgentRegistry.load().contains { $0.id == "claude-code" && $0.name == "Claude Code" }, "迁移: 补的登记在配对列表里读得到")
check((try String(contentsOf: claudeConfig, encoding: .utf8)) == claudeText, "迁移: 只读配置，一个字不改")
check(AgentRegistry.migrateLegacyHooks().isEmpty, "迁移: 已有登记的不重复建")

// 7. 提示词和脚本。
try AgentHookInstaller.refreshScript()
let prompt = AgentPairingPrompt.text()
check(prompt.contains(script) && prompt.contains(AgentRegistry.logURL.path) && prompt.contains(agentsDir.path), "提示词: 含脚本、日志、登记目录的真实路径")
check(prompt.contains("/dev/null") && prompt.contains("UserPromptSubmit") && prompt.contains("Interrupt") && prompt.contains("Stop"), "提示词: 含用法和事件")
let scriptText = try String(contentsOfFile: script, encoding: .utf8)
check(scriptText.contains("[ -t 0 ]") && scriptText.contains("$EVENT") && scriptText.contains("manual"), "脚本: 终端上不卡 stdin、支持 agent id、手动调用带 manual 标记")
let mode = (try? fm.attributesOfItem(atPath: script))?[.posixPermissions] as? Int
check(fm.fileExists(atPath: script) && mode == 0o755, "脚本: 已写入且可执行")

print(failures == 0 ? "RESULT failures=0" : "RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
