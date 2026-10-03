import AppKit

/// 盖在图标上的 Agent 状态层。工作中：整个图标上黑客帝国式的字符雨往下掉，越往上越淡，下半部分铺一层黑色渐变托住字符；
/// 做完：字符雨停掉，黑色渐变里亮出绿色的 “OK” 和一个闪烁的光标（像终端启动完成的 [ OK ]、等待下一条命令的提示符）。
/// 形状用图标自己的轮廓裁，所以圆角处不会溢出。动画由系统在自己的进程里播放，App 本身不会被唤醒。
final class AgentOverlayLayer: CALayer {
    private static let green = CGColor(srgbRed: 0.17, green: 1.0, blue: 0.53, alpha: 1)
    // 字符雨在“设备像素”里手绘：Touch Bar 的图标只有 56 像素宽，用字体渲染会糊成一团，
    // 所以每个字符是 5×7 的点阵，整数像素对齐，边缘利落。
    private static let glyphW = 5, glyphH = 7
    /// 字符带一列的像素宽（字符左右各留一点给光晕）、每行的像素高、一个周期的行数。
    private static let stripW = 9, rowPitch = 9, rows = 16
    /// 列间距（pt）：7 像素。
    private static let columnPitch: CGFloat = 3.5
    private static let variants = 4
    private static let glyphBitmaps: [[String]] = {
        // 半角片假名的简化点阵 + 数字，像电影里一样整体左右镜像。
        let art: [[String]] = [
            ["#####", "...#.", "..#..", ".##..", "#.#..", "..#..", "..#.."],
            ["...#.", "..##.", ".#.#.", "#..#.", "...#.", "...#.", "...#."],
            ["..#..", "#####", "#...#", "#...#", "....#", "...#.", "..#.."],
            ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
            ["...#.", "#####", "..##.", ".#.#.", "#..#.", "...#.", "..#.."],
            [".#...", "#####", ".#..#", ".#..#", "#...#", "....#", "...#."],
            ["..#..", ".####", "..#..", "#####", "..#..", "..#..", "...##"],
            ["..#..", ".#..#", "#...#", "....#", "...#.", "..#..", ".#..."],
            ["#####", "....#", "....#", "....#", "....#", "....#", "#####"],
            ["..#..", "#####", "..#..", "..#..", "#####", "..#..", "..#.."],
            [".#.#.", ".#.#.", "#...#", "#...#", "#...#", "#...#", "#...#"],
            ["#...#", "#...#", "#...#", "#...#", "....#", "...#.", "..#.."],
            [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
            ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
            [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
            ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
            ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
            ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
            ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
            [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        ]
        return art.map { $0.map { String($0.reversed()) } }
    }()

    private let shade = CAGradientLayer()
    private let rain = CALayer()
    private let rainFade = CAGradientLayer()
    private let okText = CATextLayer()
    private let cursor = CALayer()
    private let shape = CALayer()
    /// 被图标轮廓裁剪的内容（渐变、字符雨、OK）；轮廓线本身不裁，光晕才能往外晕开一点。
    private let content = CALayer()
    private let outline = CALayer()

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
        // 整个图标适度压暗，下重上轻：字符跳得出来，同时图标本身还看得清（再加一圈绿色轮廓线帮着认）。
        shade.colors = [CGColor(gray: 0, alpha: 0.0), CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0.7)]
        shade.locations = [0, 0.5, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.contentsScale = 2
        rain.masksToBounds = true
        rain.contentsScale = 2
        // 字符雨整体的透明度：顶部几乎看不见，往下越来越亮。
        rainFade.colors = [CGColor(gray: 1, alpha: 0.4), CGColor(gray: 1, alpha: 0.75), CGColor(gray: 1, alpha: 1)]
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
        okText.shadowColor = Self.green
        okText.shadowRadius = 3
        okText.shadowOpacity = 0.95
        okText.shadowOffset = .zero
        cursor.shadowColor = Self.green
        cursor.shadowRadius = 3
        cursor.shadowOpacity = 0.95
        cursor.shadowOffset = .zero
        cursor.backgroundColor = Self.green
        shape.contentsGravity = .resizeAspect
        shape.contentsScale = 2
        content.addSublayer(shade)
        content.addSublayer(rain)
        content.addSublayer(okText)
        content.addSublayer(cursor)
        content.mask = shape
        addSublayer(content)
        // 沿图标轮廓描一圈绿线，像老式绿色荧光屏的边缘：原来的图标轮廓一直认得出来。
        outline.contentsScale = 2
        outline.magnificationFilter = .nearest
        outline.shadowColor = Self.green
        outline.shadowRadius = 2.5
        outline.shadowOpacity = 0.9
        outline.shadowOffset = .zero
        addSublayer(outline)
        isHidden = true
    }

    /// 在图标层 `frame` 里按图形范围 `glyph`（原点左下，和 `IconCache.contentRect` 同一套）铺好。
    /// `key` 是图标的来源，换了图标要重做遮罩。
    func update(state: AgentState, size: CGFloat, glyph: CGRect, icon: CGImage?, key: URL?) {
        if let applied, applied.state == state, applied.glyph == glyph, applied.key == key { return }
        applied = (state, glyph, key)
        frame = CGRect(x: frame.minX, y: frame.minY, width: size, height: size)
        content.frame = CGRect(x: 0, y: 0, width: size, height: size)
        outline.frame = content.frame
        shape.frame = content.bounds
        shape.contents = icon
        outline.contents = icon.flatMap(Self.outlineImage(of:))
        outline.removeAnimation(forKey: "glow")
        if state == .working {
            // 荧光屏一样的呼吸：亮度在 0.7 到 1 之间慢慢起伏。
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = 0.7
            glow.toValue = 1
            glow.duration = 1.4
            glow.autoreverses = true
            glow.repeatCount = .infinity
            outline.add(glow, forKey: "glow")
        }
        isHidden = state == .idle
        rain.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursor.removeAllAnimations()
        rain.isHidden = true
        okText.isHidden = true
        cursor.isHidden = true
        guard state != .idle else { return }

        shade.frame = glyph
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
        let columns = max(3, Int(area.width / Self.columnPitch))
        let offset = (area.width - CGFloat(columns) * Self.columnPitch) / 2
        let periodPt = CGFloat(Self.rows * Self.rowPitch) / 2
        for column in 0..<columns {
            var generator = SeededGenerator(seed: UInt64(column) &* 7919 &+ 17)
            // 远近感：有的列又暗又慢，有的又亮又快。
            let depth = CGFloat.random(in: 0.65...1, using: &generator)
            let images = Self.stripVariants(seed: &generator)
            let strip = CALayer()
            strip.contentsScale = 2
            strip.magnificationFilter = .nearest
            strip.minificationFilter = .nearest
            strip.contents = images.first
            strip.opacity = Float(depth)
            strip.frame = CGRect(x: offset + CGFloat(column) * Self.columnPitch - 0.5, y: 0,
                                 width: CGFloat(Self.stripW) / 2, height: periodPt * 2)
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = 0
            fall.toValue = -periodPt
            fall.isAdditive = true
            fall.duration = Double(periodPt) / Double(34 + 36 * depth)
            fall.repeatCount = .infinity
            fall.timeOffset = Double(column) * 0.53
            strip.add(fall, forKey: "fall")
            // 字符原地不停变：几版图轮流换，和下落同时进行。
            let flicker = CAKeyframeAnimation(keyPath: "contents")
            flicker.values = images
            flicker.calculationMode = .discrete
            flicker.duration = 0.55 + Double(column % 3) * 0.2
            flicker.repeatCount = .infinity
            strip.add(flicker, forKey: "flicker")
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

    /// 图标不透明区域的边缘（约 2 像素宽）染成绿色，其余透明。边缘 = 不透明、且周围 2 像素内有透明（或出了画布）的点。
    private static func outlineImage(of icon: CGImage) -> CGImage? {
        let w = icon.width, h = icon.height
        guard let source = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        source.draw(icon, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = source.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        func solid(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < w && y >= 0 && y < h && data[(y * w + x) * 4 + 3] >= 128
        }
        output.setFillColor(green)
        for y in 0..<h {
            for x in 0..<w where solid(x, y) {
                var edge = false
                scan: for dy in -2...2 {
                    for dx in -2...2 where abs(dx) + abs(dy) <= 2 && !solid(x + dx, y + dy) { edge = true; break scan }
                }
                if edge { output.fill(CGRect(x: x, y: y, width: 1, height: 1)) }
            }
        }
        return output.makeImage()
    }

    /// 一列字符带的几个版本：同一个雨头、同一条尾巴，只有一部分字符不一样，轮流播放就是字符在原地跳变。
    /// 雨头近乎白色并带一圈绿光晕，尾巴按曲线渐隐成深绿（拖影），越靠近雨头越亮。
    private static func stripVariants(seed: inout SeededGenerator) -> [CGImage] {
        // 一个周期里两股雨，各带一条尾巴，错开半个周期。
        let head = Int.random(in: 0..<rows, using: &seed)
        let streams = [(head: head, trail: Int.random(in: 6...9, using: &seed)),
                       (head: (head + rows / 2) % rows, trail: Int.random(in: 6...9, using: &seed))]
        var base = (0..<rows).map { _ in Int.random(in: 0..<glyphBitmaps.count, using: &seed) }
        var images: [CGImage] = []
        for _ in 0..<variants {
            // 每一版换掉约 40% 的字符，雨头那格总换。
            for row in 0..<rows where streams.contains(where: { $0.head == row }) || Double.random(in: 0..<1, using: &seed) < 0.4 {
                base[row] = Int.random(in: 0..<glyphBitmaps.count, using: &seed)
            }
            if let image = drawStrip(streams: streams, glyphs: base) { images.append(image) }
        }
        return images
    }

    private static func drawStrip(streams: [(head: Int, trail: Int)], glyphs: [Int]) -> CGImage? {
        let pixelsHigh = rows * rowPitch * 2
        guard let context = CGContext(data: nil, width: stripW, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(false)
        func paint(_ rowIndex: Int, step: Int, trail: Int) {
            let art = glyphBitmaps[glyphs[((rowIndex % rows) + rows) % rows]]
            let top = pixelsHigh - rowIndex * rowPitch  // 这一行上沿（位图原点在左下）
            let fade = pow(1 - CGFloat(step) / CGFloat(trail), 1.7)
            let isHead = step == 0
            // 光晕：雨头和紧跟着的一格，把字符向四周胀一圈，用半透明的绿画在底下。
            if step <= 1 {
                context.setFillColor(CGColor(srgbRed: 0.1, green: 1, blue: 0.4, alpha: isHead ? 0.5 : 0.22))
                for (r, line) in art.enumerated() {
                    for (c, ch) in line.enumerated() where ch == "#" {
                        context.fill(CGRect(x: 2 + c - 1, y: top - 1 - r - 1, width: 3, height: 3))
                    }
                }
            }
            let color = isHead
                ? CGColor(srgbRed: 0.88, green: 1, blue: 0.93, alpha: 1)
                : CGColor(srgbRed: 0.05 + 0.25 * fade, green: 0.55 + 0.45 * fade, blue: 0.25 + 0.2 * fade, alpha: 0.2 + 0.8 * fade)
            context.setFillColor(color)
            for (r, line) in art.enumerated() {
                for (c, ch) in line.enumerated() where ch == "#" {
                    context.fill(CGRect(x: 2 + c, y: top - 1 - r, width: 1, height: 1))
                }
            }
        }
        // 字符带每隔 `rows` 行重复一次（两个周期），尾巴越过边界的部分落到另一个周期里，整体往下走时看不出接缝。
        for (head, trail) in streams {
            for step in stride(from: trail - 1, through: 0, by: -1) {
                for cycle in -1...1 {
                    let index = head - step + cycle * rows
                    if (0..<(rows * 2)).contains(index) { paint(index, step: step, trail: trail) }
                }
            }
        }
        return context.makeImage()
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
