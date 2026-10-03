// 验证 AI 助手接入：hook 的安装/卸载（保留用户原有配置、坏文件不动、旧脚本迁移）和事件状态机。
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
AgentHookInstaller.homeDirectory = temp
AgentMonitor.supportDirectory = temp.appendingPathComponent("support", isDirectory: true)

func read(_ agent: AgentIntegration) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: AgentHookInstaller.configURL(agent))) as? [String: Any]) ?? [:]
}
func write(_ agent: AgentIntegration, _ json: String) throws {
    let url = AgentHookInstaller.configURL(agent)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
}
func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
    ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
}
func commands(_ root: [String: Any], _ event: String) -> [String] {
    groups(root, event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

for agent in AgentIntegration.all {
    let name = agent.name
    // 1. 已有别的 hook 和别的配置：装完都在，卸完恢复原样。
    try write(agent, #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]}}"#)
    check(!AgentHookInstaller.isInstalled(agent), "\(name): 装之前显示未连接")
    try AgentHookInstaller.install(agent)
    var root = read(agent)
    check(AgentHookInstaller.isInstalled(agent), "\(name): 装完显示已连接")
    check(agent.events.allSatisfy { !commands(root, $0).filter { $0.contains("agent-hook.sh") }.isEmpty }, "\(name): 每个订阅的事件都有我们的 hook")
    check(commands(root, "Stop").contains("echo mine"), "\(name): 用户原来的 Stop hook 还在")
    check(commands(root, "PreToolUse") == ["echo pre"], "\(name): 没订阅的事件原样不动")
    check(root["model"] as? String == "x", "\(name): 其它配置项还在")
    check(fm.fileExists(atPath: AgentHookInstaller.scriptURL.path), "\(name): 转发脚本已写入")
    // 重复安装不会重复加。
    try AgentHookInstaller.install(agent)
    root = read(agent)
    check(commands(root, "Stop").filter { $0.contains("agent-hook.sh") }.count == 1, "\(name): 重复连接不会加两份")
    try AgentHookInstaller.uninstall(agent)
    root = read(agent)
    check(!AgentHookInstaller.isInstalled(agent), "\(name): 卸完显示未连接")
    check(commands(root, "Stop") == ["echo mine"] && commands(root, "PreToolUse") == ["echo pre"] && root["model"] as? String == "x",
          "\(name): 卸完用户的配置原样")
    check(agent.events.filter { $0 != "Stop" }.allSatisfy { groups(root, $0).isEmpty }, "\(name): 我们加的条目都删干净了")

    // 2. 配置文件不存在：创建；卸载后是空配置。
    try? fm.removeItem(at: AgentHookInstaller.configURL(agent))
    try AgentHookInstaller.install(agent)
    check(AgentHookInstaller.isInstalled(agent), "\(name): 配置文件不存在时也能连接")
    try AgentHookInstaller.uninstall(agent)

    // 3. 坏 JSON：一个字不动，并报错。
    try write(agent, "{ not json")
    var threw = false
    do { try AgentHookInstaller.install(agent) } catch { threw = true }
    let after = try String(contentsOf: AgentHookInstaller.configURL(agent), encoding: .utf8)
    check(threw && after == "{ not json", "\(name): 配置不是合法 JSON 时报错且原文件不动")

    // 4. 早期脚本 claude-hook.sh：识别为需要迁移，重新连接后换成新脚本。
    let old = AgentMonitor.supportDirectory.appendingPathComponent("claude-hook.sh").path
    try write(agent, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"\#(old)\" Stop","timeout":5}]}]}}"#)
    check(AgentHookInstaller.needsMigration(agent), "\(name): 指向旧脚本的识别为需要迁移")
    try AgentHookInstaller.install(agent)
    root = read(agent)
    check(!commands(root, "Stop").contains { $0.contains("claude-hook.sh") } && AgentHookInstaller.isInstalled(agent),
          "\(name): 迁移后只剩新脚本")
    try AgentHookInstaller.uninstall(agent)
}
check(fm.fileExists(atPath: AgentHookInstaller.scriptURL.path), "全部断开后转发脚本还在（配对提示词要调用它）")

