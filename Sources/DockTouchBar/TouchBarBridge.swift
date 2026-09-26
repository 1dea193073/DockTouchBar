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
