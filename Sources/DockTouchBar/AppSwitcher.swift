import AppKit

/// 点 Touch Bar 图标后切到对应的 App。
///
/// 系统只在“用户点 Dock / 按 ⌘Tab”时自动切到 App 所在的桌面；后台 App 发起的激活只会让它变成前台，
/// 桌面不动（macOS 27 实测，`openApplication` 和 `NSRunningApplication.activate` 都一样）。
/// 所以当目标 App 在当前桌面没有窗口、但在别的桌面有窗口时，这里自己找到那个窗口：
/// 先用 SkyLight 把它设为前台窗口，再用辅助功能 Raise，系统随之切到那个桌面（和 AltTab 的做法相同）。
/// 需要辅助功能权限；没有权限或任何一步失败，都退回普通的打开/激活。
enum AppSwitcher {
    private static let queue = DispatchQueue(label: "com.maohuhu.docktouchbar.switcher", qos: .userInitiated)
    private static var didPromptForAccess = false

    static func switchTo(_ tile: DockTile) {
        guard let url = tile.url else { return }
        guard let app = DockModel.runningApp(bundleID: tile.bundleID, url: url), !app.isHidden else {
            launchOrActivate(url)
            return
        }
        let pid = app.processIdentifier
        // 辅助功能调用会跨进程等待目标 App 回应，放到后台，别卡住 Touch Bar。
        queue.async {
            var switched = false
            if let window = windowOnOtherSpaceOnly(of: pid) {
                if AXIsProcessTrusted() {
                    switched = focus(pid: pid, window: window)
                } else {
                    DispatchQueue.main.async { promptForAccessOnce() }
                }
            }
            if !switched {
                DispatchQueue.main.async { launchOrActivate(url) }
            }
        }
    }

    /// 长按：正常退出（等同 ⌘Q，有未保存内容的 App 会自己弹窗询问）。
    static func quit(_ tile: DockTile) {
        guard let url = tile.url, tile.bundleID != "com.apple.finder",
              let app = DockModel.runningApp(bundleID: tile.bundleID, url: url) else { return }
        app.terminate()
    }

    /// 双击：隐藏 App（等同 ⌘H），再点一下图标就回来。
    /// 本来想做成最小化窗口，但开着“台前调度”时，辅助功能设置 AXMinimized、按最小化按钮都返回成功却不生效
    /// （macOS 27 实测，访达和计算器都一样）；隐藏在任何设置下都有效，也不需要权限。
    /// 注意 `hide()` 的返回值不可靠：实测窗口已经隐藏了它仍返回 false。
    static func hide(_ tile: DockTile) {
        guard let url = tile.url, let app = DockModel.runningApp(bundleID: tile.bundleID, url: url) else { return }
        // 稍等一下：双击的第一下刚发出激活请求，App 如果在隐藏之后才处理它，会又显示出来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = app.hide() }
    }

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统的“允许辅助功能”提示，并把本 App 加进 系统设置 → 隐私与安全性 → 辅助功能 的列表。
    static func requestAccessibilityAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 第一次真正需要跨桌面切换时才提示，每次启动最多一次。
    private static func promptForAccessOnce() {
        guard !didPromptForAccess else { return }
        didPromptForAccess = true
        requestAccessibilityAccess()
    }

