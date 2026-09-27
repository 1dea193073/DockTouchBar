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
    /// 发出请求后，等多久还没变化就当作“没成功”。退出整个 App 和只关窗口都用这个：
    /// App 退出前的收尾（写偏好设置、关子进程……）、关窗口的动画，都可能比这更慢，尤其是机器卡的时候；
    /// 等太短会把“其实办成了，只是慢”误判成“没办成”——退出场景下这只是提示文字说错话，
    /// 关窗口场景下还会因为接下来切回那个没了窗口的 App 而看着像“又开了一个”。
    private static let patience: TimeInterval = 2.6

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
            wait(until: { isGoneFromSight(app, pid: pid) }) { finished in
                completion(finished ? .done : (hasPendingDialog(pid) ? .needsAnswer : .stillOpen))
            }
        case .closeWindow:
            let before = standardWindows(of: pid)?.count ?? 0
            guard let closedWindow = closeFocusedWindow(of: pid) else { completion(.stillOpen); return }
            wait(until: { app.isTerminated || !elementStillExists(closedWindow) || (standardWindows(of: pid)?.count ?? 0) < before }) { finished in
                completion(finished ? .done : (hasPendingDialog(pid) ? .needsAnswer : .stillOpen))
            }
        }
    }

    /// 每 0.2 秒看一次 `condition`，成了就立刻回调 true；等满 `patience` 秒还没成就回调 false。
    private static func wait(patience: TimeInterval = patience, until condition: @escaping () -> Bool, then done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(patience)
        func check() {
            if condition() { done(true); return }
            if Date() >= deadline { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
    }

    /// 退出这个 App 是不是已经在用户眼前发生了：真退出了；或者它把自己藏起来了（类似访达的隐藏兜底）；
    /// 或者当前桌面上已经没有它的标准窗口。不强求进程真的已经退出——有些 App（实测：企业 IM 一类）收到
    /// 退出请求后窗口立刻就没了，但后台还要花几十秒断开长连接、写本地缓存才真正退出进程，早就超出任何
    /// 合理的等待时间；对用户来说，窗口没了就是关掉了，不该因为它在后台收尾而被判定成“没关闭”。
    private static func isGoneFromSight(_ app: NSRunningApplication, pid: pid_t) -> Bool {
        app.isTerminated || app.isHidden || (standardWindows(of: pid)?.count ?? 0) == 0
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

    /// 按下当前窗口的红色关闭按钮（和用手点一样，有未保存内容会弹出确认）。成功时把这个窗口的辅助功能元素
    /// 带回去，用来之后核对它是不是真的没了（`elementStillExists`），比只看窗口数量变化更准。
    private static func closeFocusedWindow(of pid: pid_t) -> AXUIElement? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if AXUIElementCopyAttributeValue(element, name as CFString, &window) == .success,
               let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() { break }
            window = nil
        }
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = window as! AXUIElement
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXCloseButtonAttribute as CFString, &button) == .success,
              let b = button, CFGetTypeID(b) == AXUIElementGetTypeID() else { return nil }
        guard AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success else { return nil }
        return windowElement
    }

    /// 这个窗口元素是不是还在：关掉的窗口再去读它的属性，系统会报“元素无效”。
    /// 读不出结果（App 卡住、超时）时按“还在”处理，交给窗口数量那条线索兜底。
    private static func elementStillExists(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value) != .invalidUIElement
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
