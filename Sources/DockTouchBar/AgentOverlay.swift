import AppKit

/// 盖在图标下三分之一的黑色渐变层：工作中是黑客帝国式的 0/1 字符雨往下掉，做完是一个绿色对号。
/// 形状用图标自己的轮廓裁，所以圆角处不会溢出。动画由系统在自己的进程里播放，App 本身不会被唤醒。
final class AgentOverlayLayer: CALayer {
    private static let green = CGColor(srgbRed: 0.17, green: 1.0, blue: 0.53, alpha: 1)
    private static let cellWidth: CGFloat = 4.5
    private static let cellHeight: CGFloat = 5.5
    private static let rows = 8

    private let shade = CAGradientLayer()
    private let rain = CALayer()
    private let check = CAShapeLayer()
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
        shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.88)]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.contentsScale = 2
        rain.masksToBounds = true
        rain.contentsScale = 2
        check.fillColor = nil
        check.strokeColor = Self.green
        check.lineWidth = 1.8
        check.lineCap = .round
        check.lineJoin = .round
        shape.contentsGravity = .resizeAspect
        shape.contentsScale = 2
        addSublayer(shade)
        addSublayer(rain)
        addSublayer(check)
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
        rain.removeAllAnimations()
        check.removeAllAnimations()
        check.isHidden = true
        rain.isHidden = true
        guard state != .idle else { return }

        let band = CGRect(x: glyph.minX, y: glyph.minY, width: glyph.width, height: glyph.height / 3)
        shade.frame = band
        rain.frame = band
        switch state {
        case .working: startRain(in: band)
        case .done: showCheck(in: band)
        case .idle: break
        }
    }

    private func startRain(in band: CGRect) {
        rain.isHidden = false
        let columns = max(2, Int(band.width / Self.cellWidth))
        let offset = (band.width - CGFloat(columns) * Self.cellWidth) / 2
        let period = CGFloat(Self.rows) * Self.cellHeight
        for column in 0..<columns {
            var generator = SeededGenerator(seed: UInt64(column) &* 7919 &+ 17)
            let strip = CALayer()
            strip.contentsScale = 2
            strip.contents = Self.strip(seed: &generator)
            strip.frame = CGRect(x: offset + CGFloat(column) * Self.cellWidth, y: 0,
                                 width: Self.cellWidth, height: period * 2)
            // 每列速度不同，错落一点；起点也错开，一开始不会整齐划一。
            let animation = CABasicAnimation(keyPath: "position.y")
            animation.fromValue = 0
            animation.toValue = -period
            animation.isAdditive = true
            animation.duration = 0.9 + Double(column % 4) * 0.22
            animation.repeatCount = .infinity
            animation.timeOffset = Double(column) * 0.37
            strip.add(animation, forKey: "rain")
            rain.addSublayer(strip)
        }
    }

    private func showCheck(in band: CGRect) {
        check.isHidden = false
        let side = min(band.height * 0.8, band.width * 0.4)
        let center = CGPoint(x: band.midX, y: band.minY + band.height * 0.5)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - side * 0.5, y: center.y))
        path.addLine(to: CGPoint(x: center.x - side * 0.12, y: center.y - side * 0.4))
        path.addLine(to: CGPoint(x: center.x + side * 0.55, y: center.y + side * 0.45))
        check.path = path
        check.frame = bounds
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.25
        check.add(draw, forKey: "draw")
    }

    /// 一条两个周期长的字符带：每个周期里字符由暗到亮，亮的在下面（雨头）；字符带整体往下走，周期衔接处看不出接缝。
    private static func strip(seed: inout SeededGenerator) -> CGImage? {
        let period = CGFloat(rows) * cellHeight
        let pixelsWide = Int(cellWidth * 2), pixelsHigh = Int(period * 2 * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let digits = (0..<rows).map { _ in Bool.random(using: &seed) ? "1" : "0" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        let font = NSFont.monospacedSystemFont(ofSize: 4.6, weight: .bold)
        for row in 0..<(rows * 2) {
            // 位图坐标原点在左下；第 0 行放在最上面。
            let level = CGFloat(row % rows + 1) / CGFloat(rows)
            let color = NSColor(srgbRed: 0.17, green: 1.0, blue: 0.53, alpha: 0.15 + 0.85 * level * level)
            let y = period * 2 - CGFloat(row + 1) * cellHeight
            NSString(string: digits[row % rows]).draw(at: CGPoint(x: 0.4, y: y),
                                                      withAttributes: [.font: font, .foregroundColor: color])
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
