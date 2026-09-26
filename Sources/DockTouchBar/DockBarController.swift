import AppKit

/// Touch Bar 上的那条 Dock：显示、刷新、点击/双击/长按，以及被系统收回后自动挂回去。
final class DockBarController: NSObject {
    private enum Metrics {
        static let tileWidth: CGFloat = 36
        static let dividerWidth: CGFloat = 13
        static let iconSize: CGFloat = 24
        /// Touch Bar 占满整条时可用宽度约 1004pt。
        static let maxDockWidth: CGFloat = 1000
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
        item.view = NSButton(image: image, target: self, action: #selector(present))
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

    override init() {
        let scrubber = NSScrubber()
        self.scrubber = scrubber
        self.scrubberWidth = scrubber.widthAnchor.constraint(equalToConstant: 0)
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
        container.addSubview(quitHint)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Metrics.maxDockWidth),
            container.heightAnchor.constraint(equalToConstant: 30),
            scrubber.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrubber.topAnchor.constraint(equalTo: container.topAnchor),
            scrubber.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            quitHint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
        reload()
        present()
        // 刚登录时系统的 Touch Bar 进程可能还没就绪，稍后再确认一次。
        presentAgainIfHidden(after: 2)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        cancelPress()
        stopObserving()
        TouchBarBridge.dismiss(touchBar)
        TouchBarBridge.removeTrayItem(trayItem)
    }

    // MARK: - 显示与恢复

    @objc private func present() {
        guard isActive else { return }
        TouchBarBridge.present(touchBar, trayIdentifier: trayID)
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
            quitHint.show(appName: name, duration: remaining)
        }
        press = newPress
    }

    private func completePress() {
        guard var current = press, !current.moved, !current.completed else { return }
        current.completed = true
        current.quitWork = nil
        press = current
        swallowTapsUntilRelease = true
        (scrubber.itemViewForItem(at: current.index) as? DockTileView)?.hidePressProgress()
        quitHint.hide()
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
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.scheduleReload() }
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
            let contentWidth = tiles.reduce(0) { $0 + Self.width(of: $1) }
            scrubberWidth.constant = min(contentWidth, Metrics.maxDockWidth)
            scrubber.reloadData()
        }
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


// MARK: - 长按退出时右侧的提示

/// 长按退出时，靠 Touch Bar 右边缘显示：“正在关闭 XX”、倒计时和进度条。
/// 手指按在图标上会挡住图标下方的红条，这里给一个不会被挡住的地方。不接收触摸，不占用 Dock 的位置。
/// 文字是白色，一道高光循环扫过（类似系统“滑动来解锁”的文字流光）；背景从右边缘向内渐变淡出。
final class QuitHintView: NSView {
    static let width: CGFloat = 260

    private static let side: CGFloat = 16
    private static let countdownWidth: CGFloat = 40
    private static let barWidth: CGFloat = 170

    private let glow = CAGradientLayer()
    private let titleLayer = CATextLayer()
    private let shimmerMask = CAGradientLayer()
    private let countdownLayer = CATextLayer()
    private let track = CALayer()
    private let bar = CALayer()
    private var timer: Timer?
    private var deadline = Date()
    private var appName = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        layer?.masksToBounds = true

        // 右边缘偏深的红，向内逐渐透明。
        glow.colors = [NSColor.clear.cgColor,
                       NSColor(red: 0.42, green: 0.04, blue: 0.05, alpha: 0.55).cgColor,
                       NSColor(red: 0.30, green: 0.02, blue: 0.03, alpha: 0.92).cgColor]
        glow.locations = [0, 0.55, 1]
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)

        titleLayer.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLayer.fontSize = 12
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.alignmentMode = .right
        titleLayer.truncationMode = .end
        // 高光遮罩：中间不透明、两边半透明的一条宽带，平移过文字就是流光。
        shimmerMask.colors = [NSColor(white: 1, alpha: 0.42).cgColor, NSColor(white: 1, alpha: 0.42).cgColor,
                              NSColor(white: 1, alpha: 1).cgColor,
                              NSColor(white: 1, alpha: 0.42).cgColor, NSColor(white: 1, alpha: 0.42).cgColor]
        shimmerMask.locations = [0, 0.38, 0.5, 0.62, 1]
        shimmerMask.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerMask.endPoint = CGPoint(x: 1, y: 0.5)
        titleLayer.mask = shimmerMask

        countdownLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countdownLayer.fontSize = 12
        countdownLayer.foregroundColor = NSColor.white.cgColor
        countdownLayer.alignmentMode = .right

        track.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        bar.backgroundColor = NSColor(red: 1, green: 0.32, blue: 0.29, alpha: 1).cgColor
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        for l in [track, bar] { l.cornerRadius = 1 }

        for l in [glow, titleLayer, countdownLayer, track, bar] as [CALayer] {
            l.contentsScale = 2
            layer?.addSublayer(l)
        }
        titleLayer.contentsScale = 2
        countdownLayer.contentsScale = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var titleFrame: CGRect {
        let right = bounds.width - Self.side - Self.countdownWidth - 6
        return CGRect(x: 30, y: 12, width: right - 30, height: 15)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        titleLayer.frame = titleFrame
        let w = titleFrame.width
        shimmerMask.frame = CGRect(x: -w, y: 0, width: w * 3, height: titleFrame.height)
        countdownLayer.frame = CGRect(x: bounds.width - Self.side - Self.countdownWidth, y: 12,
                                      width: Self.countdownWidth, height: 15)
        let barFrame = CGRect(x: bounds.width - Self.side - Self.barWidth, y: 5, width: Self.barWidth, height: 2)
        track.frame = barFrame
        bar.bounds = CGRect(x: 0, y: 0, width: barFrame.width, height: barFrame.height)
        bar.position = CGPoint(x: barFrame.minX, y: barFrame.midY)
        CATransaction.commit()
    }

    func show(appName: String, duration: TimeInterval) {
        self.appName = appName
        deadline = Date().addingTimeInterval(duration)
        layoutSubtreeIfNeeded()
        updateText()

        let fill = CABasicAnimation(keyPath: "transform.scale.x")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = duration
        bar.add(fill, forKey: "fill")

        let w = titleFrame.width
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -w * 0.8
        sweep.toValue = w * 0.8
        sweep.duration = 1.5
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerMask.add(sweep, forKey: "sweep")

        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateText() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        guard alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; animator().alphaValue = 0 }) { [weak self] in
            self?.bar.removeAnimation(forKey: "fill")
            self?.shimmerMask.removeAnimation(forKey: "sweep")
        }
    }

    private func updateText() {
        let left = max(deadline.timeIntervalSinceNow, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = L10n.tr("正在关闭 \(appName)", "Closing \(appName)")
        countdownLayer.string = String(format: "%.1fs", left)
        CATransaction.commit()
    }
}
