import AppKit

/// Touch Bar 上的那条 Dock：显示、刷新、点击/双击/长按，以及被系统收回后自动挂回去。
final class DockBarController: NSObject {
    private enum Metrics {
        static let tileWidth: CGFloat = 36
        static let dividerWidth: CGFloat = 13
        static let iconSize: CGFloat = 24
        /// Touch Bar 占满整条时可用宽度约 1004pt。
        static let maxDockWidth: CGFloat = 1000
        /// 最右侧固定的按钮（“咖啡杯”和“窗口居中”）的宽度，Dock 图标区不会画到它们下面。
        static let buttonWidth: CGFloat = 44
        /// 点咖啡杯时屏幕亮度低于这个值算“被调黑了”，回到 `brightnessRecovered` 以上才自动恢复。
        static let brightnessDark: Float = 0.08
        static let brightnessRecovered: Float = 0.15
        static let doubleTapInterval: TimeInterval = 0.35
        /// 按住多久开始显示“长按退出”的进度条；比这更短的按压都当作点击。
        static let pressArmDelay: TimeInterval = 0.35
        /// 按住后手指移动超过这个距离，当作在滑动，取消长按。
        static let pressMovementTolerance: CGFloat = 10
    }

    private static let controlStripBundleID = "com.apple.controlstrip"

    private let trayID = NSTouchBarItem.Identifier("com.maohuhu.docktouchbar.tray")
    private let dockID = NSTouchBarItem.Identifier("com.maohuhu.docktouchbar.dock")
    private let tileViewID = NSUserInterfaceItemIdentifier("tile")

    private let scrubber: NSScrubber
    private let scrubberWidth: NSLayoutConstraint
    private let pressRecognizer = NSPressGestureRecognizer()
    /// 装着 Dock 和右侧“正在关闭”提示的容器；宽度固定为整条 Touch Bar，Dock 靠左，提示靠右边缘。
    private let container = NSView()
    private let quitHint = QuitHintView()
    /// 右侧的两个像素画按钮：咖啡杯（歇一会儿，把 Touch Bar 还给系统）在左，窗口居中在最右边。
    private let coffeeButton = PixelButton(frames: PixelIcon.coffee, cells: (13, 11), frameDuration: 0.4)
    private let centerButton = PixelButton(frames: PixelIcon.center.map { [$0] } ?? [], cells: (13, 9))
    private let quitHintLeading: NSLayoutConstraint
    /// 咖啡杯贴着居中按钮，或者（居中按钮隐藏时）贴着最右边。
    private let coffeeToCenter: NSLayoutConstraint
    private let coffeeToEdge: NSLayoutConstraint
    /// 图标区内容的宽度（不含右侧按钮），按钮显示/隐藏时据此重算图标区可用宽度。
    private var contentWidth: CGFloat = 0
    /// 临时暂停：用户点了右侧的咖啡杯按钮，让出 Touch Bar 给系统控制条（亮度、音量……）。
    private var isPaused = false
    /// 点“咖啡杯”后暂时隐藏多久（秒）；如果屏幕已经被调黑，则不看时间，等亮度回来。
    var pauseDuration: TimeInterval = 20
    private var pauseTimer: Timer?

    private lazy var touchBar: NSTouchBar = {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [dockID]
        return bar
    }()

    /// 系统控制条里的入口按钮（Touch Bar 设为“App 控制”时可见，点一下重新显示 Dock）。
    private lazy var trayItem: NSCustomTouchBarItem = {
        let item = NSCustomTouchBarItem(identifier: trayID)
        let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: nil) ?? NSImage()
        item.view = NSButton(image: image, target: self, action: #selector(trayTapped))
        return item
    }()

    private var tiles: [DockTile] = []
    private var isActive = false
    private var reloadScheduled = false
    private var recoverScheduled = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var controlStripPID: pid_t?

    /// 正在进行的一次按压（从按住 `pressArmDelay` 秒开始，到松手结束）。
    private struct Press {
        let index: Int
        let tile: DockTile
        let start: NSPoint
        var quitWork: DispatchWorkItem?
        var moved = false
        var completed = false
        var sawSelection = false
    }
    private var press: Press?
    private var suppressSelectionUntil = Date.distantPast
    /// 长按已经退出了 App、手指还没抬起。退出的如果是没固定的 App，它的图标会消失、列表重排，
    /// 按压记录随之作废；这个标记保证松手时不会误点到挪过来的相邻图标。
    private var swallowTapsUntilRelease = false
    private var lastTap: (tile: DockTile, time: Date)?

