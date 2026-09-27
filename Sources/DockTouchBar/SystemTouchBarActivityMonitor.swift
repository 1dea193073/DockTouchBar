import AppKit
import Darwin

/// 监听会临时接管 Touch Bar 的系统界面。
///
/// 真正承载 ⌘⇧4 选区、⌘⇧5 工具条和录屏控制的是 `screencaptureui`；用户从“截图” App
/// 打开时还会经过 Screenshot 启动器。DockTouchBar 的全宽系统模态栏优先级更高，因而必须在
/// 截图任务活动期间主动让位，结束后再恢复。screencaptureui 自身会在 Esc 后继续存活数秒，
/// 因此不能只用它的退出作为恢复信号。
///
/// `NSTouchBar` 没有公开 API 可枚举“当前谁正在显示临时 Touch Bar”。这里刻意只匹配已在
/// 本机核对过的系统 bundle id，避免把普通 App 切换误当作需要撤下 Dock 的情况。
final class SystemTouchBarActivityMonitor {
    /// `screencaptureui` 是快捷键实际启动、并拥有 Touch Bar 截图/录屏控制的系统 App。
    /// 保留 Screenshot 启动器，让从“截图.app”手动打开时也遵守同样的让位规则。
    private static let captureBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
    ]

    private let stateDidChange: (Bool) -> Void
    private var runningAppsObservation: NSKeyValueObservation?
    private var taskTimer: Timer?
    private var screenshotUIIsRunning = false
    private var hasObservedInteractiveTask = false
    private var missingTaskSamples = 0
    private var isScreenshotActive = false

    init(stateDidChange: @escaping (Bool) -> Void) {
        self.stateDidChange = stateDidChange
    }

    func start() {
        guard runningAppsObservation == nil else { return }
        // screencaptureui 是 launchd 管理的后台 agent。在 macOS 27 上它会出现在
        // runningApplications，但不会触发 didLaunchApplication 通知。
        // KVO 能捕获它的启动和退出；回到主线程后再读取更新完毕的列表。
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        runningAppsObservation = nil
        taskTimer?.invalidate()
        taskTimer = nil
        screenshotUIIsRunning = false
        hasObservedInteractiveTask = false
        missingTaskSamples = 0
        isScreenshotActive = false
    }

    private func refresh() {
        guard runningAppsObservation != nil else { return }
        let uiIsRunning = NSWorkspace.shared.runningApplications.contains {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return Self.captureBundleIDs.contains(bundleID)
        }

        guard uiIsRunning else {
            screenshotUIIsRunning = false
            hasObservedInteractiveTask = false
            missingTaskSamples = 0
            taskTimer?.invalidate()
            taskTimer = nil
            setActive(false)
            return
        }

        if !screenshotUIIsRunning {
            screenshotUIIsRunning = true
            // 如果系统将来不再使用 /usr/sbin/screencapture，仍保持旧的 UI 进程生命周期兜底。
            setActive(true)
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                self?.sampleInteractiveTask()
            }
            RunLoop.main.add(timer, forMode: .common)
            taskTimer = timer
        }
        sampleInteractiveTask()
    }

    private func sampleInteractiveTask() {
        guard screenshotUIIsRunning, let taskIsRunning = Self.interactiveCaptureTaskIsRunning() else { return }
        if taskIsRunning {
            hasObservedInteractiveTask = true
            missingTaskSamples = 0
            setActive(true)
        } else if hasObservedInteractiveTask {
            // 截图工具条到录屏进程的交接中可能有短暂空档；连续两次缺席才恢复。
            missingTaskSamples += 1
            if missingTaskSamples >= 2 { setActive(false) }
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isScreenshotActive else { return }
        isScreenshotActive = active
        stateDidChange(active)
    }

    /// 快捷键/截图工具条由 SystemUIServer 启动 /usr/sbin/screencapture；它在 Esc 或录屏停止时
    /// 立即退出，早于 screencaptureui agent。仅在 agent 活动期间短时检查其子进程；平时零轮询。
    /// 无法确认 SystemUIServer 时返回 nil，保守地等待 agent 退出。
    private static func interactiveCaptureTaskIsRunning() -> Bool? {
        guard let systemUI = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systemuiserver"
        ).first else { return nil }
        var children = [pid_t](repeating: 0, count: 512)
        let bytes = children.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(systemUI.processIdentifier),
                          $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard bytes >= 0, Int(bytes) < children.count * MemoryLayout<pid_t>.size else { return nil }
        for pid in children.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            let length = name.withUnsafeMutableBufferPointer {
                proc_name(pid, $0.baseAddress, UInt32($0.count))
            }
            guard length > 0, String(cString: name) == "screencapture" else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            let pathLength = path.withUnsafeMutableBufferPointer {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            if pathLength > 0, String(cString: path) == "/usr/sbin/screencapture" { return true }
        }
        return false
    }
}

// 2026-09-28：这里原本有一个 SiriTouchBarActivityMonitor，按 `com.apple.Siri` 是否出现在
// runningApplications 里判断 Siri 是否正占着 Touch Bar，设计前提是“和 screencaptureui 一样，
// 用完就退出”。实机验证推翻了这个前提：Siri 的 agent 进程会在交互结束后继续存活很久（本机
// 观察到挂了将近 30 分钟没退出，被 assistantd 按自己的节奏续着），不是“用完即退”。用进程在
// 不在判断会导致 Dock 长时间卡住不恢复，所以整个去掉了，改天要做的话得换一个真正反映“Touch
// Bar 上是不是还在显示 Siri 波形”的信号，不能再用这个假设。

/// 监听物理 Fn 键：按住时 Touch Bar 固件会把显示切成 F1–F12 功能键行，这一步发生在
/// TouchBarServer 里，不对应任何会出现在 `runningApplications` 里的 App 进程，所以只能
/// 靠监听修饰键变化（`.function`）来发现，不能用 Siri/截图那套“看进程在不在”的办法。
///
/// 全局修饰键监听需要“辅助功能”权限才能收到事件；权限不够时监听器照常装上，只是收不到
/// 回调——和本项目其它依赖辅助功能的功能（窗口操作、长按退出）权限缺失时的降级方式一致，
/// 不会崩溃也不用单独提示。
///
/// 未用物理 Fn 键在实体 Touch Bar 上验证过按住时 Dock 是否真的被功能键行盖住；这里先假设
/// 会（Fn 切换在文档记录里是固件级別的强制展示），按住/松开 Fn 时对应暂停/恢复 Dock。
final class FunctionRowActivityMonitor {
    private let stateDidChange: (Bool) -> Void
    private var monitor: Any?
    private var isFnDown = false

    init(stateDidChange: @escaping (Bool) -> Void) {
        self.stateDidChange = stateDidChange
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isFnDown = false
    }

    private func handle(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.function)
        guard down != isFnDown else { return }
        isFnDown = down
        stateDidChange(down)
    }
}
