import AppKit

/// 右侧两个小按钮的像素画图标：白色、8 位机风格，和长按提示里的像素画是一个味道。每格 2pt。
enum PixelIcon {
    static let cell: CGFloat = 2
    /// 每格在图片里占几个像素（Retina 屏 2 倍）。
    private static let scale = 4

    /// 咖啡杯（13×11 格）：杯口、咖啡、杯把、托盘；上面 4 行是蒸汽，一共三帧，轮流播放就是热气往上飘。
    static let coffee: [CGImage] = {
        let cup = [
            ".#########...",
            ".#.......####",
            ".#########..#",
            ".#########..#",
            ".############",
            "..#######....",
            ".###########.",
        ]
        let steam = [
            [".............", "....#...#....", "...#...#.....", "....#...#...."],
            ["...#...#.....", "....#...#....", "...#...#.....", "............."],
            ["....#...#....", "...#...#.....", ".............", "............."],
        ]
        return steam.compactMap { image($0 + cup) }
    }()

    /// 窗口居中（13×9 格）：四个角的取景框，中间一个居中的窗口。
    static let center: CGImage? = image([
        "###.......###",
        "#...........#",
        "#...........#",
        "...#######...",
        "...#######...",
        "...#######...",
        "#...........#",
        "#...........#",
        "###.......###",
    ])

    /// `#` 画成白色的一格，其他留空。
    private static func image(_ art: [String]) -> CGImage? {
        guard let width = art.first?.count,
              let context = CGContext(data: nil, width: width * scale, height: art.count * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 0.92)
        for (row, line) in art.enumerated() {
            for (column, ch) in line.enumerated() where ch == "#" {
                context.fill(CGRect(x: column * scale, y: (art.count - 1 - row) * scale, width: scale, height: scale))
            }
        }
        return context.makeImage()
    }
}

/// 只画一幅像素画的按钮；按下时暗一点。图片有多帧时循环播放（咖啡杯的蒸汽）。
/// 动画由系统在自己的进程里播放，App 本身不会被唤醒。
final class PixelButton: NSButton {
    private let iconLayer = CALayer()
    private let frames: [CGImage]
    private let iconSize: CGSize
    private let frameDuration: TimeInterval

    init(frames: [CGImage], cells: (columns: Int, rows: Int), frameDuration: TimeInterval = 0.4) {
        self.frames = frames
        self.frameDuration = frameDuration
        iconSize = CGSize(width: CGFloat(cells.columns) * PixelIcon.cell, height: CGFloat(cells.rows) * PixelIcon.cell)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        iconLayer.contents = frames.first
        iconLayer.contentsScale = 2
        iconLayer.magnificationFilter = .nearest
        iconLayer.minificationFilter = .nearest
        iconLayer.bounds = CGRect(origin: .zero, size: iconSize)
        layer?.addSublayer(iconLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { iconLayer.opacity = isHighlighted ? 0.5 : 1 }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 落在整数点上，方块的边才利落。
        iconLayer.position = CGPoint(x: (bounds.width / 2).rounded(), y: (bounds.height / 2).rounded())
        CATransaction.commit()
    }

    /// 挂到 Touch Bar 上（重新挂上）时确保动画在播。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = frameDuration * Double(frames.count)
        animation.repeatCount = .infinity
        iconLayer.add(animation, forKey: "frames")
    }
}
