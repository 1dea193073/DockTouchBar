// 由 tools/verify-quit-fix.sh 编译运行。只读地打开、退出计算器（单窗口、没有“要保存吗”确认框，
// 退出干净利落，适合当测试对象），验证 QuitPlanner 的 .quitApp 路径不会把“退出了，只是慢一点”
// 误判成 .stillOpen —— 这是用户实测反馈的问题：上一轮只把 .closeWindow 的耐心加长了，
// .quitApp 那条路径还在用旧的 1.4 秒，单窗口 App（大多数情况）走的正是这条路径。
import AppKit

func pumpUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

let bundleID = "com.apple.calculator"
guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    print("找不到计算器，跳过"); exit(1)
}

let config = NSWorkspace.OpenConfiguration()
config.activates = true
var launchDone = false
var launchError: Error?
NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
    launchError = error
    launchDone = true
}
pumpUntil(timeout: 5) { launchDone }
if let launchError { print("打开计算器失败：\(launchError)"); exit(1) }

pumpUntil(timeout: 3) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("计算器没有在运行"); exit(1)
}
let pid = app.processIdentifier
app.activate()
pumpUntil(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
// 给窗口一点时间真正出现，plan(for:) 数窗口才准。
Thread.sleep(forTimeInterval: 0.3)

let plan = QuitPlanner.plan(for: app)
print("plan(for:) = \(plan)")
guard case .quitApp = plan else {
    print("plan 不是 .quitApp（可能计算器开了不止一个窗口，或者没抢到前台），跳过"); exit(1)
}

let start = Date()
var outcome: QuitOutcome?
QuitPlanner.perform(plan, on: app) { result in outcome = result }
pumpUntil(timeout: 5) { outcome != nil }
let elapsed = Date().timeIntervalSince(start)

print("outcome = \(outcome.map { "\($0)" } ?? "超时没回调")，耗时 \(String(format: "%.2f", elapsed))s，isTerminated=\(app.isTerminated)")

let isDone: Bool = { if case .done = outcome { return true }; return false }()
if isDone && app.isTerminated {
    print("✓ 通过：退出被正确识别为 done")
    exit(0)
} else {
    print("✗ 失败：outcome=\(String(describing: outcome))，isTerminated=\(app.isTerminated)")
    // 兜底：万一真的没退出，别留一个孤儿计算器进程。
    if !app.isTerminated { app.forceTerminate() }
    exit(1)
}