    /// 和点 Dock 一样走 LaunchServices：没开就启动，开着就切到前台（隐藏的会显示、最小化的会还原）。
    private static func launchOrActivate(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("DockTouchBar: 打开 %@ 失败：%@", url.path, error.localizedDescription)
            }
        }
    }

    // MARK: - 找窗口

    /// 当前桌面上没有这个 App 的窗口、但别的桌面上有时，返回最靠前的那个；其他情况返回 nil。
    private static func windowOnOtherSpaceOnly(of pid: pid_t) -> CGWindowID? {
        guard SkyLight.isAvailable else { return nil }
        if !normalWindows(of: pid, options: [.optionOnScreenOnly, .excludeDesktopElements]).isEmpty {
            return nil
        }
        // 列表按前后顺序排列。最小化的窗口不属于任何桌面，跳过（交给 launchOrActivate 还原）。
        return normalWindows(of: pid, options: [.optionAll, .excludeDesktopElements])
            .first { !SkyLight.spaces(of: $0).isEmpty }
    }

    /// 普通窗口：第 0 层、不透明、不是 App 用来占位的小窗口。
    private static func normalWindows(of pid: pid_t, options: CGWindowListOption) -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 50, (bounds["Height"] ?? 0) > 50 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    // MARK: - 切过去

    private static func focus(pid: pid_t, window: CGWindowID) -> Bool {
        guard SkyLight.makeFront(pid: pid, window: window),
              let element = axWindow(pid: pid, window: window) else { return false }
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    private static func axWindow(pid: pid_t, window: CGWindowID) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        // App 没有响应，就别再逐个试了。
        if result == .cannotComplete { return nil }
        for element in (value as? [AXUIElement]) ?? [] where AXPrivate.windowID(of: element) == window {
            return element
        }
        // 标准接口只返回当前桌面的窗口；其他桌面的窗口要按元素编号逐个试（AltTab 同款做法，实测约 60–80ms）。
        for elementID in UInt64(0)..<1000 {
            guard let element = AXPrivate.element(pid: pid, elementID: elementID) else { continue }
            if AXPrivate.windowID(of: element) == window { return element }
        }
        return nil
    }
}

// MARK: - 私有接口（全部运行时解析，缺了就退回普通激活）

private enum SkyLight {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func symbol<T>(_ name: String, in lib: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        dlsym(lib, name).map { unsafeBitCast($0, to: type) }
    }

    private static let mainConnection = symbol("SLSMainConnectionID", in: handle, as: MainConnectionFn.self)
    private static let copySpaces = symbol("SLSCopySpacesForWindows", in: handle, as: CopySpacesFn.self)
    private static let setFront = symbol("_SLPSSetFrontProcessWithOptions", in: handle, as: SetFrontFn.self)
    private static let postEvent = symbol("SLPSPostEventRecordTo", in: handle, as: PostEventFn.self)
    private static let getPSN = symbol("GetProcessForPID", in: UnsafeMutableRawPointer(bitPattern: -2), as: GetPSNFn.self)

    static let isAvailable = mainConnection != nil && copySpaces != nil && setFront != nil
        && postEvent != nil && getPSN != nil && AXPrivate.isAvailable

    /// 窗口所在的桌面编号；最小化的窗口返回空。
    static func spaces(of window: CGWindowID) -> [UInt64] {
        guard let mainConnection, let copySpaces else { return [] }
        let allSpaces: Int32 = 0x7
        return copySpaces(mainConnection(), allSpaces, [window] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
    }

    static func makeFront(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFront, let postEvent, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        let userGenerated: UInt32 = 0x200
        guard getPSN(pid, &psn) == noErr, setFront(&psn, window, userGenerated) == 0 else { return false }
        // 再发两条“设为关键窗口”的事件记录，键盘焦点才会落在这个窗口上。
        // 字节布局来自 Hammerspoon issue #370，AltTab 也在用。
        for type: UInt8 in [0x01, 0x02] {
            var record = [UInt8](repeating: 0, count: 0xf8)
            record[0x04] = 0xf8
            record[0x08] = type
            record[0x3a] = 0x10
            record.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: window, toByteOffset: 0x3c, as: UInt32.self)
                for offset in 0x20..<0x30 { raw[offset] = 0xff }
            }
            _ = record.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
        }
        return true
    }
}

private enum AXPrivate {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let getWindow = dlsym(defaultHandle, "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindowFn.self) }
    private static let createWithToken = dlsym(defaultHandle, "_AXUIElementCreateWithRemoteToken")
        .map { unsafeBitCast($0, to: CreateWithTokenFn.self) }

    static let isAvailable = getWindow != nil && createWithToken != nil

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success else { return nil }
        return id
    }

    /// 按编号直接构造某个 App 里的辅助功能元素（token = pid + 0 + "coco" + 元素编号）。
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let createWithToken else { return nil }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
        return createWithToken(token as CFData)?.takeRetainedValue()
    }
}
