import AppKit

/// 后台 App 常驻显示 Touch Bar 没有公开 API，这里用的是 DFRFoundation 和 NSTouchBar 的私有接口。
/// 所有符号都在运行时解析、不做链接：系统删掉任何一个时 `isAvailable` 为 false，App 只是不显示，不会崩溃。
enum TouchBarBridge {
    private typealias SetPresenceFn = @convention(c) (CFString, Bool) -> Void
    private typealias CloseBoxFn = @convention(c) (Bool) -> Void
    private typealias PresentFn = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString) -> Void

    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private static let setPresenceFn: SetPresenceFn? = dfr
        .flatMap { dlsym($0, "DFRElementSetControlStripPresenceForIdentifier") }
        .map { unsafeBitCast($0, to: SetPresenceFn.self) }

    private static let closeBoxFn: CloseBoxFn? = dfr
        .flatMap { dlsym($0, "DFRSystemModalShowsCloseBoxWhenFrontMost") }
        .map { unsafeBitCast($0, to: CloseBoxFn.self) }

    private static let presentSel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private static let presentFn: PresentFn? = class_getClassMethod(NSTouchBar.self, presentSel)
        .map { unsafeBitCast(method_getImplementation($0), to: PresentFn.self) }

    private static let dismissSel = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static let addTraySel = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTraySel = NSSelectorFromString("removeSystemTrayItem:")

    static let isAvailable: Bool = {
        let bar = NSTouchBar.self as AnyObject
        let item = NSTouchBarItem.self as AnyObject
        return setPresenceFn != nil && presentFn != nil
            && bar.responds(to: dismissSel)
            && item.responds(to: addTraySel) && item.responds(to: removeTraySel)
    }()

    /// 不显示左侧的系统 × 关闭按钮，Esc 键保持原样。
    static func hideCloseBox() {
        closeBoxFn?(false)
    }

    static func addTrayItem(_ item: NSTouchBarItem) {
        guard isAvailable else { return }
        NSTouchBarItem.perform(addTraySel, with: item)
        setPresenceFn?(item.identifier.rawValue as CFString, true)
    }

    static func removeTrayItem(_ item: NSTouchBarItem) {
        guard isAvailable else { return }
        setPresenceFn?(item.identifier.rawValue as CFString, false)
        NSTouchBarItem.perform(removeTraySel, with: item)
    }

    /// placement 1 = 占满整条。系统设置为“展开的控制条”时 placement 0 不会显示（macOS 27 实测），所以固定用 1。
    static func present(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) {
        guard isAvailable else { return }
        presentFn?(NSTouchBar.self, presentSel, bar, 1, trayIdentifier.rawValue as NSString)
    }

    static func dismiss(_ bar: NSTouchBar) {
        guard isAvailable else { return }
        NSTouchBar.perform(dismissSel, with: bar)
    }
}


/// 内置屏幕的亮度（0…1），用来判断屏幕是不是被调到了全黑。用系统私有的 DisplayServices，读不到就返回 nil。
enum ScreenBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let getFn: GetFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: GetFn.self)
    }()

    static var current: Float? {
        guard let getFn else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            var value: Float = 0
            if getFn(id, &value) == 0 { return value }
        }
        return nil
    }
}


/// 系统「键盘 → 触控栏显示」设置。选「显示 F1、F2 等键」时整条 Touch Bar 被功能键行占满，
/// Dock 出不来，而 App 本身一切正常，用户看不到任何提示。这里读取并（经用户同意后）修正该设置。
enum TouchBarSetup {
    private static let domain = "com.apple.touchbar.agent" as CFString
    private static let modeKey = "PresentationModeGlobal" as CFString
    /// Dock 能正常显示的模式。
    static let workingMode = "fullControlStrip"

    /// 当前系统设置的触控栏显示模式；读不到返回 nil（系统默认值）。
    static var presentationMode: String? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(modeKey, domain) as? String
    }

    /// 已确认会盖住 Dock 的模式。
    static var modeHidesDock: Bool { presentationMode == "functionKeys" }

    static var modeDescription: String {
        switch presentationMode {
        case "functionKeys": return L10n.tr("F1、F2 等键", "F1, F2, etc. keys")
        case "fullControlStrip": return L10n.tr("展开的控制条", "Expanded Control Strip")
        case "appWithControlStrip", nil: return L10n.tr("App 控制 + 控制条（默认）", "App Controls with Control Strip (default)")
        case "app": return L10n.tr("仅 App 控制", "App Controls")
        case let other?: return other
        }
    }

    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// 带 Touch Bar 的机型（2016–2020 款 13/15/16 英寸 MacBook Pro）。
    static var hasTouchBarHardware: Bool {
        let touchBarModels: Set<String> = [
            "MacBookPro13,2", "MacBookPro13,3", "MacBookPro14,2", "MacBookPro14,3",
            "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
            "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
        ]
        return touchBarModels.contains(hardwareModel)
    }

    /// 等同于在系统设置里把「触控栏显示」改成「展开的控制条」，再重启触控栏相关进程。
    @discardableResult
    static func applyWorkingMode() -> Bool {
        guard run("/usr/bin/defaults", ["write", "com.apple.touchbar.agent", "PresentationModeGlobal",
                                         "-string", workingMode]) else { return false }
        _ = run("/usr/bin/killall", ["ControlStrip"])
        _ = run("/usr/bin/killall", ["Touch Bar agent"])
        return true
    }

    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
