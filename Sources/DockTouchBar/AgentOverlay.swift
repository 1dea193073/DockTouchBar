import AppKit

/// 盖在图标上的 Agent 状态层，整个图标变成一块 8-bit 的老式 CRT 屏幕：
/// 原图标被重画成像素版；屏幕边缘贴着图标自己的圆角，有暗色玻璃边、内阴影和左上角的反光；
/// 从下往上一层深色渐变托着内容。工作中是黑客帝国式的字符雨往下掉；做完是靠下的、粗笔画的像素 “OK” 加闪烁的光标。
/// 形状用图标自己的轮廓裁，所以圆角处不会溢出。动画由系统在自己的进程里播放，App 本身不会被唤醒。
final class AgentOverlayLayer: CALayer {
    private static let green = CGColor(srgbRed: 0.17, green: 1.0, blue: 0.53, alpha: 1)
    // 整个图标共用一个像素格：1pt = 2×2 设备像素（和 8-bit 原图标的 28×28 格子、OK、边框完全对齐）。
    // 字符雨的字符是 3×5 格的点阵，一个字符一格不多一格不少；字符带的图片一个像素就是一格（contentsScale = 1）。
    private static let glyphW = 3, glyphH = 5
    /// 字符带一列的宽（格；字符左右各留 1 格给光晕）、每行的高（5 格字符＋1 格行距）、一个周期的行数。
    private static let stripW = 5, rowPitch = 6, rows = 16
    /// 列间距（格）：字符 3 格＋1 格空隙。
    private static let columnPitch: CGFloat = 4
    private static let variants = 4
    private static let glyphBitmaps: [[String]] = {
        // 数字和几个像“片假名”的记号，3×5 点阵，整体左右镜像（像电影里一样）。
        let art: [[String]] = [
            ["###", "#.#", "#.#", "#.#", "###"], [".#.", "##.", ".#.", ".#.", "###"],
            ["###", "..#", "###", "#..", "###"], ["###", "..#", "###", "..#", "###"],
            ["#.#", "#.#", "###", "..#", "..#"], ["###", "#..", "###", "..#", "###"],
            ["###", "#..", "###", "#.#", "###"], ["###", "..#", ".#.", ".#.", ".#."],
            ["###", "#.#", "###", "#.#", "###"], ["###", "#.#", "###", "..#", "###"],
            ["###", ".#.", "#.#", "..#", "..#"], [".#.", "###", ".#.", "#.#", "#.#"],
            ["#..", "###", "#.#", "#.#", "..#"], ["###", "..#", ".#.", "#.#", "#.."],
            [".##", "#..", "###", "#..", ".##"], ["#.#", "#.#", "#.#", ".#.", "#.."],
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
        let screen = CGRect(x: glyph.minX.rounded(.up) + 3, y: glyph.minY.rounded(.up) + 3,
                            width: (glyph.width - 6).rounded(.down), height: (glyph.height - 6).rounded(.down))
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
        let offset = ((area.width - CGFloat(columns) * Self.columnPitch) / 2).rounded(.down)
        let periodPt = CGFloat(Self.rows * Self.rowPitch)   // 1 格 = 1pt
        for column in 0..<columns {
            var generator = SeededGenerator(seed: UInt64(column) &* 7919 &+ 17)
            // 远近感：有的列又暗又慢，有的又亮又快。
            let depth = CGFloat.random(in: 0.65...1, using: &generator)
            let images = Self.stripVariants(seed: &generator)
            let strip = CALayer()
            strip.contentsScale = 1     // 图片一个像素＝一格＝1pt
            strip.magnificationFilter = .nearest
            strip.minificationFilter = .nearest
            strip.contents = images.first
            strip.opacity = Float(depth)
            strip.frame = CGRect(x: offset + CGFloat(column) * Self.columnPitch - 1, y: 0,
                                 width: CGFloat(Self.stripW), height: periodPt * 2)
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

    /// 把图标重画成 8-bit 像素画，不是“缩小再限色”（那只是糊了一下）。用的是像素画的几样基本手法：
    /// 1. 缩到 28×28 个格子（每格 2×2 像素），放大不插值，一格就是一个大像素；
    /// 2. 先加强饱和度和对比度——像素画靠鲜明的色块说话，平淡的颜色缩小后会发灰；
    /// 3. 为每个图标单独提取一个只有 `paletteSize` 种颜色的小调色板（median cut），而不是套通用色板，所以颜色是少而准的；
    /// 4. 渐变的地方用 Bayer 4×4 有序抖动（老式 8 位机显示渐变的办法），平坦的地方就是干净的色块；
    /// 5. 半透明的格子要么实心要么留空，边缘没有渐变。
    private static let paletteSize = 10

    private static func pixelated(_ icon: CGImage) -> CGImage? {
        let n = 28, work = n * 2
        guard let source = CGContext(data: nil, width: work, height: work, bitsPerComponent: 8, bytesPerRow: work * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let out = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let src = source.data?.assumingMemoryBound(to: UInt8.self),
              let dst = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        source.interpolationQuality = .high
        source.draw(icon, in: CGRect(x: 0, y: 0, width: work, height: work))

        // 每 2×2 取平均（按透明度加权），再加强饱和度和对比度。
        typealias RGB = (r: Float, g: Float, b: Float)
        var cells = [RGB?](repeating: nil, count: n * n)
        for y in 0..<n { for x in 0..<n {
            var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let o = ((y * 2 + dy) * work + x * 2 + dx) * 4
                r += Float(src[o]); g += Float(src[o + 1]); b += Float(src[o + 2]); a += Float(src[o + 3])
            } }
            guard a / 4 >= 128 else { continue }    // 半透明的格子留空
            var color: RGB = (r / a, g / a, b / a)   // 预乘的颜色除以总透明度＝还原成不透明的颜色
            let mean = (color.r + color.g + color.b) / 3
            func boost(_ v: Float) -> Float { min(max(((mean + (v - mean) * 1.3) - 0.5) * 1.15 + 0.5, 0), 1) }
            color = (boost(color.r), boost(color.g), boost(color.b))
            cells[y * n + x] = color
        } }

        // 这个图标自己的调色板。
        let palette = medianCut(cells.compactMap { $0 }, count: paletteSize)
        guard !palette.isEmpty else { return nil }

        // Bayer 4×4 有序抖动：在找最近的调色板颜色之前，按格子位置给颜色加一点有规律的偏移。
        let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let spread: Float = 0.10
        for y in 0..<n { for x in 0..<n {
            // 位图内存的第 0 行是画面最上面一行，读和写用同一个方向，格子 (x, y) 的 y 从上往下数。
            let target = (y * n + x) * 4
            guard let color = cells[y * n + x] else { dst[target] = 0; dst[target + 1] = 0; dst[target + 2] = 0; dst[target + 3] = 0; continue }
            let offset = (bayer[(y % 4) * 4 + x % 4] / 16 - 0.5) * spread
            var best = palette[0], bestDistance = Float.greatestFiniteMagnitude
            for candidate in palette {
                let dr = color.r + offset - candidate.r, dg = color.g + offset - candidate.g, db = color.b + offset - candidate.b
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance { bestDistance = distance; best = candidate }
            }
            dst[target] = UInt8(best.r * 255); dst[target + 1] = UInt8(best.g * 255); dst[target + 2] = UInt8(best.b * 255); dst[target + 3] = 255
        } }
        return out.makeImage()
    }

    /// median cut：把所有颜色放进一个盒子，反复把“某个通道跨度最大”的盒子沿中位数切成两半，直到有 `count` 个盒子，每个盒子取平均色。
    private static func medianCut(_ colors: [(r: Float, g: Float, b: Float)], count: Int) -> [(r: Float, g: Float, b: Float)] {
        typealias RGB = (r: Float, g: Float, b: Float)
        guard !colors.isEmpty else { return [] }
        var boxes: [[RGB]] = [colors]
        func widest(_ box: [RGB]) -> (channel: Int, range: Float) {
            var low: [Float] = [1, 1, 1], high: [Float] = [0, 0, 0]
            for c in box {
                let v = [c.r, c.g, c.b]
                for i in 0..<3 { low[i] = min(low[i], v[i]); high[i] = max(high[i], v[i]) }
            }
            let ranges = (0..<3).map { high[$0] - low[$0] }
            let channel = ranges.indices.max { ranges[$0] < ranges[$1] } ?? 0
            return (channel, ranges[channel])
        }
        while boxes.count < count {
            guard let index = boxes.indices.filter({ boxes[$0].count > 1 }).max(by: { widest(boxes[$0]).range * Float(boxes[$0].count) < widest(boxes[$1]).range * Float(boxes[$1].count) }),
                  widest(boxes[index]).range > 0.02 else { break }
            let box = boxes[index]
            let channel = widest(box).channel
            let sorted = box.sorted { [$0.r, $0.g, $0.b][channel] < [$1.r, $1.g, $1.b][channel] }
            let middle = sorted.count / 2
            boxes[index] = Array(sorted[..<middle])
            boxes.append(Array(sorted[middle...]))
        }
        return boxes.map { box in
            let total = Float(box.count)
            return (box.reduce(0) { $0 + $1.r } / total, box.reduce(0) { $0 + $1.g } / total, box.reduce(0) { $0 + $1.b } / total)
        }
    }

    /// 贴着图标圆角的 CRT 玻璃，按和精灵、OK、字符雨相同的格子来画（1 格 = 1pt = 2×2 设备像素，整个图标是 28×28 格）：
    /// 按“离图标边缘有几格”分层上色，所以圆角、异形图标都自然贴合——最外一格奶白色机身边（上亮下暗），
    /// 往里一格暗色玻璃边，再往里两格由深到浅的内阴影；左上角沿内阴影画一道弧形反光，越靠角越亮、往两边渐隐。
    /// 圆角因此是按格的阶梯状，和像素版图标是同一种“像素”。
    private static func crtFrame(of icon: CGImage) -> CGImage? {
        let w = icon.width, h = icon.height
        let cell = 2
        let gw = w / cell, gh = h / cell
        guard gw > 12, gh > 12,
              let source = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        source.draw(icon, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = source.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // 格子坐标 (x, y)：y 从画布底边往上数，和输出画布一致；内存里的行是从上往下的，这里换算一下。一格里 4 个像素的平均不透明度过半才算“实”。
        func solid(_ gx: Int, _ gy: Int) -> Bool {
            guard gx >= 0, gx < gw, gy >= 0, gy < gh else { return false }
            let top = gh - 1 - gy
            var total = 0
            for dy in 0..<cell { for dx in 0..<cell { total += Int(data[((top * cell + dy) * w + gx * cell + dx) * 4 + 3]) } }
            return total / (cell * cell) >= 128
        }
        // 每个实心格到最近的空格（或画布外）有几格，4 邻域逐层往里推。
        var depth = [Int](repeating: 0, count: gw * gh)
        var frontier: [(Int, Int)] = []
        for y in 0..<gh { for x in 0..<gw where solid(x, y) {
            if !solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1) {
                depth[y * gw + x] = 1
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
                    if solid(nx, ny), depth[ny * gw + nx] == 0 { depth[ny * gw + nx] = level; next.append((nx, ny)) }
                }
            }
            frontier = next
        }
        guard let top = (0..<gh).last(where: { y in (0..<gw).contains { solid($0, y) } }),
              let left = (0..<gw).first(where: { x in (0..<gh).contains { solid(x, $0) } }) else { return nil }
        let glareReach = 13
        for y in 0..<gh {
            let t = CGFloat(y) / CGFloat(gh - 1)
            for x in 0..<gw where solid(x, y) {
                let d = depth[y * gw + x]
                var color: CGColor?
                switch d {
                case 1: color = CGColor(srgbRed: 0.93, green: 0.91, blue: 0.82, alpha: 0.5 + 0.4 * t)
                case 2: color = CGColor(gray: 0.04, alpha: 0.88)
                case 3: color = CGColor(gray: 0, alpha: 0.4)
                case 4: color = CGColor(gray: 0, alpha: 0.2)
                default: break
                }
                // 反光：深度 4 的那一圈（最里面的内阴影），离左上角越近越亮。
                if d == 4 {
                    let distance = (x - left) + (top - y)
                    if distance < glareReach { color = CGColor(gray: 1, alpha: 0.65 * (1 - CGFloat(distance) / CGFloat(glareReach))) }
                }
                if let color {
                    output.setFillColor(color)
                    output.fill(CGRect(x: x * cell, y: y * cell, width: cell, height: cell))
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
        let streams = [(head: head, trail: Int.random(in: 4...6, using: &seed)),
                       (head: (head + rows / 2) % rows, trail: Int.random(in: 4...6, using: &seed))]
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
            // 光晕：只给雨头，把字符向四周胀一格，用淡淡的绿画在底下（每个字符都带光晕的话会连成一片绿，盖住图标）。
            if isHead {
                context.setFillColor(CGColor(srgbRed: 0.1, green: 1, blue: 0.4, alpha: 0.28))
                for (r, line) in art.enumerated() {
                    for (c, ch) in line.enumerated() where ch == "#" {
                        context.fill(CGRect(x: 1 + c - 1, y: top - 1 - r - 1, width: 3, height: 3))
                    }
                }
            }
            let color = isHead
                ? CGColor(srgbRed: 0.88, green: 1, blue: 0.93, alpha: 1)
                : CGColor(srgbRed: 0.05 + 0.25 * fade, green: 0.55 + 0.45 * fade, blue: 0.25 + 0.2 * fade, alpha: 0.2 + 0.8 * fade)
            context.setFillColor(color)
            for (r, line) in art.enumerated() {
                for (c, ch) in line.enumerated() where ch == "#" {
                    context.fill(CGRect(x: 1 + c, y: top - 1 - r, width: 1, height: 1))
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
