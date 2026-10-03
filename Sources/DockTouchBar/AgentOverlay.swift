import AppKit

/// 盖在图标上的 Agent 状态层，整个图标变成一块 8-bit 的老式 CRT 屏幕：
/// 原图标被重画成像素版；屏幕边缘贴着图标自己的圆角，有暗色玻璃边、内阴影和左上角的反光；
/// 从下往上一层深色渐变托着内容。工作中是黑客帝国式的字符雨往下掉；做完是靠下的、粗笔画的像素 “OK” 加闪烁的光标。
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

    private let rain = CALayer()
    private let rainFade = CAGradientLayer()
    /// “OK” 两个字（5×7 点阵，每个点 1pt，8-bit 的粗笔画）和后面闪烁的光标。
    private let okText = CALayer()
    private let cursor = CALayer()
    /// 从下往上的深色渐变：托住下面的内容（字符、OK），往上渐渐透明。
    private let shade = CAGradientLayer()
    private let shape = CALayer()
    /// 工作中/做完时，原图标被重画成 8-bit 像素版（低分辨率、限色），放在屏幕里。
    private let sprite = CALayer()
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
        shade.colors = [CGColor(gray: 0, alpha: 0.8), CGColor(gray: 0, alpha: 0.38), CGColor(gray: 0, alpha: 0)]
        shade.locations = [0, 0.45, 0.9]
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        shade.contentsScale = 2
        rain.masksToBounds = true
        rain.contentsScale = 2
        // 字符雨整体的透明度：顶部几乎看不见，往下越来越亮。
        rainFade.colors = [CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 1)]
        rainFade.locations = [0, 0.5, 1]
        rainFade.startPoint = CGPoint(x: 0.5, y: 1)
        rainFade.endPoint = CGPoint(x: 0.5, y: 0)
        rain.mask = rainFade
        okText.contentsScale = 2
        okText.magnificationFilter = .nearest
        okText.minificationFilter = .nearest
        okText.contents = Self.okImage()
        cursor.backgroundColor = Self.green
        shape.contentsGravity = .resizeAspect
        shape.contentsScale = 2
        sprite.contentsScale = 2
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        content.addSublayer(sprite)
        content.addSublayer(shade)
        content.addSublayer(rain)
        content.addSublayer(okText)
        content.addSublayer(cursor)
        content.mask = shape
        addSublayer(content)
        // 贴着图标圆角的 CRT 玻璃边、内阴影和反光。
        outline.contentsScale = 2
        outline.magnificationFilter = .nearest
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
        outline.contents = icon.flatMap { Self.crtFrame(of: $0) }
        sprite.frame = content.bounds
        sprite.contents = icon.flatMap { Self.pixelated($0) }
        shade.frame = glyph
        isHidden = state == .idle
        rain.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursor.removeAllAnimations()
        rain.isHidden = true
        okText.isHidden = true
        cursor.isHidden = true
        guard state != .idle else { return }

        // 内容放在玻璃边里面（边缘约 3pt 是玻璃边和内阴影）。
        let screen = glyph.insetBy(dx: 3, dy: 3)
        switch state {
        case .working: startRain(in: screen)
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
        // 8-bit 的粗笔画：每个点 1pt（2×2 设备像素）。字 5×7 点，外面描一圈半透明黑边；光标 2×7 点。靠屏幕下方，水平居中。
        let (width, height) = Self.okImageSize
        let textSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let total = textSize.width + 1 + 2
        let left = (area.midX - total / 2).rounded()
        let bottom = (area.minY + 4).rounded()
        okText.frame = CGRect(origin: CGPoint(x: left, y: bottom), size: textSize)
        cursor.frame = CGRect(x: left + textSize.width + 1, y: bottom + 1, width: 2, height: 7)
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1
        blink.repeatCount = .infinity
        cursor.add(blink, forKey: "blink")
    }

    /// 字 5×7 点，两个字之间空 1 点，再加一圈 1 点的黑边：整张 13×9。
    private static let okImageSize = (width: 13, height: 9)

    private static func okImage() -> CGImage? {
        let (width, height) = okImageSize
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let o = [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."]
        let k = ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"]
        var pixels = Set<[Int]>()
        for (letter, art) in [(0, o), (1, k)] {
            for (row, line) in art.enumerated() {
                for (column, ch) in line.enumerated() where ch == "#" {
                    pixels.insert([1 + letter * 6 + column, 1 + (6 - row)])
                }
            }
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.7))
        for p in pixels {
            for dx in -1...1 { for dy in -1...1 where !pixels.contains([p[0] + dx, p[1] + dy]) {
                context.fill(CGRect(x: p[0] + dx, y: p[1] + dy, width: 1, height: 1))
            } }
        }
        context.setFillColor(green)
        for p in pixels { context.fill(CGRect(x: p[0], y: p[1], width: 1, height: 1)) }
        return context.makeImage()
    }

    /// 把图标重画成 8-bit 风格：缩到 28×28 个色块（每块 2 像素），每个颜色通道只留 4 档（共 64 色），
    /// 半透明的格子要么实心要么留空。放大时不插值，一格就是一个大像素。
    private static func pixelated(_ icon: CGImage) -> CGImage? {
        let n = 28, levels: CGFloat = 3
        guard let small = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = small.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        small.interpolationQuality = .high
        small.draw(icon, in: CGRect(x: 0, y: 0, width: n, height: n))
        for i in 0..<(n * n) {
            let o = i * 4
            let alpha = CGFloat(data[o + 3]) / 255
            guard alpha >= 0.5 else { data[o] = 0; data[o + 1] = 0; data[o + 2] = 0; data[o + 3] = 0; continue }
            for c in 0..<3 {
                let straight = min(CGFloat(data[o + c]) / 255 / alpha, 1)
                data[o + c] = UInt8((straight * levels).rounded() / levels * 255)
            }
            data[o + 3] = 255
        }
        return small.makeImage()
    }

    /// 贴着图标圆角的 CRT 玻璃：按“离图标边缘有几个像素”分层上色，所以圆角、异形图标都自然贴合——
    /// 最外 1 像素奶白色的机身边（上亮下暗），往里 1 像素暗色玻璃边，再往里三层由深到浅的内阴影；
    /// 左上角沿内阴影里面一圈画一道弧形反光，越靠角越亮、往两边渐隐。
    private static func crtFrame(of icon: CGImage) -> CGImage? {
        let w = icon.width, h = icon.height
        guard w > 24, h > 24,
              let source = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        source.draw(icon, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = source.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // 坐标 (x, y)：y 从画布底边往上数；内存里的行是从上往下的，这里换算一下。
        func solid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < w, y >= 0, y < h else { return false }
            return data[((h - 1 - y) * w + x) * 4 + 3] >= 128
        }
        // 每个不透明像素到最近的透明像素（或画布外）有几步，4 邻域逐层往里推。
        var depth = [Int](repeating: 0, count: w * h)
        var frontier: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where solid(x, y) {
            if !solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1) {
                depth[y * w + x] = 1
                frontier.append((x, y))
            }
        } }
        var level = 1
        while !frontier.isEmpty {
            level += 1
            var next: [(Int, Int)] = []
            for (x, y) in frontier {
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    if solid(nx, ny), depth[ny * w + nx] == 0 { depth[ny * w + nx] = level; next.append((nx, ny)) }
                }
            }
            frontier = next
        }
        guard let top = (0..<h).last(where: { y in (0..<w).contains { solid($0, y) } }),
              let left = (0..<w).first(where: { x in (0..<h).contains { solid(x, $0) } }) else { return nil }
        let glareReach = 26
        for y in 0..<h {
            let t = CGFloat(y) / CGFloat(h - 1)
            for x in 0..<w where solid(x, y) {
                let d = depth[y * w + x]
                var color: CGColor?
                switch d {
                case 1: color = CGColor(srgbRed: 0.93, green: 0.91, blue: 0.82, alpha: 0.5 + 0.4 * t)
                case 2: color = CGColor(gray: 0.04, alpha: 0.85)
                case 3: color = CGColor(gray: 0, alpha: 0.4)
                case 4: color = CGColor(gray: 0, alpha: 0.26)
                case 5, 6: color = CGColor(gray: 0, alpha: 0.12)
                default: break
                }
                // 反光：深度 7 的那一圈（内阴影的里面），离左上角越近越亮。
                if d == 7 {
                    let distance = (x - left) + (top - y)
                    if distance < glareReach { color = CGColor(gray: 1, alpha: 0.7 * (1 - CGFloat(distance) / CGFloat(glareReach))) }
                }
                if let color {
                    output.setFillColor(color)
                    output.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
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
