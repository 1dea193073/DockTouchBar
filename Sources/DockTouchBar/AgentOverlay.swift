import AppKit

/// 盖在图标上的 Agent 状态层。工作中：整个图标上黑客帝国式的字符雨往下掉，越往上越淡，下半部分铺一层黑色渐变托住字符；
/// 做完：字符雨停掉，黑色渐变里亮出绿色的 “OK” 和一个闪烁的光标（像终端启动完成的 [ OK ]、等待下一条命令的提示符）。
/// 形状用图标自己的轮廓裁，所以圆角处不会溢出。动画由系统在自己的进程里播放，App 本身不会被唤醒。
final class AgentOverlayLayer: CALayer {
    private static let green = CGColor(srgbRed: 0.17, green: 1.0, blue: 0.53, alpha: 1)
    private static let cellWidth: CGFloat = 4.5
    private static let cellHeight: CGFloat = 5.5
    /// 字符带一个周期的行数；一个周期里有两股雨，各自带一条尾巴。
    private static let rows = 12
    private static let variants = 3
    /// 半角片假名加数字，和电影里的字符雨一个味道。
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜ0123456789")

    private let shade = CAGradientLayer()
    private let rain = CALayer()
    private let rainFade = CAGradientLayer()
    private let okText = CATextLayer()
    private let cursor = CALayer()
    private let shape = CALayer()

    private var applied: (state: AgentState, glyph: CGRect, key: URL?)?

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func commonInit() {
        contentsScale = 2
        // 黑色渐变：从图标中间（透明）到底部（最黑）。
        shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.4), CGColor(gray: 0, alpha: 0.9)]
        shade.locations = [0, 0.55, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.contentsScale = 2
        rain.masksToBounds = true
        rain.contentsScale = 2
        // 字符雨整体的透明度：顶部几乎看不见，往下越来越亮。
        rainFade.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 1)]
        rainFade.locations = [0, 0.5, 1]
        rainFade.startPoint = CGPoint(x: 0.5, y: 1)
        rainFade.endPoint = CGPoint(x: 0.5, y: 0)
        rain.mask = rainFade
        okText.string = "OK"
        okText.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy)
        okText.fontSize = 9
        okText.foregroundColor = Self.green
        okText.alignmentMode = .left
        okText.contentsScale = 2
        cursor.backgroundColor = Self.green
        shape.contentsGravity = .resizeAspect
        shape.contentsScale = 2
        addSublayer(shade)
        addSublayer(rain)
        addSublayer(okText)
        addSublayer(cursor)
        mask = shape
        isHidden = true
    }

    /// 在图标层 `frame` 里按图形范围 `glyph`（原点左下，和 `IconCache.contentRect` 同一套）铺好。
    /// `key` 是图标的来源，换了图标要重做遮罩。
    func update(state: AgentState, size: CGFloat, glyph: CGRect, icon: CGImage?, key: URL?) {
        if let applied, applied.state == state, applied.glyph == glyph, applied.key == key { return }
        applied = (state, glyph, key)
        frame = CGRect(x: frame.minX, y: frame.minY, width: size, height: size)
        shape.frame = CGRect(x: 0, y: 0, width: size, height: size)
        shape.contents = icon
        isHidden = state == .idle
        rain.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursor.removeAllAnimations()
        rain.isHidden = true
        okText.isHidden = true
        cursor.isHidden = true
        guard state != .idle else { return }

        shade.frame = CGRect(x: glyph.minX, y: glyph.minY, width: glyph.width, height: glyph.height * 0.55)
        switch state {
        case .working: startRain(in: glyph)
        case .done: showOK(in: glyph)
        case .idle: break
        }
    }

    private func startRain(in area: CGRect) {
        rain.isHidden = false
        rain.frame = area
        rainFade.frame = rain.bounds
        let columns = max(2, Int(area.width / Self.cellWidth))
        let offset = (area.width - CGFloat(columns) * Self.cellWidth) / 2
        let period = CGFloat(Self.rows) * Self.cellHeight
        for column in 0..<columns {
            var generator = SeededGenerator(seed: UInt64(column) &* 7919 &+ 17)
            let images = (0..<Self.variants).compactMap { _ in Self.strip(seed: &generator) }
            let strip = CALayer()
            strip.contentsScale = 2
            strip.contents = images.first
            strip.frame = CGRect(x: offset + CGFloat(column) * Self.cellWidth, y: 0,
                                 width: Self.cellWidth, height: period * 2)
            // 每列速度不同、起点错开；字符隔一会儿换一版，像在不停变化。
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = 0
            fall.toValue = -period
            fall.isAdditive = true
            fall.duration = Double(period) / Double(30 + (column * 7) % 22)
            fall.repeatCount = .infinity
            fall.timeOffset = Double(column) * 0.41
            strip.add(fall, forKey: "fall")
            if images.count > 1 {
                let flicker = CAKeyframeAnimation(keyPath: "contents")
                flicker.values = images
                flicker.calculationMode = .discrete
                flicker.duration = 0.5 + Double(column % 3) * 0.17
                flicker.repeatCount = .infinity
                strip.add(flicker, forKey: "flicker")
            }
            rain.addSublayer(strip)
        }
    }

    private func showOK(in area: CGRect) {
        okText.isHidden = false
        cursor.isHidden = false
        let textWidth: CGFloat = 11, cursorWidth: CGFloat = 4.5, cursorHeight: CGFloat = 8
        let total = textWidth + 1 + cursorWidth
        let left = area.midX - total / 2
        let baseline = area.minY + 2.5
        okText.frame = CGRect(x: left, y: baseline - 2.5, width: textWidth + 2, height: 12)
        cursor.frame = CGRect(x: left + textWidth + 1, y: baseline, width: cursorWidth, height: cursorHeight)
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1
        blink.repeatCount = .infinity
        cursor.add(blink, forKey: "blink")
    }

    /// 一条两个周期长的字符带：每个周期里有两股雨，雨头（最下面一格）近乎白色，尾巴往上由亮绿渐隐。
    /// 字符带整体往下走，周期衔接处看不出接缝。
    private static func strip(seed: inout SeededGenerator) -> CGImage? {
        let period = CGFloat(rows) * cellHeight
        let pixelsWide = Int(cellWidth * 2), pixelsHigh = Int(period * 2 * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        let font = NSFont.monospacedSystemFont(ofSize: 4.6, weight: .bold)
        let firstHead = Int.random(in: 0..<rows, using: &seed)
        for head in [firstHead, (firstHead + rows / 2) % rows] {
            let trail = Int.random(in: 4...6, using: &seed)
            for step in 0..<trail {
                let char = String(glyphs.randomElement(using: &seed) ?? "0")
                let color: NSColor = step == 0
                    ? NSColor(srgbRed: 0.85, green: 1, blue: 0.92, alpha: 1)
                    : NSColor(srgbRed: 0.1, green: 1.0, blue: 0.45, alpha: 1 - CGFloat(step) / CGFloat(trail + 1))
                // 在两个周期里各画一遍，越界的行绕回字符带另一端。
                for copy in 0..<2 {
                    var row = head - step
                    if row < 0 { row += rows }
                    row += copy * rows
                    let y = period * 2 - CGFloat(row + 1) * cellHeight
                    NSString(string: char).draw(at: CGPoint(x: 0.3, y: y),
                                                withAttributes: [.font: font, .foregroundColor: color])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// 固定种子的随机数，字符雨每次出来都是同一串，不会因为刷新一下就换样子。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
