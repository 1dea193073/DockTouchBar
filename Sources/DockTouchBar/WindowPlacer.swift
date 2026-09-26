import AppKit
import ApplicationServices

/// “窗口居中”按钮：把当前最前面 App 的窗口调成屏幕正中间的指定大小（默认是正方形），上下留一点边距。
/// 全部走公开的辅助功能接口（读/写窗口的位置和大小），没有私有 API；居中就是算一下所在屏幕可用区域的中心。
enum WindowPlacer {
    private static let queue = DispatchQueue(label: "com.maohuhu.docktouchbar.placer", qos: .userInitiated)

    /// 高度：屏幕可用高度（去掉菜单栏和 Dock）的 `heightPercent`%。
    /// 宽度：`widthPercent` 为 0 时和高度一样（正方形），否则是屏幕可用宽度的 `widthPercent`%。
    static func centerFrontmost(heightPercent: Int, widthPercent: Int) {
        guard AXIsProcessTrusted() else {
            AppSwitcher.requestAccessibilityAccess()
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return }
        let pid = app.processIdentifier
        queue.async {
            // 刚切到前台的 App 窗口可能还没就绪，最多等 1 秒。
            let deadline = Date().addingTimeInterval(1)
            repeat {
                if let window = focusedWindow(pid: pid),
                   place(window, heightPercent: heightPercent, widthPercent: widthPercent) { return }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
        }
    }

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

    private static func place(_ window: AXUIElement, heightPercent: Int, widthPercent: Int) -> Bool {
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { return true }   // 全屏窗口不动，也不用再等

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let current = frame(of: window) else { return false }

        // 屏幕坐标：辅助功能用主屏左上角为原点、向下为正；NSScreen 是左下角为原点、向上为正。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: current.midX, y: current.midY)
        let screen = NSScreen.screens.first { screenRect($0.frame, primaryHeight).contains(center) } ?? NSScreen.main
        guard let screen else { return false }
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

        let height = min(area.height * CGFloat(heightPercent) / 100, area.height).rounded()
        let width = (widthPercent == 0 ? min(height, area.width) : min(area.width * CGFloat(widthPercent) / 100, area.width)).rounded()
        let size = CGSize(width: width, height: height)

        // 先把窗口挪到目标位置，再改大小：反过来的话，窗口先变大、底边可能伸出这块屏幕，系统会把大小压回去，
        // 副屏（尤其是竖屏、窗口很大时）会来回被系统拉扯。
        // 有的 App 有最小/最大尺寸不会照办，调整也是异步的；之后按读回的实际大小重新居中，直到大小稳定。
        setPosition(window, CGPoint(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded()))
        setSize(window, size)
        var last = CGSize.zero
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.05)
            let actual = frame(of: window)?.size ?? size
            setPosition(window, CGPoint(x: (area.midX - actual.width / 2).rounded(),
                                        y: (area.midY - actual.height / 2).rounded()))
            if actual == last { break }
            last = actual
        }
        return true
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
