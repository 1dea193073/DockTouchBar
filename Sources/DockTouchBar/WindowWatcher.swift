import AppKit
import ApplicationServices

/// 盯着最前面 App 的窗口有没有被移动、改大小、换成另一个窗口，有变化就通知一声（合并成一次）。
/// 用来让“居中 / 最大化”按钮的图标跟着窗口的实际样子变：用户自己拖、用别的工具摆，图标也对得上。
/// 用辅助功能的观察者（AXObserver）：系统在窗口真的变了才通知，空闲时不轮询、不唤醒。
final class WindowWatcher {
    /// 窗口变了（拖动结束后约 0.2 秒回调一次）。在主线程。
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var app: AXUIElement?
    private var window: AXUIElement?
    private var pending: DispatchWorkItem?

    private static let windowNotifications = [kAXMovedNotification, kAXResizedNotification]

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
        watcher.handle(notification as String)
    }

    /// 改成盯着这个进程。没有辅助功能权限时什么也不做。
    func watch(pid: pid_t) {
        stop()
        guard AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        app = element
        watchFocusedWindow()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        app = nil
        window = nil
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// 换成盯着现在的焦点窗口（移动、改大小）。
    private func watchFocusedWindow() {
        guard let observer else { return }
        if let old = window {
            for name in Self.windowNotifications { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        window = nil
        var value: CFTypeRef?
        guard let app, AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let focused = value as! AXUIElement
        for name in Self.windowNotifications { AXObserverAddNotification(observer, focused, name as CFString, refcon) }
        window = focused
    }

    private func handle(_ notification: String) {
        if notification == kAXFocusedWindowChangedNotification { watchFocusedWindow() }
        // 拖动窗口时通知很密，等它停下来再通知一次。
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
