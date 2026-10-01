import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }

// 多种暂停原因叠加时，关闭一项不能提前恢复，也不能留下永久暂停。
let dock = DockBarController()
dock.isActive = true
dock.updateSystemCaptureAvoidance()
dock.updateFunctionRowAvoidance()
check(dock.systemTouchBarActivity.started && dock.functionRowActivity.started, "default avoidance starts both monitors")
dock.beginPause(for: .coffee)
dock.systemTouchBarActivity.emit(true)
dock.functionRowActivity.emit(true)
check(dock.pauseReasons.count == 3 && TouchBarBridge.dismisses == 1, "overlapping pauses dismiss once")
dock.yieldsToSystemCapture = false
check(dock.pauseReasons.count == 2 && dock.isPaused && TouchBarBridge.presents == 0, "disable capture preserves Fn and coffee pause")
dock.systemTouchBarActivity.emit(true)
check(dock.pauseReasons.count == 2 && !dock.systemTouchBarActivity.started, "disabled capture ignores late callback")
dock.yieldsToFunctionRow = false
check(dock.pauseReasons == [.coffee] && TouchBarBridge.presents == 0, "disable Fn preserves coffee pause")
dock.endPause(for: .coffee, present: true)
check(!dock.isPaused && TouchBarBridge.presents == 1, "last pause ending resumes once")
dock.yieldsToSystemCapture = true
dock.systemTouchBarActivity.emit(true)
check(dock.isPaused, "re-enable capture takes effect")
dock.stop()
dock.systemTouchBarActivity.emit(true)
dock.functionRowActivity.emit(true)
check(!dock.isActive && !dock.isPaused && !dock.systemTouchBarActivity.started && !dock.functionRowActivity.started, "stop clears pauses and ignores late notifications")

// 入口按钮应重读系统活动，解除残留状态；正在进行的真实任务仍需让位。
let restoringDock = DockBarController()
restoringDock.isActive = true
restoringDock.updateSystemCaptureAvoidance()
restoringDock.updateFunctionRowAvoidance()
restoringDock.systemTouchBarActivity.emit(true)
restoringDock.functionRowActivity.emit(true)
restoringDock.beginPause(for: .coffee)
restoringDock.systemTouchBarActivity.stateOnRefresh = false
restoringDock.functionRowActivity.stateOnRefresh = false
let beforeRestore = TouchBarBridge.presents
restoringDock.trayTapped()
check(!restoringDock.isPaused && TouchBarBridge.presents == beforeRestore + 1, "tray button clears stale system pauses and coffee pause")
restoringDock.systemTouchBarActivity.emit(true)
restoringDock.systemTouchBarActivity.stateOnRefresh = true
let beforeActiveTask = TouchBarBridge.presents
restoringDock.trayTapped()
check(restoringDock.pauseReasons == [.systemCapture] && TouchBarBridge.presents == beforeActiveTask, "tray button preserves actual capture task")
restoringDock.stop()

// 旧松手回调不能消费用户已开始的新按压。
dock.press = DockBarController.Press(index: 0, tile: .trash, start: .zero)
dock.endPress()
let newer = DockBarController.Press(index: 1, tile: .trash, start: .zero)
dock.press = newer
settle()
check(dock.press?.id == newer.id, "delayed old release preserves newer press")
dock.cancelPress()

let updater = UpdateManager()
for busy in [UpdateManager.State.checking, .downloading(progress: 0.25), .verifying, .installing] {
    updater.state = busy
    updater.checkForUpdates()
    check(updater.state == busy, "check update preserves busy state \(busy)")
    if busy != .downloading(progress: 0.25) {
        updater.cancel()
        check(updater.state == busy, "cancel cannot interrupt \(busy)")
    }
}
for (new, old, expected) in [("1.14", "1.13", true), ("v2.0", "1.99", true), ("1.14.0", "1.14", false), ("1.9", "1.14", false), ("1..99", "1.14", false), ("1.15beta", "1.14", false), ("", "1.14", false), ("999999999999999999999", "1.14", false)] {
    check(UpdateManager.isVersion(new, greaterThan: old) == expected, "numeric version \(new) / \(old)")
}

