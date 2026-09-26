import AppKit
import ApplicationServices

/// “窗口居中 / 最大化”按钮：对当前最前面 App 的窗口，第一下居中，再点一下最大化，再点又回到居中，来回切换。
/// 每次点之前先读窗口现在的位置和大小，判断它此刻是什么样子，再决定这一下做什么：
/// - 现在是居中的样子 → 最大化；
/// - 现在是最大化的样子 → 居中；
/// - 别的样子（用户自己拖过、换了个 App、换了个窗口……）→ 先居中。
/// 全部走公开的辅助功能接口（读/写窗口的位置和大小），没有私有 API。
///
/// “最大化”是铺满所在屏幕的可用区域（菜单栏和 Dock 还在），不是 macOS 的原生全屏：
/// 原生全屏会新开一个桌面、动画要将近一秒，还会和跨桌面切换互相干扰。
enum WindowPlacer {
    /// 这一下点下去会做什么，也就是按钮该显示哪个图标。
    enum Action {
        case center
        case maximize
    }

    private enum State {
        case centered
        case maximized
        case free
    }

    private static let queue = DispatchQueue(label: "com.maohuhu.docktouchbar.placer", qos: .userInitiated)
    /// 判断“现在就是居中 / 最大化的样子”时允许的误差（pt）。窗口边框、取整都会让数字差几个点。
    private static let tolerance: CGFloat = 8
    /// 我们自己摆过的窗口，最后实际是什么样。有的 App 有最小 / 最大尺寸，摆出来和算出来的不完全一样；
    /// 不记下来的话，这种窗口永远认不出自己是“居中的”，就会一直居中、最大化不了。只在 `queue` 上访问。
    private static var placed: [(window: AXUIElement, action: Action, frame: CGRect)] = []

    /// 点了按钮：按窗口现在的样子居中或最大化。`done` 在主线程回调，参数是“再点一下会做什么”。
    /// 高度：屏幕可用高度（去掉菜单栏和 Dock）的 `heightPercent`%。
    /// 宽度：`widthPercent` 为 0 时和高度一样（正方形），否则是屏幕可用宽度的 `widthPercent`%。
    static func toggleFrontmost(heightPercent: Int, widthPercent: Int, done: @escaping (Action) -> Void) {
        guard AXIsProcessTrusted() else {
            AppSwitcher.requestAccessibilityAccess()
            return
        }
        guard let pid = frontmostPID() else { return }
        queue.async {
            // 刚切到前台的 App 窗口可能还没就绪，最多等 1 秒。
            let deadline = Date().addingTimeInterval(1)
            repeat {
                if let window = focusedWindow(pid: pid), let info = inspect(window, heightPercent, widthPercent) {
                    let action = info.state == .centered && info.resizable ? Action.maximize : .center
                    perform(action, on: window, info: info, heightPercent, widthPercent)
                    let next = inspect(window, heightPercent, widthPercent).map(action(after:)) ?? .center
                    DispatchQueue.main.async { done(next) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
        }
    }

    /// 只看不动：最前面 App 的窗口现在是什么样，再点一下会做什么。用来让按钮的图标跟着窗口变。
    /// 没有权限、最前面是自己、找不到窗口时，不回调（图标保持原样）或按“居中”回调。
    static func nextAction(heightPercent: Int, widthPercent: Int, done: @escaping (Action) -> Void) {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { done(.center) }
            return
        }
        guard let pid = frontmostPID() else { return }
        queue.async {
            let next = focusedWindow(pid: pid)
                .flatMap { inspect($0, heightPercent, widthPercent) }
                .map(action(after:)) ?? .center
            DispatchQueue.main.async { done(next) }
        }
    }

    private static func frontmostPID() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return nil }
        return app.processIdentifier
    }

    private static func action(after info: Info) -> Action {
        info.state == .centered && info.resizable ? .maximize : .center
    }

    // MARK: - 判断窗口现在的样子

    private struct Info {
        let area: CGRect
        let resizable: Bool
        let state: State
    }

