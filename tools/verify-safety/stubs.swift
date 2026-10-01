import AppKit

enum TouchBarBridge {
    static let isAvailable = true
    static var presents = 0
    static var dismisses = 0
    static func hideCloseBox() {}
    static func addTrayItem(_ item: NSTouchBarItem) {}
    static func removeTrayItem(_ item: NSTouchBarItem) {}
    static func present(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) { presents += 1 }
    static func dismiss(_ bar: NSTouchBar) { dismisses += 1 }
}
enum ScreenBrightness { static var current: Float? = 1 }
final class SystemTouchBarActivityMonitor {
    var started = false
    var stateOnRefresh: Bool?
    let callback: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { callback = onChange }
    func start() { started = true }
    func stop() { started = false }
    func refreshCurrentState() { if started, let stateOnRefresh { callback(stateOnRefresh) } }
    // 即使已停止也发回调，模拟排队中的旧通知。
    func emit(_ active: Bool) { callback(active) }
}
final class FunctionRowActivityMonitor {
    var started = false
    var stateOnRefresh: Bool?
    let callback: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { callback = onChange }
    func start() { started = true }
    func stop() { started = false }
    func refreshCurrentState() { if started, let stateOnRefresh { callback(stateOnRefresh) } }
    func emit(_ active: Bool) { callback(active) }
}
