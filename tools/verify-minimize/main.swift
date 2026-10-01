import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func settle(_ seconds: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { settle(0.04) }
    return condition()
}
var failures = 0
func check(_ value: Bool, _ message: String) {
    print("\(value ? "PASS" : "FAIL") \(message)")
    if !value { failures += 1 }
}
guard AppSwitcher.hasAccessibilityAccess else { print("BLOCKED Accessibility unavailable"); exit(2) }
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let stateURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard wait(10, { FileManager.default.fileExists(atPath: stateURL.path) }) else { print("FAIL fixture not ready"); exit(1) }
let state = try! JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
let pid = (state["pid"] as! NSNumber).int32Value
let windowID = state["window"] as! Int
let nativeMinimized = state["nativeMinimized"] as! Bool
let nativeOnScreen = state["nativeOnScreen"] as! Bool
let fixtureApp = NSRunningApplication(processIdentifier: pid)!
let element = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(element, 0.35)
func window() -> AXUIElement? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
    return (value as? [AXUIElement])?.first
}
func isMinimized() -> Bool {
    guard let window = window() else { return false }
    AXUIElementSetMessagingTimeout(window, 0.35)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
    return value as? Bool == true
}
func onScreen() -> Bool {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return infos.contains { $0[kCGWindowNumber as String] as? Int == windowID }
}
func frame() -> [String: CGFloat] {
    let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]] ?? []
    return infos.first { $0[kCGWindowNumber as String] as? Int == windowID }?[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
}
let original = state["originalFrame"] as! [String: CGFloat]
let nativeFrame = state["nativeFrame"] as! [String: CGFloat]
func shrunk(_ frame: [String: CGFloat]) -> Bool {
    (frame["Width"] ?? 0) < (original["Width"] ?? 0) * 0.6 && (frame["Height"] ?? 0) < (original["Height"] ?? 0) * 0.6
}
check(nativeMinimized || !nativeOnScreen || shrunk(nativeFrame), "Native minimization removes window or places thumbnail in Stage Manager")
check(wait(5, { onScreen() && !isMinimized() && !shrunk(frame()) }), "Fixture restored before double-tap test")
let tile = DockTile(kind: .app, url: fixtureURL, bundleID: "com.hooosberg.docktouchbar.verify-minimize", isRunning: true)
DockModel.previewTiles = [tile]
let controller = DockBarController()
controller.reload()
let item = controller.touchBar(NSTouchBar(), makeItemForIdentifier: .init("com.maohuhu.docktouchbar.dock")) as! NSCustomTouchBarItem
let scrubber = item.view.subviews.compactMap { $0 as? NSScrubber }.first!
controller.scrubber(scrubber, didSelectItemAt: 0)
controller.scrubber(scrubber, didSelectItemAt: 0)
let minimizedOK = wait(5, { isMinimized() == nativeMinimized && onScreen() == nativeOnScreen && (isMinimized() || !onScreen() || shrunk(frame())) })
check(minimizedOK, "Production double-tap matches native minimization")
check(!fixtureApp.isHidden, "App remains unhidden")
controller.scrubber(scrubber, didSelectItemAt: 0)
check(wait(5, { onScreen() && !isMinimized() && !shrunk(frame()) }), "Single tap restores the minimized window")
controller.doubleTapMinimizes = false
controller.scrubber(scrubber, didSelectItemAt: 0)
controller.scrubber(scrubber, didSelectItemAt: 0)
settle(2.8) // 等待两次切换和后台纠正结束，随后核对稳定结果。
let disabledOK = wait(5, { onScreen() && !isMinimized() && !shrunk(frame()) })
if !disabledOK { print("DETAIL disabled: pid=\(pid) terminated=\(fixtureApp.isTerminated) hidden=\(fixtureApp.isHidden) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) minimized=\(isMinimized()) onScreen=\(onScreen()) frame=\(frame()) original=\(original)") }
check(disabledOK, "Disabled double-tap setting keeps the window open")
_ = fixtureApp.terminate()
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