// 不 resume 网络任务；手动注入迟到的 delegate 回调。
let oldSession = URLSession(configuration: .ephemeral)
let newSession = URLSession(configuration: .ephemeral)
let url = URL(string: "https://127.0.0.1/unused")!
let oldTask = oldSession.downloadTask(with: url)
let newTask = newSession.downloadTask(with: url)
updater.downloadSession = newSession
updater.downloadTask = newTask
updater.state = .downloading(progress: 0)
updater.urlSession(oldSession, downloadTask: oldTask, didWriteData: 80, totalBytesWritten: 80, totalBytesExpectedToWrite: 100)
updater.urlSession(oldSession, task: oldTask, didCompleteWithError: URLError(.timedOut))
settle()
check(updater.state == .downloading(progress: 0) && updater.downloadTask === newTask, "old progress and error do not corrupt new download")
updater.urlSession(newSession, downloadTask: newTask, didWriteData: 50, totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
settle()
check(updater.state == .downloading(progress: 0.5), "current download progress accepted")
updater.cancel()
updater.urlSession(newSession, task: newTask, didCompleteWithError: URLError(.timedOut))
settle()
check(updater.state == .idle, "late failure after cancel ignored")
oldSession.invalidateAndCancel()
newSession.invalidateAndCancel()

// 模拟无权限时期已经记住同一 Finder pid；授权后应重新装 observer。
if AXIsProcessTrusted(), let finderPID = DockModel.finderPID() {
    let monitor = FinderWindowMonitor()
    monitor.watchedPID = finderPID
    monitor.watch(pid: finderPID)
    check(monitor.observer != nil, "Finder observer retries same PID after access becomes available")
    monitor.stop()
} else { print("SKIP Finder observer retry: Accessibility unavailable") }

// 测试工具自身没有 Developer ID；即便下载目标是有效正式包，也不能绕过宿主身份校验。
let installed = URL(fileURLWithPath: "/Applications/DockTouchBar.app")
check(UpdateManager.extractTeamID(for: installed) == "STWPBZG6S7", "installed application has expected signing identity")
do {
    try updater.verifyAppleCodeSignature(for: installed)
    check(false, "missing host signing identity blocks installation")
} catch UpdateError.teamIDMismatch {
    check(true, "missing host signing identity blocks installation")
} catch { check(false, "unexpected signature check error: \(error)") }

// 运行生产安装脚本，只替换 open 命令为本地夹具，验证真实目录替换与失败回退。
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("DockTouchBarSafety-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func installCase(_ name: String, copyFails: Bool = false, renameFails: Bool = false, openFails: Bool = false, alive: Bool = false) throws {
    let base = root.appendingPathComponent(name)
    let source = base.appendingPathComponent("new.app")
    let dest = base.appendingPathComponent("App $(touch injected) `touch injected2` ' \" space.app")
    let temp = base.appendingPathComponent("temp")
    let bin = base.appendingPathComponent("bin")
    for dir in [source, dest, temp, bin] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    try "new".write(to: source.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    try "old".write(to: dest.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    func script(_ text: String, _ url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let open = bin.appendingPathComponent("fake-open")
    try script("#!/bin/bash\n" + (openFails ? "[ \"$(cat \"$2/marker\")\" = old ]\n" : "exit 0\n"), open)
    if renameFails {
        try script("#!/bin/bash\ncase \"$1\" in *'/.DockTouchBar-update-'*) exit 1 ;; esac\nexec /bin/mv \"$@\"\n", bin.appendingPathComponent("mv"))
    }
    var content = UpdateManager.replacementScript.replacingOccurrences(of: "/usr/bin/open", with: "\"\(open.path)\"")
    if copyFails { content = content.replacingOccurrences(of: "/usr/bin/ditto", with: "/usr/bin/false") }
    if alive { content = content.replacingOccurrences(of: "{1..50}", with: "{1..2}") }
    let runner = base.appendingPathComponent("install.sh")
    try script(content, runner)
    // 新建一个已退出并已回收的进程，其 pid 不会被 kill -0 当成活进程。
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run(); ended.waitUntilExit()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [runner.path, String(alive ? ProcessInfo.processInfo.processIdentifier : ended.processIdentifier), source.path, dest.path, temp.path]
    process.currentDirectoryURL = base
    process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "\(bin.path):/usr/bin:/bin"]) { _, new in new }
    let output = Pipe()
    process.standardOutput = output; process.standardError = output
    try process.run()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let success = !copyFails && !renameFails && !openFails && !alive
    let marker = try? String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8)
    check((process.terminationStatus == 0) == success && marker == (success ? "new" : "old"), "installer \(name) preserves expected application")
    check(fm.fileExists(atPath: temp.path) == !success, "installer \(name) cleanup or failure evidence")
    check(!fm.fileExists(atPath: base.appendingPathComponent("injected").path) && !fm.fileExists(atPath: base.appendingPathComponent("injected2").path), "installer \(name) path characters remain literal")
    let leftovers = try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".DockTouchBar-") }
    check(leftovers.isEmpty, "installer \(name) no staged or backup leftovers after successful rollback")
}
do {
    try installCase("success")
    try installCase("copy-failure", copyFails: true)
    try installCase("rename-failure", renameFails: true)
    try installCase("launch-command-failure", openFails: true)
    try installCase("old-process-alive", alive: true)
} catch { check(false, "installer test error: \(error)") }
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
