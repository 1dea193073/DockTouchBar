// 用 App 自己的代码生成 Dock 视图，放进离屏窗口，按 Touch Bar 尺寸（1004×30pt，2x）渲染成 PNG。
// 不会把 Dock 挂到 Touch Bar 上，所以不影响正在运行的 DockTouchBar。
// 由 tools/render-preview.sh 编译运行。环境变量：
//   PREVIEW_DEMO=1        用系统自带 App 做示例，不读你自己的 Dock（做 README 示意图时用）
//   PREVIEW_PRESS_INDEX=n 让第 n 个图标显示长按退出的进度条
//   PREVIEW_FRAME=1       输出带圆角 Touch Bar 外框和留白的版本
import AppKit

let env = ProcessInfo.processInfo.environment
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview.png"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if env["PREVIEW_DEMO"] == "1" {
    func tile(_ path: String, _ id: String, running: Bool = false, front: Bool = false) -> DockTile {
        DockTile(kind: .app, url: URL(fileURLWithPath: path), bundleID: id, isRunning: running, isFrontmost: front)
    }
    DockModel.previewTiles = [
        tile("/System/Library/CoreServices/Finder.app", "com.apple.finder", running: true),
        tile("/Applications/Safari.app", "com.apple.Safari", running: true),
        tile("/System/Applications/Messages.app", "com.apple.MobileSMS", running: true, front: true),
        tile("/System/Applications/Mail.app", "com.apple.mail"),
        tile("/System/Applications/Maps.app", "com.apple.Maps"),
        tile("/System/Applications/Photos.app", "com.apple.Photos"),
        tile("/System/Applications/Notes.app", "com.apple.Notes", running: true),
        tile("/System/Applications/Calendar.app", "com.apple.iCal"),
        tile("/System/Applications/Music.app", "com.apple.Music"),
        tile("/System/Applications/Reminders.app", "com.apple.reminders"),
        tile("/System/Applications/Podcasts.app", "com.apple.podcasts"),
        tile("/System/Applications/System Settings.app", "com.apple.systempreferences"),
        .divider,
        tile("/System/Applications/Calculator.app", "com.apple.calculator", running: true),
        tile("/System/Applications/TextEdit.app", "com.apple.TextEdit", running: true),
    ]
}

let controller = DockBarController()
controller.reload()
guard let item = controller.touchBar(NSTouchBar(), makeItemForIdentifier: .init("com.maohuhu.docktouchbar.dock")) as? NSCustomTouchBarItem,
      let scrubber = item.view as? NSScrubber else {
    print("拿不到 Dock 视图"); exit(1)
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1004, height: 30), styleMask: .borderless,
                      backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
let root = NSView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
root.wantsLayer = true
root.layer?.backgroundColor = NSColor.black.cgColor
window.contentView = root
scrubber.translatesAutoresizingMaskIntoConstraints = false
root.addSubview(scrubber)
NSLayoutConstraint.activate([
    scrubber.leadingAnchor.constraint(equalTo: root.leadingAnchor),
    scrubber.topAnchor.constraint(equalTo: root.topAnchor),
    scrubber.bottomAnchor.constraint(equalTo: root.bottomAnchor),
])

/// 把 Touch Bar 画面放进圆角黑色外框，四周留白并加一点阴影，更像“一条 Touch Bar”。
func framed(_ image: CGImage) -> CGImage? {
    let padX = 64, padY = 72
    let width = image.width + padX * 2, height = image.height + padY * 2
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let bar = CGRect(x: padX, y: padY, width: image.width, height: image.height)
    let path = CGPath(roundedRect: bar, cornerWidth: 18, cornerHeight: 18, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(image, in: bar)
    context.restoreGState()
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 0.26, alpha: 1))
    context.setLineWidth(2)
    context.strokePath()
    return context.makeImage()
}

// 等一个 run loop，让 NSScrubber 把图标视图建出来。
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    root.layoutSubtreeIfNeeded()
    if let index = env["PREVIEW_PRESS_INDEX"].flatMap(Int.init) {
        (scrubber.itemViewForItem(at: index) as? DockTileView)?.showPressProgress(duration: 3)
    }
    root.display()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(1) }
    root.cacheDisplay(in: root.bounds, to: rep)
    var result = rep.cgImage
    if env["PREVIEW_FRAME"] == "1", let image = result { result = framed(image) }
    guard let png = result.flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: output))
    print("Wrote \(output)（Dock 宽度 \(Int(scrubber.frame.width))pt）")
    exit(0)
}
app.run()
