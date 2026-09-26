import AppKit

struct DockTile: Equatable {
    enum Kind: Equatable { case app, divider }

    let kind: Kind
    let url: URL?
    let bundleID: String?
    var isRunning = false
    var isFrontmost = false

    static let divider = DockTile(kind: .divider, url: nil, bundleID: nil)

    /// 同一个位置是不是同一个 App（不看运行状态），用来判断能否原地刷新而不重建列表。
    func isSameSlot(as other: DockTile) -> Bool {
        kind == other.kind && url == other.url
    }
}

/// 按系统 Dock 的顺序生成图标列表：访达 → Dock 里固定的 App → 分隔线 → 其他正在运行的 App。
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

        var fixed: [(url: URL, bundleID: String?)] = [(finderURL, finderID)]
        if includePinned {
            fixed += pinnedApps().filter { $0.bundleID != finderID }
        }

        var tiles: [DockTile] = []
        var claimed = Set<pid_t>()
        for entry in fixed {
            let app = running.first { matches($0, bundleID: entry.bundleID, url: entry.url) }
            if let app { claimed.insert(app.processIdentifier) }
            tiles.append(DockTile(kind: .app, url: entry.url, bundleID: entry.bundleID,
                                  isRunning: app != nil,
                                  isFrontmost: app != nil && app?.processIdentifier == frontPID))
        }

        let others = running.filter { !claimed.contains($0.processIdentifier) }
        if includePinned && !others.isEmpty {
            tiles.append(.divider)
        }
        for app in others {
            tiles.append(DockTile(kind: .app, url: app.bundleURL, bundleID: app.bundleIdentifier,
                                  isRunning: true, isFrontmost: app.processIdentifier == frontPID))
        }
        return tiles
    }

    static func runningApp(bundleID: String?, url: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { matches($0, bundleID: bundleID, url: url) }
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
enum IconCache {
    private static var cache: [URL: CGImage] = [:]

    static func image(for url: URL, pointSize: CGFloat) -> CGImage? {
        if let cached = cache[url] { return cached }
        let pixels = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // 符号链接的 App（比如 /Applications/Safari.app）直接取图标会带一个小箭头，先解析成真实路径。
        NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
            .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let image = rep.cgImage
        cache[url] = image
        return image
    }
}
