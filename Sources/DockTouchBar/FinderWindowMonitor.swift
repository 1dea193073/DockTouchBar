import AppKit
import ApplicationServices

/// 盯着访达窗口的开关，有变化就通知一声。
///
/// 访达进程杀不掉，开关窗口既不会改变 `runningApplications`，也不会触发 `didActivateApplication`——
/// `DockBarController` 原来只监听这两种通知，所以访达状态点的刷新完全要等到别的 App 切换恰好
/// 顺带触发一次 `reload()`，快则秒级、慢则一直不刷。这里跟 `WindowWatcher` 一样用辅助功能的观察者：
/// 系统在窗口真的开关时才通知，空闲时不轮询、不唤醒。没有辅助功能权限时什么也不做，和本项目其它
/// 依赖辅助功能的功能一样静默降级（降级后徽标仍会随别的通知机会刷新，只是不再是“立刻”；
/// 长按退出前会现查一次真实状态，不依赖这里的通知，权限缺不缺都对）。
///
/// “窗口关掉了”这个通知，辅助功能只在装在具体的窗口元素上才会发，装在 App 上不会发，
/// 所以新窗口一出现（`kAXWindowCreatedNotification`）就要单独给它也装一份“它被销毁了”的订阅；
/// 装观察者的时候已经开着的窗口，先手动订阅一遍。
final class FinderWindowMonitor {
    /// 窗口数量可能变了。在主线程。
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var watchedPID: pid_t?
    private var app: AXUIElement?
    private var watchedWindows = Set<AXUIElement>()
    private var pending: DispatchWorkItem?

    private static let createdNotification = kAXWindowCreatedNotification as CFString
    private static let destroyedNotification = kAXUIElementDestroyedNotification as CFString

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        Unmanaged<FinderWindowMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(element: element, notification: notification as String)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// 改成盯着这个 PID；和已经在盯的一样就什么都不做（访达一般不会重启，PID 不会变）。
    func watch(pid: pid_t?) {
        // 首次无权限时没有装上 observer，后来授权后，即使 PID 没变也应重新尝试订阅。
        guard pid != watchedPID || (observer == nil && AXIsProcessTrusted()) else { return }
        stop()
        watchedPID = pid
        guard let pid, AXIsProcessTrusted() else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXObserverAddNotification(created, appElement, Self.createdNotification, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        app = appElement
        watchExistingWindows()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        app = nil
        watchedWindows.removeAll()
        watchedPID = nil
    }

    private func watchExistingWindows() {
        guard let app else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows { watchDestruction(of: window) }
    }

    private func watchDestruction(of window: AXUIElement) {
        guard let observer, !watchedWindows.contains(window) else { return }
        AXObserverAddNotification(observer, window, Self.destroyedNotification, refcon)
        watchedWindows.insert(window)
    }

    private func handle(element: AXUIElement, notification: String) {
        let isCreate = notification == kAXWindowCreatedNotification
        if isCreate {
            watchDestruction(of: element)
        } else {
            watchedWindows.remove(element)
        }
        // 开窗口时辅助功能通知一到，`hasNormalWindows` 真正查的 CGWindowList 立刻就是对的；关窗口有个
        // 关闭动画，实测 CGWindowList 要 0.2～0.5 秒才会跟上，太早查会读到刚关掉的那扇窗口还在——
        // 所以关窗口特意多等一会儿，两种情况都顺带把连续几下的抖动合并成一次。
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isCreate ? 0.1 : 0.5), execute: work)
    }
}
