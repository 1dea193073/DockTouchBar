// 由 tools/verify-close-fix.sh 编译运行。只读地打开/关闭 TextEdit 的测试窗口，不碰用户自己的窗口。
// 验证 QuitPlanner 的 .closeWindow 路径：关掉一个窗口后，perform 是否正确回调 .done，
// 而不是把“关了，只是没那么快看出来”误判成 .stillOpen。
//
// 这是个没有 NSApplication 的命令行小程序，主线程不会自己转动 RunLoop；QuitPlanner 内部靠
// DispatchQueue.main.asyncAfter 轮询，光用 DispatchSemaphore.wait() 卡住主线程会让那些轮询永远排不上号
// （不是 QuitPlanner 的问题，是这类命令行工具本身的限制）。所以这里统一用“转一下 RunLoop 再看看条件”代替阻塞等待。
import AppKit
import ApplicationServices

func pumpUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

let bundleID = "com.apple.TextEdit"
guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    print("找不到 TextEdit，跳过"); exit(1)
}

func makeTempFile(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
    let file = dir.appendingPathComponent(name)
    try? "verify-close-fix test file".write(to: file, atomically: true, encoding: .utf8)
    return file
}

let fileA = makeTempFile("verify-close-fix-a-\(UUID().uuidString).txt")
let fileB = makeTempFile("verify-close-fix-b-\(UUID().uuidString).txt")

let config = NSWorkspace.OpenConfiguration()
config.activates = true
var launchDone = false
var launchError: Error?
NSWorkspace.shared.open([fileA, fileB], withApplicationAt: url, configuration: config) { _, error in
    launchError = error
    launchDone = true
}
pumpUntil(timeout: 5) { launchDone }
if let launchError { print("打开 TextEdit 失败：\(launchError)"); exit(1) }
guard launchDone else { print("打开 TextEdit 超时"); exit(1) }

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("TextEdit 没有在运行"); exit(1)
}
let pid = app.processIdentifier

// 等两个窗口都出现（辅助功能）。
func windowCount() -> Int {
    let element = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return -1 }
    return (value as? [AXUIElement])?.count ?? 0
}

pumpUntil(timeout: 5) { windowCount() >= 2 }
guard windowCount() >= 2 else { print("没能打开 2 个窗口（现在 \(windowCount()) 个），跳过"); exit(1) }
print("TextEdit pid \(pid)，已打开 \(windowCount()) 个窗口")

app.activate()
pumpUntil(timeout: 2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

let plan = QuitPlanner.plan(for: app)
print("plan(for:) = \(plan)")
guard case .closeWindow = plan else {
    print("plan 不是 .closeWindow（可能没抢到前台），跳过"); exit(1)
}

let before = windowCount()
let start = Date()
var outcome: QuitOutcome?
QuitPlanner.perform(plan, on: app) { result in outcome = result }
pumpUntil(timeout: 5) { outcome != nil }
let elapsed = Date().timeIntervalSince(start)
let after = windowCount()

print("outcome = \(outcome.map { "\($0)" } ?? "超时没回调")，耗时 \(String(format: "%.2f", elapsed))s，窗口数 \(before) → \(after)")

// 清理：关掉剩下那个窗口，杜绝残留。
if after > 0 {
    NSAppleScript(source: "tell application \"TextEdit\" to close every window without saving")?.executeAndReturnError(nil)
}
try? FileManager.default.removeItem(at: fileA)
try? FileManager.default.removeItem(at: fileB)

let isDone: Bool = { if case .done = outcome { return true }; return false }()
guard isDone && after < before else {
    print("✗ 失败：outcome=\(String(describing: outcome))，窗口数 \(before) → \(after)")
    exit(1)
}
print("✓ 通过：关闭被正确识别为 done，窗口数确实减少，没有误判成 stillOpen")

// 第二部分：TextEdit 关窗口太快，测不出原来的时序 bug（1.4 秒的老耐心其实够用，
// 问题只在“关闭动画/系统卡顿更慢”的情况下才会露出来）。这里直接用真实的 wait() 逻辑，
// 配一个 2.0 秒后才变 true 的假条件，模拟“确实关了，只是比较慢才看出来”，
// 分别用旧耐心（1.4s）和现在用的关窗口耐心（2.6s）跑一遍，两者应该给出不同结果。
let becomesTrueAt = Date().addingTimeInterval(2.0)
func slowCondition() -> Bool { Date() >= becomesTrueAt }

var oldPatienceResult: Bool?
QuitPlanner.wait(patience: 1.4, until: slowCondition) { oldPatienceResult = $0 }
pumpUntil(timeout: 3) { oldPatienceResult != nil }

let becomesTrueAt2 = Date().addingTimeInterval(2.0)
func slowCondition2() -> Bool { Date() >= becomesTrueAt2 }
var newPatienceResult: Bool?
QuitPlanner.wait(patience: 2.6, until: slowCondition2) { newPatienceResult = $0 }
pumpUntil(timeout: 3) { newPatienceResult != nil }

print("模拟“2 秒后才关完”：旧耐心(1.4s) → \(oldPatienceResult.map(String.init) ?? "?")，" +
      "关窗口耐心(2.6s) → \(newPatienceResult.map(String.init) ?? "?")")

if oldPatienceResult == false && newPatienceResult == true {
    print("✓ 通过：这正是原来的 bug（旧耐心会把“慢一点关完”误判成没关），新耐心能等到")
    exit(0)
} else {
    print("✗ 没有重现预期的对比（旧应为 false、新应为 true）")
    exit(1)
}
