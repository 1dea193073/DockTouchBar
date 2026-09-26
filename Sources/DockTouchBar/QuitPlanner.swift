import AppKit
import ApplicationServices

/// 长按图标时做什么：先看这个 App 现在的样子，再决定，并且保证每次长按都有反馈，做不到的要说清楚。
///
/// 背景（苹果的机制）：`NSRunningApplication.terminate()` 只是“发出退出请求”，返回 true 不代表退出了，App 可以拒绝或者推迟：
/// 有未保存的文稿会弹出“要保存吗”，终端里有进程在跑会弹确认，这时 App 在后台等你回答，而你在 Touch Bar 上什么都看不到。
/// `forceTerminate()` 是直接杀进程，会丢数据，这里不用。访达不能被正常退出（默认没有“退出”菜单项）。
enum QuitPlan {
    /// 退出整个 App（等同 ⌘Q）。
    case quitApp
    /// 只关最前面这个 App 的当前窗口（窗口不止一个，或者是访达）。
    case closeWindow
    /// 隐藏整个 App（访达不在前面时，它退不了也没有窗口可关，只能藏起来）。
    case hideApp
    /// 什么也做不了，只说明情况。
    case notice(String)
}

/// 执行之后的结果。
enum QuitOutcome {
    /// 成功了（退出了 / 窗口关了 / 藏起来了）。
    case done
    /// App 在等你回答（弹出了“要保存吗”之类的确认框）。
    case needsAnswer
    /// 请求发出去了，App 还在，也没有看到确认框（可能在别的桌面，可能没有响应，可能拒绝退出）。
    case stillOpen
}

enum QuitPlanner {
    private static let finderID = "com.apple.finder"
    /// 发出请求后，等多久还没变化就当作“没成功”。
    private static let patience: TimeInterval = 1.4

    // MARK: - 决定做什么

    /// - 访达：在最前面而且有窗口 → 关当前窗口；有窗口但不在最前面，或没有辅助功能权限 → 隐藏；在最前面却没有窗口 → 说明情况。
    /// - 其他 App：在最前面而且窗口不止一个 → 关当前窗口（要退出整个 App 用 ⌘Q，或者一个个关到只剩一个）；否则退出整个 App。
    /// 只算当前桌面上的标准窗口（辅助功能看不到别的桌面上的窗口），没有辅助功能权限时数不了窗口，按退出处理。
    static func plan(for app: NSRunningApplication) -> QuitPlan {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let count = standardWindows(of: app.processIdentifier)?.count
        if app.bundleIdentifier == finderID {
            guard isFront else { return .hideApp }
            guard let count else { return .hideApp }
            return count == 0
                ? .notice(L10n.tr("访达没有窗口，也不能退出", "Finder has no window and can't be quit"))
                : .closeWindow
        }
        if isFront, let count, count >= 2 { return .closeWindow }
        return .quitApp
    }

    // MARK: - 执行，并核对结果

    /// 执行 `plan`，最多等 `patience` 秒看结果，然后在主线程回调一次。
    static func perform(_ plan: QuitPlan, on app: NSRunningApplication, completion: @escaping (QuitOutcome) -> Void) {
        let pid = app.processIdentifier
        switch plan {
        case .notice:
            completion(.done)
        case .hideApp:
            _ = app.hide()
            completion(.done)
        case .quitApp:
            guard app.terminate() else { completion(.stillOpen); return }
            wait(until: { app.isTerminated }) { finished in
                completion(finished ? .done : (hasPendingDialog(pid) ? .needsAnswer : .stillOpen))
            }
        case .closeWindow:
            let before = standardWindows(of: pid)?.count ?? 0
            guard closeFocusedWindow(of: pid) else { completion(.stillOpen); return }
            wait(until: { app.isTerminated || (standardWindows(of: pid)?.count ?? 0) < before }) { finished in
                completion(finished ? .done : (hasPendingDialog(pid) ? .needsAnswer : .stillOpen))
            }
        }
    }

    /// 每 0.2 秒看一次 `condition`，成了就立刻回调 true；等满 `patience` 秒还没成就回调 false。
    private static func wait(until condition: @escaping () -> Bool, then done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(patience)
        func check() {
            if condition() { done(true); return }
            if Date() >= deadline { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
    }

    // MARK: - 辅助功能

    /// 当前桌面上没最小化的标准窗口。没有权限或读不到时是 nil。
    private static func standardWindows(of pid: pid_t) -> [AXUIElement]? {
        allWindows(of: pid)?.filter {
            string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole && bool($0, kAXMinimizedAttribute) != true
        }
    }

    private static func allWindows(of pid: pid_t) -> [AXUIElement]? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    /// 有没有确认框：窗口上挂着“表单”（sheet，比如“要保存吗”），或者有独立的对话框窗口。
    private static func hasPendingDialog(_ pid: pid_t) -> Bool {
        for window in allWindows(of: pid) ?? [] {
            let subrole = string(window, kAXSubroleAttribute)
            if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return true }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement],
               list.contains(where: { string($0, kAXRoleAttribute) == kAXSheetRole }) { return true }
        }
        return false
    }

    /// 按下当前窗口的红色关闭按钮（和用手点一样，有未保存内容会弹出确认）。
    private static func closeFocusedWindow(of pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if AXUIElementCopyAttributeValue(element, name as CFString, &window) == .success,
               let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() { break }
            window = nil
        }
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXCloseButtonAttribute as CFString, &button) == .success,
              let b = button, CFGetTypeID(b) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? Bool : nil
    }
}