// 5. 状态机。
let monitor = AgentMonitor()
var changes = 0
monitor.onChange = { changes += 1 }
monitor.ownerResolver = { $0 == 100 ? "app.one" : ($0 == 200 ? "app.two" : nil) }
func send(_ event: String, _ session: String, _ pid: pid_t) { monitor.handle(event: event, sessionID: session, from: pid) }

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
monitor.isEnabled = false
send("UserPromptSubmit", "f", 100)
check(monitor.state(for: "app.one") == .idle, "状态: 总开关关掉后一律显示空闲")
check(changes > 0, "状态: 变化会通知刷新")

// 6. 配对智能体：登记文件、事件日志、提示词。
let agentsDir = AgentRegistry.directory
try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
try #"{"id":"workbuddy","name":"WorkBuddy","method":"hook","files":["/tmp/a.json"],"notes":"ok"}"#
    .write(to: agentsDir.appendingPathComponent("workbuddy.json"), atomically: true, encoding: .utf8)
try #"{"id":"other","name":"Mismatch"}"#.write(to: agentsDir.appendingPathComponent("wrongname.json"), atomically: true, encoding: .utf8)
try #"{"id":"../evil","name":"Evil"}"#.write(to: agentsDir.appendingPathComponent("evil.json"), atomically: true, encoding: .utf8)
try "{ broken".write(to: agentsDir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
try #"{"id":"nameless"}"#.write(to: agentsDir.appendingPathComponent("nameless.json"), atomically: true, encoding: .utf8)
let registered = AgentRegistry.load()
check(registered.map(\.id) == ["nameless", "workbuddy"] || registered.map(\.id).sorted() == ["nameless", "workbuddy"], "登记: 只读到合法的两份（坏文件、id 和文件名不一致、路径穿越都被跳过）")
check(registered.first { $0.id == "workbuddy" }?.files == ["/tmp/a.json"], "登记: files 读出来了")
check(registered.first { $0.id == "nameless" }?.name == "nameless", "登记: 没有 name 时用 id")
check(AgentRegistry.isValidID("work-buddy2") && !AgentRegistry.isValidID("Work") && !AgentRegistry.isValidID("a/b") && !AgentRegistry.isValidID(""), "登记: id 的合法性判断")
AgentRegistry.remove(id: "workbuddy")
check(!fm.fileExists(atPath: agentsDir.appendingPathComponent("workbuddy.json").path), "登记: 移除只删登记文件")

// 事件日志 → 最近活动
let monitor2 = AgentMonitor()
monitor2.ownerResolver = { _ in "app.host" }
monitor2.handle(event: "UserPromptSubmit", sessionID: "s1", from: 1, agent: "workbuddy")
monitor2.handle(event: "Stop", sessionID: "s1", from: 1, agent: "workbuddy")
monitor2.handle(event: "Stop", sessionID: "s9", from: 1)
let activity = AgentRegistry.lastActivity()
check(activity["workbuddy"]?.event == "Stop" && activity["workbuddy"]?.bundleID == "app.host", "活动: 日志里按 agent 取最近一次事件和所在 App")
check(activity["-"] == nil && activity.count == 1, "活动: 没带 agent id 的事件不进配对列表")
let unresolved = AgentMonitor()
unresolved.ownerResolver = { _ in nil }
unresolved.handle(event: "Stop", sessionID: "s2", from: 1, agent: "lost")
check(AgentRegistry.lastActivity()["lost"]?.bundleID == nil, "活动: 找不到所在 App 时 bundleID 为空，列表会提示")

// 提示词里有真实路径和关键约束；脚本能处理参数。
let prompt = AgentPairingPrompt.text()
check(prompt.contains(AgentHookInstaller.scriptURL.path) && prompt.contains(AgentRegistry.logURL.path) && prompt.contains(agentsDir.path), "提示词: 含脚本、日志、登记目录的真实路径")
check(prompt.contains("/dev/null") && prompt.contains("UserPromptSubmit") && prompt.contains("Interrupt"), "提示词: 含用法和事件")
let script = try String(contentsOf: AgentHookInstaller.scriptURL, encoding: .utf8)
check(script.contains("[ -t 0 ]") && script.contains("$EVENT"), "脚本: 终端上不会卡住读 stdin、支持 agent id")

print(failures == 0 ? "RESULT failures=0" : "RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
