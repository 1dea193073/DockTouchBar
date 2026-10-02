import AppKit

struct DockTile: Equatable {
    enum Kind: Equatable { case app, divider, trash }

    let kind: Kind
    let url: URL?
    let bundleID: String?
    var isRunning = false
    var isFrontmost = false
    var isTemporary = false

    static let divider = DockTile(kind: .divider, url: nil, bundleID: nil)
    static let temporaryDivider = DockTile(kind: .divider, url: nil, bundleID: "temporary-apps")
    static let trash = DockTile(kind: .trash,
                               url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true),
                               bundleID: nil)

    /// 同一个位置是不是同一个 App（不看运行状态），用来判断能否原地刷新而不重建列表。
    func isSameSlot(as other: DockTile) -> Bool {
        kind == other.kind && url == other.url && bundleID == other.bundleID
    }
}

/// 临时 App（最近启动的在最左）→ 访达和固定 App → 垃圾桶。
enum DockModel {
    private static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    private static let finderID = "com.apple.finder"

    /// 只给 tools/render-preview 用：设置后 `tiles` 直接返回它，不读系统 Dock，
    /// 这样生成 README 示意图时，图里只有示例 App，不会带上使用者自己的 App。
    static var previewTiles: [DockTile]?

    static func tiles(includePinned: Bool) -> [DockTile] {
        if let previewTiles { return previewTiles }
        let workspace = NSWorkspace.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && $0.bundleURL != nil
        }
        let frontPID = workspace.frontmostApplication?.processIdentifier
        let pinned = pinnedApps()

        var tiles: [DockTile] = []
        var claimed = Set<pid_t>()

        // 访达进程杀不掉、永远“在运行”，看进程没有意义，和别的 App 对齐：有打开的窗口（任何桌面、最小化都算）才算启动，
        // 图标亮；红点（前台）还要求访达在前台并且窗口真的显示在屏幕上——切到别的桌面、别的 App，
        // 或者空桌面上访达接管前台但窗口在别的桌面，都是“启动着，但不在前台”。
        let finderApp = running.first { matches($0, bundleID: finderID, url: finderURL) }
        let finderOpen = finderApp.map { AppSwitcher.hasOpenWindows(pid: $0.processIdentifier) } ?? false
        let finderFront = finderOpen && finderApp.map {
            $0.processIdentifier == frontPID && !$0.isHidden && AppSwitcher.hasVisibleWindows(pid: $0.processIdentifier)
        } == true
        if let finderApp { claimed.insert(finderApp.processIdentifier) }
        tiles.append(DockTile(kind: .app, url: finderURL, bundleID: finderID,
                              isRunning: finderOpen, isFrontmost: finderFront))

        if includePinned {
            for entry in pinned where entry.bundleID != finderID {
                // 同一个 App 可能同时有多个 regular 进程（Chrome 会短暂冒出同 bundle 的额外进程），
                // 全部认领；只认领第一个的话，其余会被当成“新启动的临时 App”冒到最左边。
                let instances = running.filter { matches($0, bundleID: entry.bundleID, url: entry.url) }
                instances.forEach { claimed.insert($0.processIdentifier) }
                tiles.append(DockTile(kind: .app, url: entry.url, bundleID: entry.bundleID,
                                      isRunning: !instances.isEmpty,
                                      isFrontmost: instances.contains { $0.processIdentifier == frontPID }))
            }
        }

        // 不按激活时间排：点击/切换已经打开的 App 不应让列表跳动。
        // 同一个 App 的多个进程合并成一个图标，位置按最早启动的那个算，短命的额外进程不会让它跳到最左边。
        var groups: [String: [NSRunningApplication]] = [:]
        for app in running where !claimed.contains(app.processIdentifier) {
            groups[app.bundleIdentifier ?? app.bundleURL?.path ?? "pid-\(app.processIdentifier)", default: []].append(app)
        }
        let others = groups.values.compactMap { group -> (app: NSRunningApplication, front: Bool)? in
            guard let first = group.min(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return nil }
            return (first, group.contains { $0.processIdentifier == frontPID })
        }.sorted {
            let left = $0.app.launchDate ?? .distantPast
            let right = $1.app.launchDate ?? .distantPast
            if left != right { return left > right }
            return ($0.app.bundleURL?.path ?? "") < ($1.app.bundleURL?.path ?? "")
        }
        let temporaryTiles = others.map { item in
            DockTile(kind: .app, url: item.app.bundleURL, bundleID: item.app.bundleIdentifier,
                     isRunning: true, isFrontmost: item.front,
                     isTemporary: !pinned.contains { matches(item.app, bundleID: $0.bundleID, url: $0.url) })
        }
        if !temporaryTiles.isEmpty {
            tiles.insert(contentsOf: temporaryTiles + [.temporaryDivider], at: 0)
        }
        tiles.append(contentsOf: [.divider, .trash])
        return tiles
    }

    static func runningApp(bundleID: String?, url: URL) -> NSRunningApplication? {
        // 有多个同 bundle 进程时，取最早启动的（长期运行的那个），不取短命的额外进程。
        NSWorkspace.shared.runningApplications.filter { matches($0, bundleID: bundleID, url: url) }
            .min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    /// 访达现在的 PID，给 `FinderWindowMonitor` 盯着用。进程杀不掉，一般不会变，崩溃重启后会变。
    static func finderPID() -> pid_t? {
        runningApp(bundleID: finderID, url: finderURL)?.processIdentifier
    }

    /// 长按退出前再确认一次“真的在运行”：访达窗口开关不触发任何通知，`tile.isRunning` 可能是缓存的旧值；
    /// 其它 App 只要进程还在（能走到这里说明已经查到了）就算数，不用再多查一次窗口。
    static func isActuallyRunning(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == finderID ? AppSwitcher.hasOpenWindows(pid: app.processIdentifier) : true
    }

    private static func matches(_ app: NSRunningApplication, bundleID: String?, url: URL) -> Bool {
        if let bundleID, app.bundleIdentifier == bundleID { return true }
        return app.bundleURL?.standardizedFileURL == url.standardizedFileURL
    }

    /// 读 `com.apple.dock` 的 `persistent-apps`，就是 Dock 左半边固定的那些 App。
    private static func pinnedApps() -> [(url: URL, bundleID: String?)] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let entries = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let tile = entry["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let raw = file["_CFURLString"] as? String else { return nil }
            let url = raw.hasPrefix("file://") ? URL(string: raw) : URL(fileURLWithPath: raw)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (url, tile["bundle-identifier"] as? String)
        }
    }
}

