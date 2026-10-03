// 用 App 自己的代码生成 Dock 视图，放进离屏窗口，按 Touch Bar 尺寸（1004×30pt，2x）渲染成 PNG。
// 不会把 Dock 挂到 Touch Bar 上，所以不影响正在运行的 DockTouchBar。
// 由 tools/render-preview.sh 编译运行。环境变量：
//   PREVIEW_DEMO=1        用系统自带 App 做示例，不读你自己的 Dock（做 README 示意图时用）
//   PREVIEW_AGENT=2       所有 App 都画状态层（交替“工作中 / 做完”），看每个图标的主题色边框
//   PREVIEW_AGENT=1       给 Safari / Notes 画“AI 助手工作中”、给 Messages 画“做完了”的状态层（Vibecoding 版）
//   PREVIEW_PRESS_INDEX=n 让第 n 个图标显示长按退出的进度条
//   PREVIEW_PROGRESS=p    配合上一项，把长按提示定格在倒计时走到 p（0…1）的样子，默认 0.5
//   PREVIEW_WIDE=1        把示例图标翻倍，撑满整条（看长按提示靠左的效果）
//   PREVIEW_THEME=name    长按提示的季节：spring（默认）/ summer / autumn / winter
//   PREVIEW_LANG=en|zh    图里文字的语言（默认跟随系统）
//   PREVIEW_FRAME=1       输出带圆角 Touch Bar 外框和留白的版本
//   PREVIEW_LIVE=1        不离屏渲染，而是把窗口真的显示在屏幕上跑起来（动画、粒子都是真的），打印 `WINDOW <编号>` 后
//                         停留 PREVIEW_LIVE_SECONDS 秒（默认 6）；由 tools/render-seasons.sh 用 screencapture 截下来
// 另外两个不需要 Dock 的小功能：
//   render-preview --frame 输入.png 输出.png            给截图加上圆角 Touch Bar 外框和留白
//   render-preview --stack 输出.png 图1.png 图2.png …   把几张图上下拼成一张
import AppKit


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

func loadImage(_ path: String) -> CGImage? {
    NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func writePNG(_ image: CGImage?, to path: String) {
    guard let png = image.flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) else {
        print("写不出 \(path)"); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

/// 把几张图上下拼起来，宽度取最宽的，左右居中。
func stacked(_ images: [CGImage]) -> CGImage? {
    let width = images.map(\.width).max() ?? 0
    let height = images.map(\.height).reduce(0, +)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var y = height
    for image in images {
        y -= image.height
        context.draw(image, in: CGRect(x: (width - image.width) / 2, y: y, width: image.width, height: image.height))
    }
    return context.makeImage()
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "--frame" {
    writePNG(loadImage(arguments[2]).flatMap(framed), to: arguments[3])
    exit(0)
}
if arguments.count > 3, arguments[1] == "--stack" {
    writePNG(stacked(arguments[3...].compactMap(loadImage)), to: arguments[2])
    exit(0)
}

let env = ProcessInfo.processInfo.environment
if let language = env["PREVIEW_LANG"].flatMap(AppLanguage.init(rawValue:)) { L10n.preference = language }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview.png"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if env["PREVIEW_DEMO"] == "1" {
    func tile(_ path: String, _ id: String, running: Bool = false, front: Bool = false, temporary: Bool = false) -> DockTile {
        DockTile(kind: .app, url: URL(fileURLWithPath: path), bundleID: id, isRunning: running, isFrontmost: front, isTemporary: temporary)
    }
    DockModel.previewTiles = [
        tile("/System/Applications/TextEdit.app", "com.apple.TextEdit", running: true, temporary: true),
        tile("/System/Applications/Calculator.app", "com.apple.calculator", running: true, temporary: true),
        .temporaryDivider,
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
        .trash,
    ]
}

if env["PREVIEW_AGENT"] == "2", var tiles = DockModel.previewTiles {
    // 所有 App 都画状态层，单双号交替“工作中 / 做完”，一次看多个图标的配色。
    var flip = false
    for index in tiles.indices where tiles[index].kind == .app {
        tiles[index].agentState = flip ? .done : .working
        flip.toggle()
    }
    DockModel.previewTiles = tiles
}
if env["PREVIEW_AGENT"] == "1", var tiles = DockModel.previewTiles {
    for index in tiles.indices {
        switch tiles[index].bundleID {
        case "com.apple.Safari", "com.apple.Notes": tiles[index].agentState = .working
        case "com.apple.MobileSMS": tiles[index].agentState = .done
        default: break
        }
    }
    DockModel.previewTiles = tiles
}
if env["PREVIEW_WIDE"] == "1", let tiles = DockModel.previewTiles {
    let extra = tiles.filter { $0.kind == .app }
    DockModel.previewTiles = Array(tiles.dropLast(2)) + extra + [.divider, .trash]
}
let controller = DockBarController()
if let theme = env["PREVIEW_THEME"].flatMap(QuitHintTheme.init(rawValue:)) { controller.quitHintTheme = theme }
controller.reload()
guard let item = controller.touchBar(NSTouchBar(), makeItemForIdentifier: .init("com.maohuhu.docktouchbar.dock")) as? NSCustomTouchBarItem,
      let container = item.view as NSView?,
      let scrubber = container.subviews.compactMap({ $0 as? NSScrubber }).first else {
    print("拿不到 Dock 视图"); exit(1)
}

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1004, height: 30), styleMask: .borderless,
                      backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
if env["PREVIEW_LIVE"] == "1" {
    window.backgroundColor = .black
    window.level = .floating
    window.setFrameOrigin(NSPoint(x: 60, y: 120))
    window.orderFrontRegardless()
}
let root = NSView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
root.wantsLayer = true
root.layer?.backgroundColor = NSColor.black.cgColor
window.contentView = root
container.translatesAutoresizingMaskIntoConstraints = false
root.addSubview(container)
NSLayoutConstraint.activate([
    container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
    container.topAnchor.constraint(equalTo: root.topAnchor),
])

// 等一个 run loop，让 NSScrubber 把图标视图建出来。
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    root.layoutSubtreeIfNeeded()
    if env["PREVIEW_LIVE"] == "1" {
        // 真的把窗口显示出来并让长按提示跑起来，由外面的脚本用 screencapture 按窗口编号截图。
        if let index = env["PREVIEW_PRESS_INDEX"].flatMap(Int.init) {
            (scrubber.itemViewForItem(at: index) as? DockTileView)?.showPressed()
            controller.showQuitHint(forItemAt: index, appName: "Messages", duration: 3)
        }
        print("WINDOW \(window.windowNumber)")
        fflush(stdout)
        let seconds = env["PREVIEW_LIVE_SECONDS"].flatMap(Double.init) ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        return
    }
    if let index = env["PREVIEW_PRESS_INDEX"].flatMap(Int.init) {
        (scrubber.itemViewForItem(at: index) as? DockTileView)?.showPressed()
        controller.showQuitHint(forItemAt: index, appName: "Messages", duration: 3,
                                progress: CGFloat(env["PREVIEW_PROGRESS"].flatMap(Double.init) ?? 0.5))
    }
    root.display()
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(1) }
    root.cacheDisplay(in: root.bounds, to: rep)
    var result = rep.cgImage
    if env["PREVIEW_FRAME"] == "1", let image = result { result = framed(image) }
    writePNG(result, to: output)
    print("Dock 宽度 \(Int(scrubber.frame.width))pt")
    exit(0)
}
app.run()