    var showsPinnedApps = true {
        didSet { if isActive { reload() } }
    }

    /// 长按多少秒退出 App；0 表示不启用。
    var longPressDuration: TimeInterval = 3 {
        didSet { pressRecognizer.isEnabled = longPressDuration > 0 }
    }

    var doubleTapHides = true

    /// 长按退出提示的风格。
    var quitHintTheme = QuitHintTheme.spring {
        didSet { quitHint.theme = quitHintTheme }
    }
    private var quitHintPreview: DispatchWorkItem?

    /// “窗口居中 / 最大化”按钮：显示与否，以及居中后窗口的大小（0 = 宽度和高度一样，即正方形）。
    var showsCenterButton = true {
        didSet {
            centerButton.isHidden = !showsCenterButton
            updateWindowWatching()
            // 居中按钮不显示时，咖啡杯挪到最右边。
            if showsCenterButton {
                coffeeToEdge.isActive = false
                coffeeToCenter.isActive = true
            } else {
                coffeeToCenter.isActive = false
                coffeeToEdge.isActive = true
            }
            updateDockWidth()
        }
    }
    var centerHeightPercent = 80 {
        didSet { if oldValue != centerHeightPercent { refreshCenterIcon() } }
    }
    var centerWidthPercent = 0 {
        didSet { if oldValue != centerWidthPercent { refreshCenterIcon() } }
    }
    /// 按钮现在的图标，也就是再点一下会做什么：居中，或者（窗口已经是居中的样子时）最大化。
    private var windowAction = WindowPlacer.Action.center
    private let windowWatcher = WindowWatcher()

