import AppKit
import ServiceManagement

/// 菜单栏设置：显示、手势、系统 Touch Bar 避让、语言、登录启动、权限和关于。
/// 菜单文字全部在 `menuNeedsUpdate` 里按当前语言重新设置，所以切换语言后不用重启。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Key {
        static let enabled = "enabled"
        static let showPinned = "showPinned"
        // 保留原来的存储键，继承已有用户是否启用双击的选择。
        static let doubleTapMinimize = "doubleTapHide"
        static let yieldCapture = "yieldSystemCapture"
        static let yieldFunctionRow = "yieldFunctionRow"
        static let longPressSeconds = "longPressSeconds"
        static let hideSeconds = "hideSeconds"
        static let showCenterButton = "showCenterButton"
        static let centerHeight = "centerHeightPercent"
        static let centerWidth = "centerWidthPercent"
        static let iconSpacing = "iconSpacing"
    }

    /// 长按退出 App 的可选时长（秒），0 = 不启用。
    private static let longPressOptions = [0, 1, 2, 3, 5]
    /// 点“咖啡杯”后临时隐藏 Dock 的可选时长（秒）。
    private static let hideOptions = [10, 20, 30, 60]
    /// 居中后窗口的高度（占屏幕可用高度的百分比）。
    private static let heightOptions = [60, 70, 80, 90, 100]
    /// 居中后窗口的宽度：0 = 和高度一样（正方形），其余是占屏幕可用宽度的百分比。
    private static let widthOptions = [0, 50, 60, 70, 80, 90, 100]
    /// 图标之间的间距（pt）可选挡位。
    private static let spacingOptions = [0, 2, 4, 6, 8]

    private let dock = DockBarController()
    private let about = AboutWindowController()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?

    private lazy var setupWarningItem = makeItem(#selector(fixTouchBarSetup))
    private lazy var diagnoseItem = makeItem(#selector(showDiagnostics))
    /// 显示后自检没通过：Dock 应该在显示却没有出现。
    private var dockFailedToShow = false
    private lazy var enabledItem = makeItem(#selector(toggleEnabled))
    private lazy var hideDurationItem = makeSubmenuItem(
        options: Self.hideOptions.map { ($0, #selector(setHideDuration(_:))) })
    private lazy var centerButtonItem = makeItem(#selector(toggleCenterButton))
    private lazy var centerHeightItem = makeSubmenuItem(
        options: Self.heightOptions.map { ($0, #selector(setCenterHeight(_:))) })
    private lazy var centerWidthItem = makeSubmenuItem(
        options: Self.widthOptions.map { ($0, #selector(setCenterWidth(_:))) })
    private lazy var pinnedItem = makeItem(#selector(togglePinned))
    private lazy var spacingItem = makeSubmenuItem(
        options: Self.spacingOptions.map { ($0, #selector(setIconSpacing(_:))) })
    private lazy var doubleTapItem = makeItem(#selector(toggleDoubleTap))
    private lazy var avoidanceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var captureAvoidanceItem = makeItem(#selector(toggleCaptureAvoidance))
    private lazy var fnAvoidanceItem = makeItem(#selector(toggleFunctionRowAvoidance))
    private lazy var avoidanceExplanation = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var longPressItem = makeSubmenuItem(
        options: Self.longPressOptions.map { ($0, #selector(setLongPress(_:))) })
    private lazy var hintThemeItem = makeSubmenuItem(
        options: QuitHintTheme.allCases.indices.map { ($0, #selector(setHintTheme(_:))) })
    private lazy var languageItem = makeSubmenuItem(
        options: AppLanguage.allCases.indices.map { ($0, #selector(setLanguage(_:))) })
    private lazy var loginItem = makeItem(#selector(toggleLaunchAtLogin))
    /// “权限”子菜单：列出软件需要的权限、现在的状态，点一下去系统设置里开启。目前只有辅助功能一项。
    private lazy var permissionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var accessibilityRow = makeItem(#selector(requestAccessibility))
    private lazy var accessibilityUses: [NSMenuItem] = (0..<5).map { _ in
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    private lazy var permissionsFootnote: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()
    private lazy var checkUpdatesItem = makeItem(#selector(checkForUpdates))
    private lazy var aboutItem = makeItem(#selector(showAbout))
    private lazy var quitItem = makeItem(#selector(NSApplication.terminate(_:)), target: NSApp, keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 两个实例会互相抢 Touch Bar，只留先启动的那个。
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: [Key.enabled: true, Key.showPinned: true,
                                     Key.doubleTapMinimize: true, Key.longPressSeconds: 3,
                                     Key.yieldCapture: true, Key.yieldFunctionRow: true,
                                     Key.hideSeconds: 20, Key.showCenterButton: true,
                                     Key.centerHeight: 80, Key.centerWidth: 0,
                                     Key.iconSpacing: 4])

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        // 分组：显示 → 切换与手势 → 通用 → 关于/退出
        setupWarningItem.isHidden = true
        menu.addItem(setupWarningItem)
        menu.addItem(enabledItem)
        menu.addItem(hideDurationItem)
        menu.addItem(pinnedItem)
        menu.addItem(spacingItem)
        menu.addItem(.separator())
        menu.addItem(centerButtonItem)
        menu.addItem(centerHeightItem)
        menu.addItem(centerWidthItem)
        menu.addItem(.separator())
        let permissionsMenu = NSMenu()
        permissionsMenu.autoenablesItems = false
        permissionsMenu.addItem(accessibilityRow)
        permissionsMenu.addItem(.separator())
        accessibilityUses.forEach { permissionsMenu.addItem($0) }
        permissionsMenu.addItem(.separator())
        permissionsMenu.addItem(permissionsFootnote)
        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)
        menu.addItem(doubleTapItem)
        menu.addItem(longPressItem)
        menu.addItem(hintThemeItem)
        menu.addItem(.separator())
        let avoidanceMenu = NSMenu()
        avoidanceMenu.autoenablesItems = false
        avoidanceMenu.addItem(captureAvoidanceItem)
        avoidanceMenu.addItem(fnAvoidanceItem)
        avoidanceMenu.addItem(.separator())
        avoidanceExplanation.isEnabled = false
        avoidanceMenu.addItem(avoidanceExplanation)
        avoidanceItem.submenu = avoidanceMenu
        menu.addItem(avoidanceItem)
        menu.addItem(languageItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(diagnoseItem)
        menu.addItem(checkUpdatesItem)
        menu.addItem(aboutItem)
        menu.addItem(quitItem)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Touch Bar Dock")
        item.menu = menu
        statusItem = item

        dock.showsPinnedApps = defaults.bool(forKey: Key.showPinned)
        dock.doubleTapMinimizes = defaults.bool(forKey: Key.doubleTapMinimize)
        dock.yieldsToSystemCapture = defaults.bool(forKey: Key.yieldCapture)
        dock.yieldsToFunctionRow = defaults.bool(forKey: Key.yieldFunctionRow)
        dock.longPressDuration = TimeInterval(defaults.integer(forKey: Key.longPressSeconds))
        dock.quitHintTheme = QuitHintTheme.saved
        dock.showsCenterButton = defaults.bool(forKey: Key.showCenterButton)
        dock.centerHeightPercent = defaults.integer(forKey: Key.centerHeight)
        dock.centerWidthPercent = defaults.integer(forKey: Key.centerWidth)
        dock.pauseDuration = TimeInterval(defaults.integer(forKey: Key.hideSeconds))
        dock.iconSpacing = CGFloat(defaults.integer(forKey: Key.iconSpacing))
        applyEnabled()
        scheduleDisplayCheck()
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
        refreshSetupWarning()
        diagnoseItem.title = L10n.tr("诊断：为什么看不到 Dock？…", "Diagnose: why can't I see the Dock?…")
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

        let spacing = defaults.integer(forKey: Key.iconSpacing)
        spacingItem.title = L10n.tr("图标间距：\(spacing)pt", "Icon spacing: \(spacing)pt")
        for option in spacingItem.submenu?.items ?? [] {
            option.title = L10n.tr("\(option.tag)pt", "\(option.tag)pt")
            option.state = option.tag == spacing ? .on : .off
        }

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

        doubleTapItem.title = L10n.tr("双击图标：最小化当前窗口", "Double-tap an icon: minimize the window")
        doubleTapItem.state = defaults.bool(forKey: Key.doubleTapMinimize) ? .on : .off
        doubleTapItem.toolTip = L10n.tr("等同窗口左上角黄色按钮，需要辅助功能权限", "Same as the yellow window button; needs Accessibility permission")
        avoidanceItem.title = L10n.tr("系统 Touch Bar 避让", "Yield to system Touch Bar controls")
        captureAvoidanceItem.title = L10n.tr("截图 / 录屏时自动避让", "Yield during screenshots / recording")
        captureAvoidanceItem.state = defaults.bool(forKey: Key.yieldCapture) ? .on : .off
        fnAvoidanceItem.title = L10n.tr("按住 Fn 时自动避让", "Yield while Fn is held")
        fnAvoidanceItem.state = defaults.bool(forKey: Key.yieldFunctionRow) ? .on : .off
        avoidanceExplanation.title = L10n.tr("开启时 Dock 临时隐藏，结束后自动恢复", "When on, the Dock hides temporarily and returns afterward")

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

        // 权限：始终显示状态。有权限时打勾，点一下打开系统设置（方便查看或关闭）；没权限时点一下去开启。
        let hasAccess = AppSwitcher.hasAccessibilityAccess
        permissionsItem.title = hasAccess
            ? L10n.tr("权限：辅助功能已开启", "Permissions: Accessibility is on")
            : L10n.tr("⚠︎ 权限：辅助功能未开启", "⚠︎ Permissions: Accessibility is off")
        accessibilityRow.title = hasAccess
            ? L10n.tr("辅助功能：已开启（点一下打开系统设置）", "Accessibility: on (click to open System Settings)")
            : L10n.tr("辅助功能：未开启，点一下去开启…", "Accessibility: off — click to turn it on…")
        accessibilityRow.state = hasAccess ? .on : .off
        let uses = [
            L10n.tr("用来：跨桌面切换到 App 的窗口", "Used to: jump to an app's window on another desktop"),
            L10n.tr("用来：窗口居中、最大化", "Used to: center and maximize a window"),
            L10n.tr("用来：长按只关当前窗口、发现确认框", "Used to: close just the current window on long-press, and spot a confirmation dialog"),
            L10n.tr("用来：双击最小化窗口、监听 Fn 避让", "Used to: minimize windows on double-tap and detect Fn for yielding"),
            L10n.tr("没有它：其他功能照常，只是这几项不可用", "Without it: everything else works, only these are unavailable"),
        ]
        for (item, text) in zip(accessibilityUses, uses) { item.title = text }
        permissionsFootnote.title = L10n.tr("除此之外，不需要其他任何权限", "No other permission is needed")

        checkUpdatesItem.title = L10n.tr("检查更新…", "Check for Updates…")
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

    @objc private func setIconSpacing(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.iconSpacing)
        dock.iconSpacing = CGFloat(sender.tag)
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
        let on = !defaults.bool(forKey: Key.doubleTapMinimize)
        defaults.set(on, forKey: Key.doubleTapMinimize)
        dock.doubleTapMinimizes = on
    }

    @objc private func toggleCaptureAvoidance() {
        let on = !defaults.bool(forKey: Key.yieldCapture)
        defaults.set(on, forKey: Key.yieldCapture)
        dock.yieldsToSystemCapture = on
    }

    @objc private func toggleFunctionRowAvoidance() {
        let on = !defaults.bool(forKey: Key.yieldFunctionRow)
        defaults.set(on, forKey: Key.yieldFunctionRow)
        dock.yieldsToFunctionRow = on
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

    /// 去开启辅助功能：弹出系统的授权提示，并打开系统设置里的辅助功能页。
    @objc private func requestAccessibility() {
        AppSwitcher.requestAccessibilityAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        about.show(checkUpdates: true)
    }

    @objc private func showAbout() {
        about.show()
    }

    // MARK: - Touch Bar 显示自检与修复

    /// 启动后（以及系统设置被改动后）检查：显示模式是否会盖住 Dock，Dock 是否真的出现了。
    private func scheduleDisplayCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.runDisplayCheck()
            if TouchBarSetup.modeHidesDock, !self.defaults.bool(forKey: "setupPromptShown") {
                self.defaults.set(true, forKey: "setupPromptShown")
                self.fixTouchBarSetup()
            }
        }
    }

    private func runDisplayCheck() {
        let wanted = defaults.bool(forKey: Key.enabled) && TouchBarBridge.isAvailable
        dockFailedToShow = wanted && dock.isExpectedToShow && !dock.isDisplayed
        refreshSetupWarning()
    }

    private func refreshSetupWarning() {
        let modeProblem = TouchBarSetup.modeHidesDock && defaults.bool(forKey: Key.enabled)
        setupWarningItem.isHidden = !modeProblem
        setupWarningItem.title = L10n.tr("⚠︎ Touch Bar 正显示 F1–F12，Dock 无法出现 — 点此修复…",
                                         "⚠︎ Touch Bar is showing F1–F12, so the Dock can't appear — click to fix…")
        let warn = modeProblem || dockFailedToShow
        let name = warn ? "exclamationmark.triangle" : "dock.rectangle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Touch Bar Dock")
    }

    @objc private func fixTouchBarSetup() {
        guard TouchBarSetup.modeHidesDock else { showDiagnostics(); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.tr("Touch Bar 被系统设为「显示 F1、F2 等键」",
                                    "Your Touch Bar is set to show F1, F2, etc. keys")
        alert.informativeText = L10n.tr(
            "这个设置会让整条 Touch Bar 被功能键占满，Dock 无法显示。\n\n可以改成「展开的控制条」（等同于 系统设置 → 键盘 → 触控栏显示）。改完后 F1–F12 不再默认显示，按住 Fn 键即可看到。之后想还原，在同一处改回即可（Dock 会随之失效）。",
            "That setting fills the whole Touch Bar with function keys, so the Dock can't appear.\n\nYou can switch it to “Expanded Control Strip” (same as System Settings → Keyboard → Touch Bar Shows). F1–F12 will no longer be shown by default; hold Fn to see them. To undo, change it back in the same place (the Dock will stop showing again).")
        alert.addButton(withTitle: L10n.tr("改为展开的控制条（推荐）", "Switch to Expanded Control Strip (recommended)"))
        alert.addButton(withTitle: L10n.tr("保持现状", "Keep as is"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if TouchBarSetup.applyWorkingMode() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.dock.stop()
                self.applyEnabled()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runDisplayCheck() }
            }
        } else {
            showAlert(L10n.tr("修改失败", "Couldn't change the setting"),
                      L10n.tr("请手动打开 系统设置 → 键盘，把「触控栏显示」改为「展开的控制条」。",
                              "Open System Settings → Keyboard and set “Touch Bar Shows” to “Expanded Control Strip”."))
        }
    }

    private func diagnosticReport() -> (text: String, problems: Int) {
        var lines: [String] = []
        var problems = 0
        func row(_ ok: Bool, _ okText: String, _ badText: String) {
            lines.append((ok ? "✓ " : "✗ ") + (ok ? okText : badText))
            if !ok { problems += 1 }
        }
        row(TouchBarSetup.hasTouchBarHardware,
            L10n.tr("这台 Mac 带 Touch Bar（\(TouchBarSetup.hardwareModel)）", "This Mac has a Touch Bar (\(TouchBarSetup.hardwareModel))"),
            L10n.tr("这台 Mac（\(TouchBarSetup.hardwareModel)）没有 Touch Bar，Dock 无处显示", "This Mac (\(TouchBarSetup.hardwareModel)) has no Touch Bar, so the Dock has nowhere to show"))
        row(TouchBarBridge.isAvailable,
            L10n.tr("系统 Touch Bar 接口可用", "System Touch Bar API available"),
            L10n.tr("找不到系统 Touch Bar 接口（当前系统版本可能不支持）", "System Touch Bar API not found (this macOS version may be unsupported)"))
        row(!TouchBarSetup.modeHidesDock,
            L10n.tr("触控栏显示模式：\(TouchBarSetup.modeDescription)", "Touch Bar Shows: \(TouchBarSetup.modeDescription)"),
            L10n.tr("触控栏显示模式是「\(TouchBarSetup.modeDescription)」，会盖住 Dock → 菜单里点「修复」", "Touch Bar Shows is “\(TouchBarSetup.modeDescription)”, which covers the Dock → use Fix in the menu"))
        row(defaults.bool(forKey: Key.enabled),
            L10n.tr("「在 Touch Bar 上显示 Dock」已开启", "“Show Dock on Touch Bar” is on"),
            L10n.tr("「在 Touch Bar 上显示 Dock」被关闭了 → 在菜单里勾选", "“Show Dock on Touch Bar” is off → turn it on in the menu"))
        row(AppSwitcher.hasAccessibilityAccess,
            L10n.tr("辅助功能权限已开启", "Accessibility permission is on"),
            L10n.tr("辅助功能权限未开启（不影响显示，只影响窗口切换、居中、双击最小化等）", "Accessibility permission is off (doesn't affect display; affects window switching, centering, double-tap minimize)"))
        if dock.isExpectedToShow {
            row(dock.isDisplayed,
                L10n.tr("Dock 正显示在 Touch Bar 上", "The Dock is showing on the Touch Bar"),
                L10n.tr("Dock 应该显示却没有出现 → 先试「关闭再开启显示」，仍不行请把下面的信息反馈给开发者", "The Dock should be showing but isn't → toggle “Show Dock” off and on; if it persists, send this report to the developer"))
        } else {
            lines.append(L10n.tr("· Dock 当前处于临时让位状态（截图 / Fn / 咖啡杯）或已关闭", "· The Dock is currently yielding (screenshot / Fn / coffee cup) or turned off"))
        }
        lines.append("")
        lines.append("DockTouchBar \(AppInfo.version) (\(AppInfo.build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(TouchBarSetup.hardwareModel)")
        return (lines.joined(separator: "\n"), problems)
    }

    @objc private func showDiagnostics() {
        runDisplayCheck()
        let report = diagnosticReport()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = report.problems == 0
            ? L10n.tr("一切正常", "Everything looks fine")
            : L10n.tr("发现 \(report.problems) 个问题", "Found \(report.problems) issue(s)")
        alert.informativeText = report.text
        if TouchBarSetup.modeHidesDock { alert.addButton(withTitle: L10n.tr("修复显示模式…", "Fix display mode…")) }
        alert.addButton(withTitle: L10n.tr("复制诊断信息", "Copy report"))
        alert.addButton(withTitle: L10n.tr("关闭", "Close"))
        let response = alert.runModal()
        let offset = TouchBarSetup.modeHidesDock ? 1 : 0
        if offset == 1, response == .alertFirstButtonReturn {
            fixTouchBarSetup()
        } else if response == NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + offset) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.text, forType: .string)
        }
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
