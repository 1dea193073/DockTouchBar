import AppKit
import ServiceManagement

/// 菜单栏图标 + 设置：开/关、咖啡杯临时隐藏时长、窗口居中按钮及窗口大小、只显示正在运行的 App、跨桌面、双击隐藏、长按退出的时长和提示风格、语言、登录时启动、关于。
/// 菜单文字全部在 `menuNeedsUpdate` 里按当前语言重新设置，所以切换语言后不用重启。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let enabled = "enabled"
        static let showPinned = "showPinned"
        static let doubleTapHide = "doubleTapHide"
        static let longPressSeconds = "longPressSeconds"
        static let hideSeconds = "hideSeconds"
        static let showCenterButton = "showCenterButton"
        static let centerHeight = "centerHeightPercent"
        static let centerWidth = "centerWidthPercent"
    }

    /// 长按退出 App 的可选时长（秒），0 = 不启用。
    private static let longPressOptions = [0, 1, 2, 3, 5]
    /// 点“咖啡杯”后临时隐藏 Dock 的可选时长（秒）。
    private static let hideOptions = [10, 20, 30, 60]
    /// 居中后窗口的高度（占屏幕可用高度的百分比）。
    private static let heightOptions = [60, 70, 80, 90, 100]
    /// 居中后窗口的宽度：0 = 和高度一样（正方形），其余是占屏幕可用宽度的百分比。
    private static let widthOptions = [0, 50, 60, 70, 80, 90, 100]

    private let dock = DockBarController()
    private let about = AboutWindowController()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?

    private lazy var enabledItem = makeItem(#selector(toggleEnabled))
    private lazy var hideDurationItem = makeSubmenuItem(
        options: Self.hideOptions.map { ($0, #selector(setHideDuration(_:))) })
    private lazy var centerButtonItem = makeItem(#selector(toggleCenterButton))
    private lazy var centerHeightItem = makeSubmenuItem(
        options: Self.heightOptions.map { ($0, #selector(setCenterHeight(_:))) })
    private lazy var centerWidthItem = makeSubmenuItem(
        options: Self.widthOptions.map { ($0, #selector(setCenterWidth(_:))) })
    private lazy var pinnedItem = makeItem(#selector(togglePinned))
    private lazy var doubleTapItem = makeItem(#selector(toggleDoubleTap))
    private lazy var longPressItem = makeSubmenuItem(
        options: Self.longPressOptions.map { ($0, #selector(setLongPress(_:))) })
    private lazy var hintThemeItem = makeSubmenuItem(
        options: QuitHintTheme.allCases.indices.map { ($0, #selector(setHintTheme(_:))) })
    private lazy var languageItem = makeSubmenuItem(
        options: AppLanguage.allCases.indices.map { ($0, #selector(setLanguage(_:))) })
    private lazy var loginItem = makeItem(#selector(toggleLaunchAtLogin))
    private lazy var accessibilityItem = makeItem(#selector(requestAccessibility))
    private lazy var aboutItem = makeItem(#selector(showAbout))
    private lazy var quitItem = makeItem(#selector(NSApplication.terminate(_:)), target: NSApp, keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 两个实例会互相抢 Touch Bar，只留先启动的那个。
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: [Key.enabled: true, Key.showPinned: true,
                                     Key.doubleTapHide: true, Key.longPressSeconds: 3,
                                     Key.hideSeconds: 20, Key.showCenterButton: true,
                                     Key.centerHeight: 80, Key.centerWidth: 0])

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        // 分组：显示 → 切换与手势 → 通用 → 关于/退出
        menu.addItem(enabledItem)
        menu.addItem(hideDurationItem)
        menu.addItem(pinnedItem)
        menu.addItem(.separator())
        menu.addItem(centerButtonItem)
        menu.addItem(centerHeightItem)
        menu.addItem(centerWidthItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(doubleTapItem)
        menu.addItem(longPressItem)
        menu.addItem(hintThemeItem)
        menu.addItem(.separator())
        menu.addItem(languageItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(aboutItem)
        menu.addItem(quitItem)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Touch Bar Dock")
        item.menu = menu
        statusItem = item

        dock.showsPinnedApps = defaults.bool(forKey: Key.showPinned)
        dock.doubleTapHides = defaults.bool(forKey: Key.doubleTapHide)
        dock.longPressDuration = TimeInterval(defaults.integer(forKey: Key.longPressSeconds))
        dock.quitHintTheme = QuitHintTheme.saved
        dock.showsCenterButton = defaults.bool(forKey: Key.showCenterButton)
        dock.centerHeightPercent = defaults.integer(forKey: Key.centerHeight)
        dock.centerWidthPercent = defaults.integer(forKey: Key.centerWidth)
        dock.pauseDuration = TimeInterval(defaults.integer(forKey: Key.hideSeconds))
        applyEnabled()
    }

    /// App 已经在运行时，再从「应用程序」或启动台打开它：弹出菜单栏菜单，方便开关和设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.button?.performClick(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        dock.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let available = TouchBarBridge.isAvailable
        enabledItem.isEnabled = available
        enabledItem.title = available
            ? L10n.tr("在 Touch Bar 上显示 Dock", "Show Dock on Touch Bar")
            : L10n.tr("当前系统不支持（找不到 Touch Bar 接口）", "Not supported on this system (Touch Bar API not found)")
        enabledItem.state = available && defaults.bool(forKey: Key.enabled) ? .on : .off

        let hideSeconds = defaults.integer(forKey: Key.hideSeconds)
        hideDurationItem.title = L10n.tr("点咖啡杯后临时隐藏：\(hideSeconds) 秒", "Hide for a moment after tapping the coffee cup: \(hideSeconds) s")
        for option in hideDurationItem.submenu?.items ?? [] {
            option.title = L10n.tr("\(option.tag) 秒", "\(option.tag) s")
            option.state = option.tag == hideSeconds ? .on : .off
        }

        // 界面上是“只显示正在运行的 App”，存的仍是原来的 showPinned（取反），已有用户的设置不受影响。
        pinnedItem.title = L10n.tr("只显示正在运行的 App", "Only show running apps")
        pinnedItem.state = defaults.bool(forKey: Key.showPinned) ? .off : .on

        centerButtonItem.title = L10n.tr("显示“窗口居中 / 最大化”按钮", "Show the center / maximize button")
        centerButtonItem.state = defaults.bool(forKey: Key.showCenterButton) ? .on : .off

        let height = defaults.integer(forKey: Key.centerHeight)
        centerHeightItem.title = L10n.tr("居中窗口的高度：\(height)%", "Centered window height: \(height)%")
        for option in centerHeightItem.submenu?.items ?? [] {
            option.title = L10n.tr("屏幕高度的 \(option.tag)%", "\(option.tag)% of screen height")
            option.state = option.tag == height ? .on : .off
        }

        let width = defaults.integer(forKey: Key.centerWidth)
        centerWidthItem.title = L10n.tr("居中窗口的宽度：", "Centered window width: ")
            + (width == 0 ? L10n.tr("与高度相同", "same as height") : "\(width)%")
        for option in centerWidthItem.submenu?.items ?? [] {
            option.title = option.tag == 0
                ? L10n.tr("与高度相同（正方形）", "Same as height (square)")
                : L10n.tr("屏幕宽度的 \(option.tag)%", "\(option.tag)% of screen width")
            option.state = option.tag == width ? .on : .off
        }

        doubleTapItem.title = L10n.tr("双击图标：隐藏 App", "Double-tap an icon: hide the app")
        doubleTapItem.state = defaults.bool(forKey: Key.doubleTapHide) ? .on : .off

        let seconds = defaults.integer(forKey: Key.longPressSeconds)
        longPressItem.title = L10n.tr("长按图标：退出 App（", "Long-press an icon: quit the app (")
            + (seconds == 0 ? L10n.tr("不启用", "Off") : L10n.tr("\(seconds) 秒", "\(seconds) s")) + L10n.tr("）", ")")
        for option in longPressItem.submenu?.items ?? [] {
            option.title = option.tag == 0 ? L10n.tr("不启用", "Off") : L10n.tr("按住 \(option.tag) 秒", "Hold \(option.tag) s")
            option.state = option.tag == seconds ? .on : .off
        }

        let theme = QuitHintTheme.saved
        hintThemeItem.title = L10n.tr("长按提示风格：", "Long-press style: ") + theme.title
        for option in hintThemeItem.submenu?.items ?? [] {
            let candidate = QuitHintTheme.allCases[option.tag]
            option.title = candidate.title
            option.state = candidate == theme ? .on : .off
        }

        languageItem.title = L10n.tr("语言", "Language")
        for option in languageItem.submenu?.items ?? [] {
            let language = AppLanguage.allCases[option.tag]
            option.title = Self.title(of: language)
            option.state = language == L10n.preference ? .on : .off
        }

        loginItem.title = L10n.tr("登录时自动启动", "Launch at login")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // 始终显示：有权限时打勾，点一下打开系统设置方便查看或关闭；没权限时点一下去授权。
        let hasAccess = AppSwitcher.hasAccessibilityAccess
        accessibilityItem.title = hasAccess
            ? L10n.tr("跨桌面启动应用", "Launch apps across desktops")
            : L10n.tr("允许跨桌面启动应用…", "Allow launching apps across desktops…")
        accessibilityItem.state = hasAccess ? .on : .off

        aboutItem.title = L10n.tr("关于 \(AppInfo.name)…", "About \(AppInfo.name)…")
        quitItem.title = L10n.tr("退出", "Quit \(AppInfo.name)")
    }

    private static func title(of language: AppLanguage) -> String {
        switch language {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        defaults.set(!defaults.bool(forKey: Key.enabled), forKey: Key.enabled)
        applyEnabled()
    }

    @objc private func togglePinned() {
        let show = !defaults.bool(forKey: Key.showPinned)
        defaults.set(show, forKey: Key.showPinned)
        dock.showsPinnedApps = show
    }

    @objc private func setHideDuration(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.hideSeconds)
        dock.pauseDuration = TimeInterval(sender.tag)
    }

    @objc private func toggleCenterButton() {
        let show = !defaults.bool(forKey: Key.showCenterButton)
        defaults.set(show, forKey: Key.showCenterButton)
        dock.showsCenterButton = show
        if show, !AppSwitcher.hasAccessibilityAccess { AppSwitcher.requestAccessibilityAccess() }
    }

    @objc private func setCenterHeight(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.centerHeight)
        dock.centerHeightPercent = sender.tag
    }

    @objc private func setCenterWidth(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.centerWidth)
        dock.centerWidthPercent = sender.tag
    }

    @objc private func toggleDoubleTap() {
        let on = !defaults.bool(forKey: Key.doubleTapHide)
        defaults.set(on, forKey: Key.doubleTapHide)
        dock.doubleTapHides = on
    }

    @objc private func setLongPress(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.longPressSeconds)
        dock.longPressDuration = TimeInterval(sender.tag)
    }

    /// 换风格后立刻在 Touch Bar 上演示一遍，不用真的去长按一个 App。
    @objc private func setHintTheme(_ sender: NSMenuItem) {
        let theme = QuitHintTheme.allCases[sender.tag]
        UserDefaults.standard.set(theme.rawValue, forKey: QuitHintTheme.defaultsKey)
        dock.quitHintTheme = theme
        dock.previewQuitHint()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        L10n.preference = AppLanguage.allCases[sender.tag]
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert(L10n.tr("无法修改登录项", "Couldn't change the login item"),
                      "\(error.localizedDescription)\n\n"
                      + L10n.tr("先把 App 放进「应用程序」文件夹再试。", "Move the app to the Applications folder and try again."))
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// App 的窗口都在别的桌面时，要用辅助功能把窗口提到前面，系统才会切过去。
    @objc private func requestAccessibility() {
        AppSwitcher.requestAccessibilityAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        about.show()
    }

    // MARK: - Helpers

    private func applyEnabled() {
        let on = defaults.bool(forKey: Key.enabled) && TouchBarBridge.isAvailable
        if on { dock.start() } else { dock.stop() }
        statusItem?.button?.appearsDisabled = !on
    }

    /// 菜单项的标题在 `menuNeedsUpdate` 里按语言设置，这里只创建。
    private func makeItem(_ action: Selector, target: AnyObject? = nil, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: keyEquivalent)
        item.target = target ?? self
        return item
    }

    /// 带子菜单的项；`options` 里每个元素是（tag，点击后调用的方法）。
    private func makeSubmenuItem(options: [(Int, Selector)]) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (tag, action) in options {
            let option = makeItem(action)
            option.tag = tag
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != ownPID }
    }

    private func showAlert(_ title: String, _ message: String) {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