    override init() {
        let scrubber = NSScrubber()
        self.scrubber = scrubber
        self.scrubberWidth = scrubber.widthAnchor.constraint(equalToConstant: 0)
        self.quitHintLeading = quitHint.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        self.coffeeToCenter = coffeeButton.trailingAnchor.constraint(equalTo: centerButton.leadingAnchor)
        self.coffeeToEdge = coffeeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        super.init()

        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.register(DockTileView.self, forItemIdentifier: tileViewID)
        scrubber.mode = .free
        // 选中态每次都立刻清掉（连续点同一个图标才能再次触发），点击反馈由 DockTileView.flash() 自己画。
        scrubber.selectionBackgroundStyle = nil
        scrubber.showsAdditionalContentIndicators = true
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = 0
        scrubber.scrubberLayout = layout
        scrubberWidth.isActive = true

        container.translatesAutoresizingMaskIntoConstraints = false
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        quitHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrubber)
        container.addSubview(coffeeButton)
        container.addSubview(centerButton)
        // 提示要盖在右侧两个按钮上面：只是个临时提示，让它顶到最边上。
        container.addSubview(quitHint)
        for button in [coffeeButton, centerButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
        }
        coffeeButton.action = #selector(coffeeTapped)
        coffeeButton.setAccessibilityLabel(L10n.tr("暂时隐藏 Dock", "Hide the Dock for a moment"))
        centerButton.action = #selector(centerTapped)
        centerButton.setAccessibilityLabel(L10n.tr("窗口居中", "Center the window"))
        windowWatcher.onChange = { [weak self] in self?.refreshCenterIcon() }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Metrics.maxDockWidth),
            container.heightAnchor.constraint(equalToConstant: 30),
            scrubber.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrubber.topAnchor.constraint(equalTo: container.topAnchor),
            scrubber.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            centerButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            coffeeToCenter,
            coffeeButton.topAnchor.constraint(equalTo: container.topAnchor),
            coffeeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            coffeeButton.widthAnchor.constraint(equalToConstant: Metrics.buttonWidth),
            centerButton.topAnchor.constraint(equalTo: container.topAnchor),
            centerButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            centerButton.widthAnchor.constraint(equalToConstant: Metrics.buttonWidth),
            quitHintLeading,
            quitHint.topAnchor.constraint(equalTo: container.topAnchor),
            quitHint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            quitHint.widthAnchor.constraint(equalToConstant: QuitHintView.width),
        ])

        pressRecognizer.target = self
        pressRecognizer.action = #selector(handlePress(_:))
        pressRecognizer.allowedTouchTypes = .direct
        pressRecognizer.minimumPressDuration = Metrics.pressArmDelay
        pressRecognizer.allowableMovement = Metrics.pressMovementTolerance
        pressRecognizer.delegate = self
        scrubber.addGestureRecognizer(pressRecognizer)
    }

    // MARK: - 开启 / 关闭

    func start() {
        guard !isActive, TouchBarBridge.isAvailable else { return }
        isActive = true
        swallowTapsUntilRelease = false
        TouchBarBridge.hideCloseBox()
        TouchBarBridge.addTrayItem(trayItem)
        controlStripPID = Self.currentControlStripPID()
        startObserving()
        updateWindowWatching()
        reload()
        present()
        // 刚登录时系统的 Touch Bar 进程可能还没就绪，稍后再确认一次。
        presentAgainIfHidden(after: 2)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        quitHintPreview?.cancel()
        cancelPress()
        stopObserving()
        windowWatcher.stop()
        endPause(present: false)
        TouchBarBridge.dismiss(touchBar)
        TouchBarBridge.removeTrayItem(trayItem)
    }

    // MARK: - 显示与恢复

    private func present() {
        guard isActive, !isPaused else { return }
        TouchBarBridge.present(touchBar, trayIdentifier: trayID)
    }

    /// 系统控制条里的入口按钮：暂停中就恢复，否则重新显示。
    @objc private func trayTapped() {
        endPause(present: false)
        present()
    }

    // MARK: - 临时暂停（兜底：屏幕被调黑时能用系统的亮度条）

    /// 点右侧的咖啡杯按钮：先把 Touch Bar 还给系统（亮度、音量都回来了），之后自动恢复：
    /// 暂停时屏幕已经是黑的，就等亮度回来；否则过一会儿自动恢复。中途亮度又被调黑，就一直等到亮起来。
    /// 第一下居中，再点一下最大化，再点又回到居中；窗口不是这两种样子（用户拖过、换了 App）就先居中。
    @objc private func centerTapped() {
        WindowPlacer.toggleFrontmost(heightPercent: centerHeightPercent, widthPercent: centerWidthPercent) { [weak self] in
            self?.setWindowAction($0)
        }
    }

    // MARK: - 让按钮的图标跟着窗口变

    /// 盯着最前面的 App 的窗口（移动、改大小、换窗口都会通知），图标随时对得上。切到自己（比如开着菜单）时保持原样。
    private func updateWindowWatching() {
        guard isActive, showsCenterButton else {
            windowWatcher.stop()
            return
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            windowWatcher.watch(pid: app.processIdentifier)
        }
        refreshCenterIcon()
    }

    private func refreshCenterIcon() {
        guard isActive, showsCenterButton else { return }
        WindowPlacer.nextAction(heightPercent: centerHeightPercent, widthPercent: centerWidthPercent) { [weak self] in
            self?.setWindowAction($0)
        }
    }

    private func setWindowAction(_ action: WindowPlacer.Action) {
        guard action != windowAction else { return }
        windowAction = action
        let image = action == .maximize ? PixelIcon.maximize : PixelIcon.center
        centerButton.setFrames(image.map { [$0] } ?? [])
        centerButton.setAccessibilityLabel(action == .maximize ? L10n.tr("窗口最大化", "Maximize the window")
                                                                : L10n.tr("窗口居中", "Center the window"))
    }

    @objc private func coffeeTapped() {
        beginPause()
    }

    private func beginPause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        cancelPress()
        let wasDark = ScreenBrightness.current.map { $0 < Metrics.brightnessDark } ?? false
        let start = Date()
        TouchBarBridge.dismiss(touchBar)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let brightness = ScreenBrightness.current
            let bright = brightness.map { $0 >= Metrics.brightnessRecovered } ?? true
            let waited = Date().timeIntervalSince(start) >= pauseDuration
            if bright && (wasDark || waited) { self.endPause(present: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func endPause(present shouldPresent: Bool) {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard isPaused else { return }
        isPaused = false
        if shouldPresent {
            present()
            presentAgainIfHidden(after: 1)
        }
    }

    private func presentAgainIfHidden(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isActive, !self.touchBar.isVisible else { return }
            self.present()
        }
    }

    /// 睡眠唤醒、解锁、ControlStrip 重启之后系统会收回我们的 Touch Bar，这里重新挂上。
    /// 这几个事件经常一起到，合并成一次。
    private func recover(readdTray: Bool) {
        guard isActive, !recoverScheduled else { return }
        recoverScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.recoverScheduled = false
            guard self.isActive else { return }
            TouchBarBridge.hideCloseBox()
            if readdTray { TouchBarBridge.addTrayItem(self.trayItem) }
            self.present()
            self.presentAgainIfHidden(after: 2)
        }
    }

    // MARK: - 点击 / 双击

    /// 单击切换；同一个图标在 `doubleTapInterval` 内再点一次就隐藏。
    /// 第一下照常切换、不等待，所以单击没有延迟；双击的净效果是“切过去再藏起来”。
    private func handleTap(at index: Int) {
        guard tiles.indices.contains(index), tiles[index].kind == .app else { return }
        let tile = tiles[index]
        (scrubber.itemViewForItem(at: index) as? DockTileView)?.flash()
        let now = Date()
        if doubleTapHides, let last = lastTap, last.tile.isSameSlot(as: tile),
           now.timeIntervalSince(last.time) < Metrics.doubleTapInterval {
            lastTap = nil
            AppSwitcher.hide(tile)
        } else {
            lastTap = (tile, now)
            AppSwitcher.switchTo(tile)
        }
    }

    // MARK: - 长按退出

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        let point = recognizer.location(in: scrubber)
        switch recognizer.state {
        case .began:
            beginPress(at: point)
        case .changed:
            guard var current = press, !current.moved, !current.completed else { return }
            if hypot(point.x - current.start.x, point.y - current.start.y) > Metrics.pressMovementTolerance {
                // 手指滑开了，是在滚动列表。
                current.moved = true
                press = current
                stopPressProgress()
            }
        case .ended:
            endPress()
            finishSwallowingTaps()
        case .cancelled, .failed:
            cancelPress()
            finishSwallowingTaps()
        default:
            break
        }
    }

    /// 手指抬起后，再忽略 0.3 秒内的选中回调（它可能比手势结束晚一点到）。
    private func finishSwallowingTaps() {
        guard swallowTapsUntilRelease else { return }
        swallowTapsUntilRelease = false
        suppressSelectionUntil = Date().addingTimeInterval(0.3)
    }

    private func beginPress(at point: NSPoint) {
        quitHintPreview?.cancel()
        cancelPress()
        guard let index = tileIndex(at: point) else { return }
        let tile = tiles[index]
        var newPress = Press(index: index, tile: tile, start: point)
        lastTap = nil
        // 访达不能退出，没在运行的也没什么可退出的；这两种松手后照常当作点击。
        if longPressDuration > 0, tile.kind == .app, tile.isRunning, tile.bundleID != "com.apple.finder" {
            let remaining = max(longPressDuration - Metrics.pressArmDelay, 0.1)
            let work = DispatchWorkItem { [weak self] in self?.completePress() }
            newPress.quitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            (scrubber.itemViewForItem(at: index) as? DockTileView)?.showPressProgress(duration: remaining)
            let name = tile.url.flatMap { DockModel.runningApp(bundleID: tile.bundleID, url: $0)?.localizedName }
                ?? tile.url?.deletingPathExtension().lastPathComponent ?? ""
            showQuitHint(forItemAt: index, appName: name, duration: remaining)
        }
        press = newPress
    }

    /// 在菜单里换了风格后，在 Touch Bar 上演示一遍长按提示（走一个 2.5 秒的倒计时）。
    func previewQuitHint() {
        guard isActive, !isPaused, press == nil else { return }
        quitHintPreview?.cancel()
        let duration: TimeInterval = 2.5
        quitHintLeading.constant = Metrics.maxDockWidth - QuitHintView.width
        quitHint.show(appName: AppInfo.name, duration: duration, onLeft: false)
        let work = DispatchWorkItem { [weak self] in self?.quitHint.hide(completed: true) }
        quitHintPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 提示默认贴 Touch Bar 最右边（盖住右侧的按钮）；手指按在右半边的图标上时放到最左边，免得挡住正在按的图标。
    func showQuitHint(forItemAt index: Int, appName: String, duration: TimeInterval, progress: CGFloat? = nil) {
        let tileMid = scrubber.itemViewForItem(at: index).map { container.convert($0.bounds, from: $0).midX } ?? 0
        let onLeft = tileMid > Metrics.maxDockWidth / 2
        quitHintLeading.constant = onLeft ? 0 : Metrics.maxDockWidth - QuitHintView.width
        if let progress {
            container.layoutSubtreeIfNeeded()
            quitHint.freeze(progress: progress, appName: appName, onLeft: onLeft)
        } else {
            quitHint.show(appName: appName, duration: duration, onLeft: onLeft)
        }
    }

    private func completePress() {
        guard var current = press, !current.moved, !current.completed else { return }
        current.completed = true
        current.quitWork = nil
        press = current
        swallowTapsUntilRelease = true
        (scrubber.itemViewForItem(at: current.index) as? DockTileView)?.hidePressProgress()
        quitHint.hide(completed: true)
        AppSwitcher.quit(current.tile)
    }

    /// 松手：长按已完成就吞掉这次点击；没到时间又没滑动，就当作一次普通点击。
    private func endPress() {
        guard let current = press else { return }
        stopPressProgress()
        if current.completed {
            press = nil
            return
        }
        // 松手时 NSScrubber 可能照常回调 didSelect，也可能因为手势已识别而不回调；
        // 稍等一下，没收到回调就自己补一次点击。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let current = self.press else { return }
            self.press = nil
            if !current.moved && !current.sawSelection {
                self.handleTap(at: current.index)
            }
        }
    }

    private func cancelPress() {
        stopPressProgress()
        press = nil
    }

    private func stopPressProgress() {
        quitHint.hide()
        guard let current = press else { return }
        current.quitWork?.cancel()
        press?.quitWork = nil
        (scrubber.itemViewForItem(at: current.index) as? DockTileView)?.hidePressProgress()
    }

    private func tileIndex(at point: NSPoint) -> Int? {
        tiles.indices.first { index in
            guard let view = scrubber.itemViewForItem(at: index) else { return false }
            return view.bounds.contains(view.convert(point, from: scrubber))
        }
    }

    // MARK: - 监听系统事件

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) {
            $0.scheduleReload()
            $0.updateWindowWatching()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.recover(readdTray: false) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.recover(readdTray: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.recover(readdTray: false) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            $0.recover(readdTray: false)
        }
        // App 启动/退出都会改这个列表，ControlStrip 进程重启也会反映在这里。
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.runningApplicationsChanged() }
        }
    }

    private func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        runningAppsObservation = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (DockBarController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { handler(self) }
        }
        observers.append((center, token))
    }

    private func runningApplicationsChanged() {
        guard isActive else { return }
        let pid = Self.currentControlStripPID()
        if let pid, pid != controlStripPID {
            // ControlStrip 崩溃或被重启过，入口按钮和 Dock 都要重新挂上。
            recover(readdTray: true)
        }
        controlStripPID = pid
        scheduleReload()
    }

    private static func currentControlStripPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: controlStripBundleID).first?.processIdentifier
    }

    // MARK: - 刷新图标

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    /// 不是 private：tools/render-preview 用它填充列表做离屏预览，而不必把 Dock 挂到 Touch Bar 上。
    func reload() {
        let newTiles = DockModel.tiles(includePinned: showsPinnedApps)
        guard newTiles != tiles else { return }
        let sameSlots = newTiles.count == tiles.count
            && zip(newTiles, tiles).allSatisfy { $0.isSameSlot(as: $1) }
        tiles = newTiles
        if sameSlots {
            // 只是运行状态变了：原地更新小圆点，不打断当前的滚动位置。
            for (index, tile) in tiles.enumerated() {
                (scrubber.itemViewForItem(at: index) as? DockTileView)?.configure(with: tile, iconSize: Metrics.iconSize)
            }
        } else {
            // 图标位置变了，按压记录的序号已经不对，直接作废。
            cancelPress()
            contentWidth = tiles.reduce(0) { $0 + Self.width(of: $1) }
            updateDockWidth()
            scrubber.reloadData()
        }
    }

    /// 右侧按钮占的宽度。
    private var buttonsWidth: CGFloat {
        Metrics.buttonWidth * (showsCenterButton ? 2 : 1)
    }

    private func updateDockWidth() {
        scrubberWidth.constant = min(contentWidth, Metrics.maxDockWidth - buttonsWidth)
    }

    private static func width(of tile: DockTile) -> CGFloat {
        tile.kind == .divider ? Metrics.dividerWidth : Metrics.tileWidth
    }
}

