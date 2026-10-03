import AppKit
import ApplicationServices

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
}
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; wait(0.1) }
    return condition()
}
func minimized(_ w: AXUIElement) -> Bool {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &v)
    return v as? Bool == true
}

guard AXIsProcessTrusted() else { print("SKIP: 运行本脚本的终端没有辅助功能权限"); exit(2) }
let trash = DockTile.trash
let finder = TrashWindow.finderApp!
func openTrash() {
    NSWorkspace.shared.open(trash.url!)
    _ = waitUntil(4) { TrashWindow.isOpen }
}
func closeTrash() -> QuitOutcome? {
    var result: QuitOutcome?
    QuitPlanner.perform(.closeTrash, on: finder) { result = $0 }
    _ = waitUntil(5) { result != nil }
    return result
}

// 开始前把可能已经开着的废纸篓窗口收掉，保证从干净状态开始。
if TrashWindow.isOpen { _ = closeTrash() }
check(!TrashWindow.isOpen, "Start: no Trash window")
check(DockModel.tiles(includePinned: true).last?.isRunning == false, "Trash tile is dimmed when the window is closed")
check(!DockModel.tiles(includePinned: false).contains { $0.kind == .trash }, "Running-only: Trash is hidden when its window is closed")

openTrash()
check(TrashWindow.isOpen, "Trash window is recognised after opening it")
check(DockModel.tiles(includePinned: false).last?.kind == .trash && DockModel.tiles(includePinned: false).last?.isRunning == true,
      "Trash tile is bright (and shown in running-only mode) while the window is open")
let finderTile = DockModel.tiles(includePinned: false).first
check(finderTile?.bundleID == "com.apple.finder" && finderTile?.isRunning == true,
      "Running-only: Finder shows at the far left while the Trash window is open")

// 双击：最小化废纸篓窗口（窗口还在，只是收起来）。台前调度开着时窗口会缩成侧栏缩略图而不是进程序坞，
// 所以不只看 AXMinimized，也看窗口实际显示的大小。
func shownWidth() -> CGFloat? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let w = list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == finder.processIdentifier
        && ($0[kCGWindowName as String] as? String) != nil && ($0[kCGWindowLayer as String] as? Int) == 0 }
    return (w?[kCGWindowBounds as String] as? [String: CGFloat])?["Width"]
}
NSWorkspace.shared.open(trash.url!)
wait(1)
let widthBefore = shownWidth()
var message: String?? = .none
AppSwitcher.minimize(trash) { message = .some($0) }
_ = waitUntil(5) { message != nil }
check(message == .some(nil), "Double-tap on Trash reports success (message=\(String(describing: message)))")
wait(1)
let widthAfter = shownWidth()
let isMin = TrashWindow.windows()?.allSatisfy(minimized) == true
print("   width before=\(String(describing: widthBefore)) after=\(String(describing: widthAfter)) minimized=\(isMin)")
check(TrashWindow.isOpen && (isMin || widthAfter == nil || (widthBefore != nil && widthAfter! < widthBefore! * 0.6)),
      "Trash window was minimized (or shrunk to a Stage Manager thumbnail), not closed")

// 长按：关闭（包括已经最小化的）
let outcome = closeTrash()
check(outcome == .some(.done), "Long-press on Trash closes the window (outcome=\(String(describing: outcome)))")
check(waitUntil(3) { !TrashWindow.isOpen }, "Trash window is gone")

// 访达没有任何窗口时，仅运行模式下访达图标不显示
let remaining = AppSwitcher.hasOpenWindows(pid: finder.processIdentifier)
let tiles = DockModel.tiles(includePinned: false)
check(tiles.contains { $0.bundleID == "com.apple.finder" } == remaining,
      "Running-only: Finder icon visible only when Finder has windows (windows=\(remaining))")

// 再点一次垃圾桶能重新打开
openTrash()
check(TrashWindow.isOpen, "Tapping Trash again reopens the window")
_ = closeTrash()
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