/// 图标只按 Touch Bar 需要的尺寸栅格化一次，之后复用，避免每次刷新都重绘大图。
///
/// 系统给的图标图片自带透明留白（Big Sur 起的图标模板四周留了约 20% 边距，图形本身只占画布中间
/// 一块，参考 https://applypixels.com/resource/macos-11-big-sur-app-icon）；这里先在一张小图上量出
/// 图形实际不透明的范围，再照量出来的范围把图形贴到画布底边、尽量撑满，画出来的图标里就不会再有
/// 这圈用不上的留白——图标区往下贴齐，往上腾出的空间给状态点用。
enum IconCache {
    /// `contentRect`：图形（裁掉留白之后）在 `pointSize` 画布里的实际范围，原点左下角，和 `iconLayer`
    /// 本地坐标系是同一套。状态点要贴着这块范围的角，不是贴着画布本身的角——两者用的是同一份测量，
    /// 图标换了大小或者图形本身比例不一样，点跟着一起变，不用再分开手调一遍。
    private struct Entry { let image: CGImage; let contentRect: CGRect }
    private static var cache: [URL: Entry] = [:]
    /// 量边框只是为了拿个大致比例，不用画很大；量完就丢，不留内存。
    private static let probeSize = 64
    /// 边缘反走样的像素透明度很低，量的时候不算数，免得把留白量进图形范围里。
    private static let alphaThreshold: UInt8 = 32

    static func image(for url: URL, pointSize: CGFloat) -> CGImage? {
        entry(for: url, pointSize: pointSize)?.image
    }

    static func contentRect(for url: URL, pointSize: CGFloat) -> CGRect? {
        entry(for: url, pointSize: pointSize)?.contentRect
    }

    private static func entry(for url: URL, pointSize: CGFloat) -> Entry? {
        if let cached = cache[url] { return cached }
        // 符号链接的 App（比如 /Applications/Safari.app）直接取图标会带一个小箭头，先解析成真实路径。
        let icon: NSImage
        if url == DockTile.trash.url {
            guard let trashIcon = NSImage(named: NSImage.trashEmptyName) else { return nil }
            icon = trashIcon
        } else {
            icon = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
        }
        let bounds = contentBounds(of: icon) ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        let pixels = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let drawn = drawRect(fitting: bounds, canvas: CGFloat(pixels))
        icon.draw(in: drawn)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }

        // `drawn` 是整张图标（含留白）画上去的矩形（像素坐标，2x）；图形本身在这矩形里占 `bounds` 那一块，
        // 换算回点坐标就是图形在最终画布里的真实范围。
        let contentPx = CGRect(x: drawn.minX + bounds.minX * drawn.width,
                               y: drawn.minY + bounds.minY * drawn.height,
                               width: bounds.width * drawn.width, height: bounds.height * drawn.height)
        let contentRect = CGRect(x: contentPx.minX / 2, y: contentPx.minY / 2,
                                 width: contentPx.width / 2, height: contentPx.height / 2)
        let result = Entry(image: image, contentRect: contentRect)
        cache[url] = result
        return result
    }

    /// 把 `bounds`（图标图形在图标自己 0…1 画布里的实际范围）贴到边长 `canvas` 的目标画布：
    /// 等比缩放到图形较长的那条边刚好撑满，下边贴着画布底边，水平居中。
    /// 整张图标图片（含留白）要画到这个矩形里，图形本身缩放/贴齐之后自然落在留白被裁掉的位置。
    private static func drawRect(fitting bounds: CGRect, canvas: CGFloat) -> CGRect {
        let scale = canvas / max(bounds.width, bounds.height)
        let side = scale
        let x = canvas / 2 - (bounds.minX + bounds.width / 2) * side
        let y = -bounds.minY * side
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 量出图标图形（不透明像素）在它自己 0…1 画布里的范围；量不出来就返回 nil，调用方会退回整张画布。
    private static func contentBounds(of icon: NSImage) -> CGRect? {
        let p = probeSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: p, pixelsHigh: p,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep), let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: p, height: p))
        NSGraphicsContext.restoreGraphicsState()

        let bytesPerRow = rep.bytesPerRow
        var minX = p, maxX = -1, minRow = p, maxRow = -1
        for row in 0..<p {
            for x in 0..<p where data[row * bytesPerRow + x * 4 + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return nil }
        // 位图第 0 行是画面最上面一行；转换成图标自己 0…1、原点在左下角的坐标系。
        let left = CGFloat(minX) / CGFloat(p)
        let right = CGFloat(maxX + 1) / CGFloat(p)
        let top = 1 - CGFloat(minRow) / CGFloat(p)
        let bottom = 1 - CGFloat(maxRow + 1) / CGFloat(p)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