// MARK: - NSTouchBarDelegate

extension DockBarController: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == dockID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = container
        return item
    }
}

// MARK: - NSGestureRecognizerDelegate

extension DockBarController: NSGestureRecognizerDelegate {
    /// 和 NSScrubber 自己的滑动、点击识别同时进行，不抢它的触摸。
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - NSScrubber

extension DockBarController: NSScrubberDataSource, NSScrubberFlowLayoutDelegate {
    func numberOfItems(for scrubber: NSScrubber) -> Int {
        tiles.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: tileViewID, owner: nil) as? DockTileView ?? DockTileView()
        view.configure(with: tiles[index], iconSize: Metrics.iconSize)
        return view
    }

    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt itemIndex: Int) -> NSSize {
        NSSize(width: Self.width(of: tiles[itemIndex]), height: 30)
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        // 立刻清掉选中态，否则连续点同一个图标（包括双击），第二下不会触发。
        DispatchQueue.main.async { scrubber.selectedIndex = -1 }
        if swallowTapsUntilRelease { return }
        if let current = press {
            press?.sawSelection = true
            // 长按已经退出了 App，松手这一下不再算点击。
            if current.completed { return }
        } else if Date() < suppressSelectionUntil {
            return
        }
        handleTap(at: selectedIndex)
    }
}