    /// 全屏（macOS 原生全屏）的窗口不动，返回 nil。
    private static func inspect(_ window: AXUIElement, _ heightPercent: Int, _ widthPercent: Int) -> Info? {
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { return nil }
        guard let current = frame(of: window), let area = visibleArea(containing: current) else { return nil }

        var settable = DarwinBoolean(false)
        let resizable = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue

        let state: State
        if near(current, area) {
            state = .maximized
        } else if near(current, centeredRect(in: area, heightPercent, widthPercent)) {
            state = .centered
        } else if let record = placed.first(where: { CFEqual($0.window, window) }), near(current, record.frame) {
            state = record.action == .center ? .centered : .maximized
        } else {
            state = .free
        }
        return Info(area: area, resizable: resizable, state: state)
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// 居中后的样子：在 `area` 正中间。
    private static func centeredRect(in area: CGRect, _ heightPercent: Int, _ widthPercent: Int) -> CGRect {
        let height = min(area.height * CGFloat(heightPercent) / 100, area.height).rounded()
        let width = (widthPercent == 0 ? min(height, area.width) : min(area.width * CGFloat(widthPercent) / 100, area.width)).rounded()
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    /// 窗口所在屏幕的可用区域（去掉菜单栏和 Dock），用辅助功能的坐标：主屏左上角为原点、向下为正。
    private static func visibleArea(containing window: CGRect) -> CGRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: window.midX, y: window.midY)
        let screen = NSScreen.screens.first { screenRect($0.frame, primaryHeight).contains(center) } ?? NSScreen.main
        guard let screen else { return nil }
        var area = screenRect(screen.visibleFrame, primaryHeight)
        // 每块屏幕有自己的菜单栏时，副屏的 visibleFrame 有时不扣掉它：按主屏菜单栏的高度补扣，窗口才不会顶到菜单栏下面被系统推挪。
        if let primary = NSScreen.screens.first {
            let menuBar = primary.frame.maxY - primary.visibleFrame.maxY
            let full = screenRect(screen.frame, primaryHeight)
            if area.minY < full.minY + menuBar {
                area = CGRect(x: area.minX, y: full.minY + menuBar, width: area.width,
                              height: area.maxY - (full.minY + menuBar))
            }
        }
        return area
    }

    // MARK: - 摆窗口

    private static func perform(_ action: Action, on window: AXUIElement, info: Info, _ heightPercent: Int, _ widthPercent: Int) {
        let area = info.area
        // 不能改大小的窗口（计算器、有的设置窗口）只挪位置：把它原来的大小摆到正中间。
        guard info.resizable else {
            if let current = frame(of: window) {
                setPosition(window, CGPoint(x: (area.midX - current.width / 2).rounded(), y: (area.midY - current.height / 2).rounded()))
                remember(window, .center)
            }
            return
        }
        let target = action == .maximize ? area : centeredRect(in: area, heightPercent, widthPercent)

        // 先把窗口挪到目标位置，再改大小：反过来的话，窗口先变大、底边可能伸出这块屏幕，系统会把大小压回去，
        // 副屏（尤其是竖屏、窗口很大时）会来回被系统拉扯。
        // 有的 App 有最小/最大尺寸不会照办，调整也是异步的；之后按读回的实际大小重新居中，直到大小稳定。
        setPosition(window, target.origin)
        setSize(window, target.size)
        var last = CGSize.zero
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.05)
            let actual = frame(of: window)?.size ?? target.size
            setPosition(window, CGPoint(x: (area.midX - actual.width / 2).rounded(), y: (area.midY - actual.height / 2).rounded()))
            if actual == last { break }
            last = actual
        }
        remember(window, action)
    }

    /// 记下这个窗口摆完之后实际的样子。
    private static func remember(_ window: AXUIElement, _ action: Action) {
        guard let actual = frame(of: window) else { return }
        placed.removeAll { CFEqual($0.window, window) }
        placed.append((window, action, actual))
        if placed.count > 8 { placed.removeFirst() }
    }

    // MARK: - 辅助功能的读写

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func screenRect(_ rect: CGRect, _ primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let p = value, AXValueGetValue(p as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let s = value, AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private static func setPosition(_ window: AXUIElement, _ origin: CGPoint) {
        var origin = origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}
