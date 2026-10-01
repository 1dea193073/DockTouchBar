import AppKit
import Foundation
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
// 如果用户正在截图或录屏，不能把它当作残留场景，也不干预其系统任务。
guard SystemTouchBarActivityMonitor.interactiveCaptureTaskIsRunning() == false else {
    print("BLOCKED: capture task active or cannot determine state"); exit(2)
}
let uiAlive = NSWorkspace.shared.runningApplications.contains {
    $0.bundleIdentifier.map { SystemTouchBarActivityMonitor.captureBundleIDs.contains($0) } ?? false
}
print("CONTEXT screenshot agent running=\(uiAlive), interactive task=false")
var events: [Bool] = []
let monitor = SystemTouchBarActivityMonitor { events.append($0) }
monitor.start()
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(!monitor.isScreenshotActive && !events.contains(true), "startup with no actual capture does not pause Dock")
monitor.stop()
// 模拟以前已进入暂停，但此进程从没看见任务启动：缺失样本也必须能解除暂停。
monitor.screenshotUIIsRunning = true
monitor.setActive(true)
monitor.sampleInteractiveTask()
check(monitor.isScreenshotActive, "one missing sample preserves transition gap")
monitor.sampleInteractiveTask()
check(!monitor.isScreenshotActive && events.last == false, "two missing samples recover even without observing task launch")
monitor.stop()
monitor.start()
monitor.setActive(true)
monitor.refreshCurrentState()
check(!monitor.isScreenshotActive, "manual restore rechecks actual task immediately")
monitor.stop()
let count = events.count
monitor.refreshCurrentState()
check(events.count == count, "stopped monitor ignores manual refresh")

if !NSEvent.modifierFlags.contains(.function) {
    var fnEvents: [Bool] = []
    let fn = FunctionRowActivityMonitor { fnEvents.append($0) }
    fn.start()
    guard fn.monitor != nil else { print("BLOCKED: cannot install Fn monitor"); exit(2) }
    fn.isFnDown = true // 模拟丢失的松开通知，不发送任何系统按键。
    fn.refreshCurrentState()
    check(!fn.isFnDown && fnEvents.last == false, "manual restore clears stale Fn state")
    fn.stop()
} else { print("SKIP Fn release recovery while Fn physically held") }
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