// MARK: - 单个图标

final class DockTileView: NSScrubberItemView {
    private let highlightLayer = CALayer()
    private let iconLayer = CALayer()
    private let dotLayer = CALayer()
    private let dividerLayer = CALayer()
    private let progressLayer = CAShapeLayer()
    private var iconSize: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sublayer in [highlightLayer, iconLayer, dotLayer, dividerLayer, progressLayer] {
            sublayer.contentsScale = 2
            layer?.addSublayer(sublayer)
        }
        highlightLayer.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
        highlightLayer.cornerRadius = 6
        highlightLayer.opacity = 0
        iconLayer.contentsGravity = .resizeAspect
        dotLayer.cornerRadius = 1.5
        dividerLayer.backgroundColor = NSColor(white: 1, alpha: 0.3).cgColor
        progressLayer.strokeColor = NSColor.systemRed.cgColor
        progressLayer.fillColor = nil
        progressLayer.lineWidth = 2
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        progressLayer.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with tile: DockTile, iconSize: CGFloat) {
        self.iconSize = iconSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = tile.url.flatMap { IconCache.image(for: $0, pointSize: iconSize) }
        iconLayer.isHidden = tile.kind != .app
        dividerLayer.isHidden = tile.kind != .divider
        dotLayer.isHidden = !tile.isRunning
        // 当前前台的 App 圆点更亮。
        dotLayer.backgroundColor = NSColor(white: 1, alpha: tile.isFrontmost ? 1 : 0.5).cgColor
        CATransaction.commit()
        needsLayout = true
    }

    /// 点击反馈：短暂高亮一下。
    func flash() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.25
        highlightLayer.add(animation, forKey: "flash")
    }

    /// 长按退出的进度：图标变暗，下方红条从左到右走满。
    func showPressProgress(duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.opacity = 0.5
        dotLayer.opacity = 0
        progressLayer.isHidden = false
        progressLayer.strokeEnd = 1
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        progressLayer.add(animation, forKey: "progress")
    }

    func hidePressProgress() {
        progressLayer.removeAnimation(forKey: "progress")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.opacity = 1
        dotLayer.opacity = 1
        progressLayer.isHidden = true
        progressLayer.strokeEnd = 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let iconX = (b.width - iconSize) / 2
        highlightLayer.frame = b.insetBy(dx: 2, dy: 0)
        iconLayer.frame = CGRect(x: iconX, y: b.height - iconSize - 1, width: iconSize, height: iconSize)
        dotLayer.frame = CGRect(x: (b.width - 3) / 2, y: 1, width: 3, height: 3)
        dividerLayer.frame = CGRect(x: (b.width - 1) / 2, y: (b.height - 18) / 2, width: 1, height: 18)
        progressLayer.frame = b
        let path = CGMutablePath()
        path.move(to: CGPoint(x: iconX + 2, y: 2))
        path.addLine(to: CGPoint(x: iconX + iconSize - 2, y: 2))
        progressLayer.path = path
        CATransaction.commit()
    }
}


