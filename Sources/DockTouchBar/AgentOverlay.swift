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

    private let rain = CALayer()
    private let rainFade = CAGradientLayer()
    /// “OK” 两个字（1 像素笔画的点阵）和后面闪烁的光标。
    private let okText = CALayer()
    private let cursor = CALayer()
    /// 下巴（磁盘区域）的高度，单位 pt = 7 像素。字符雨和渐变都不进这一块，它也是图标上唯一不透明盖住原图的地方。
    private static let chinHeight: CGFloat = 3.5
    private let shape = CALayer()
    /// 工作中/做完时，原图标被重画成 8-bit 像素版（低分辨率、限色），放在屏幕里。
    private let sprite = CALayer()
    /// 被图标轮廓裁剪的内容（渐变、字符雨、OK）；轮廓线本身不裁，光晕才能往外晕开一点。
    private let content = CALayer()
    private let outline = CALayer()
    /// 下巴上的指示灯：工作中像读磁盘一样闪，做完常亮。盖在边框上面（边框的下巴是不透明的）。
    private let led = CALayer()

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
        content.addSublayer(rain)
        content.addSublayer(okText)
        content.addSublayer(cursor)
        content.mask = shape
        addSublayer(content)
        // 沿图标轮廓描一圈像素风的边框（经典 Mac 的做法：硬边、阶梯状的圆角、里面再压一圈暗线），原来的图标轮廓一直认得出来。
        outline.contentsScale = 2
        outline.magnificationFilter = .nearest
        addSublayer(outline)
        led.backgroundColor = Self.green
        led.shadowColor = Self.green
        led.shadowRadius = 2
        led.shadowOpacity = 0.9
        led.shadowOffset = .zero
        addSublayer(led)
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
        let built = icon.flatMap { Self.screenFrame(of: $0) }
        outline.contents = built?.image
        sprite.frame = content.bounds
        sprite.contents = icon.flatMap { Self.pixelated($0) }
        isHidden = state == .idle
        rain.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursor.removeAllAnimations()
        led.removeAllAnimations()
        rain.isHidden = true
        okText.isHidden = true
        cursor.isHidden = true
        led.isHidden = true
        guard state != .idle else { return }

        // 字符雨和 OK 都在“屏幕”里；屏幕的位置由边框那张图量出来。
        let screen = built?.screen ?? CGRect(x: glyph.minX, y: glyph.minY + Self.chinHeight,
                                             width: glyph.width, height: glyph.height - Self.chinHeight)
        // 指示灯：下巴左边 1pt 见方。
        led.isHidden = false
        led.frame = CGRect(x: glyph.minX + glyph.width * 0.2, y: glyph.minY + Self.chinHeight / 2 - 0.5, width: 1, height: 1)
        switch state {
        case .working:
            startRain(in: screen)
            let flicker = CAKeyframeAnimation(keyPath: "opacity")
            flicker.values = [1, 0.15, 1, 1, 0.15, 0.15, 1, 0.15]
            flicker.calculationMode = .discrete
            flicker.duration = 1.2
            flicker.repeatCount = .infinity
            led.add(flicker, forKey: "read")
        case .done:
            showOK(in: screen)
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
        // 1 像素笔画、居中放在屏幕正中：字 9×11 像素（外面描一圈 1 像素的半透明黑边），光标 2×11 像素。
        let pixel: CGFloat = 0.5
        let text = okImageSize
        let textWidth = CGFloat(text.width) * pixel, textHeight = CGFloat(text.height) * pixel
        let cursorWidth = 2 * pixel, gap = 1 * pixel
        let total = textWidth + gap + cursorWidth
        let left = area.midX - total / 2
        let bottom = area.midY - textHeight / 2
        okText.frame = CGRect(x: left, y: bottom, width: textWidth, height: textHeight)
        cursor.frame = CGRect(x: left + textWidth + gap, y: bottom + pixel, width: cursorWidth, height: 11 * pixel)
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1
        blink.repeatCount = .infinity
        cursor.add(blink, forKey: "blink")
        led.opacity = 1
    }

    private static let okImageSize = (width: 21, height: 13)
    private var okImageSize: (width: Int, height: Int) { Self.okImageSize }

    /// “OK” 的点阵图：每笔 1 像素，绿色，外面描一圈半透明黑边。字 9×11 像素，整张 21×13。
    private static func okImage() -> CGImage? {
        let (width, height) = okImageSize
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var pixels = Set<[Int]>()
        func add(_ letter: Int, _ column: Int, _ row: Int) { pixels.insert([1 + letter * 10 + column, 1 + (10 - row)]) }
        // O：圆角的框。
        for row in 0...10 { for column in 0...8 {
            let onBorder = row == 0 || row == 10 || column == 0 || column == 8
            let corner = (row == 0 || row == 10) && (column == 0 || column == 8)
            if onBorder && !corner { add(0, column, row) }
        } }
        // K：左边一竖，中间往右上、右下各一条斜线。
        for row in 0...10 { add(1, 0, row) }
        for row in 0...5 {
            let column = 1 + Int((Double(5 - row) * 7.0 / 5.0).rounded())
            add(1, column, row)
            add(1, column, 10 - row)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
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

    /// 老式 CRT 小电脑（经典 Macintosh）的外壳，盖在图标上，图标自己就是“屏幕里显示的内容”：
    /// - 机身：沿图标轮廓一圈 1 像素奶白色边；屏幕周围一圈浅奶白的边框；
    /// - 屏幕：四边一样的暗色细框（圆角，像显像管的玻璃边），里面一圈由深到浅的内阴影，左上角有一道弧形反光；
    /// - 下巴：底部 7 像素浅白色的一条，上面一笔软驱槽（指示灯另用一层，会闪）。
    /// 返回边框图和屏幕里面可以放内容的范围（pt，原点左下）。
    private static func screenFrame(of icon: CGImage) -> (image: CGImage, screen: CGRect)? {
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
        // 坐标 (x, y)：y 从画布底边往上数，和输出画布一致；内存里的行是从上往下的，这里换算一下。
        func solid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < w, y >= 0, y < h else { return false }
            return data[((h - 1 - y) * w + x) * 4 + 3] >= 128
        }
        func touchesEmpty(_ x: Int, _ y: Int) -> Bool {
            !solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1)
        }
        func plot(_ x: Int, _ y: Int, _ color: CGColor) {
            guard solid(x, y) else { return }
            output.setFillColor(color)
            output.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        // 图形实际的范围。
        guard let floor = (0..<h).first(where: { y in (0..<w).contains { solid($0, y) } }),
              let ceil = (0..<h).last(where: { y in (0..<w).contains { solid($0, y) } }) else { return nil }
        let midRow = (floor + ceil) / 2
        let xs = (0..<w).filter { solid($0, midRow) }
        guard let left = xs.first, let right = xs.last else { return nil }
        let chin = Int(chinHeight * 2)
        let bezel = 2

        // 屏幕：下巴上面、机身边框里面的圆角矩形。
        let x0 = left + bezel + 1, x1 = right - bezel - 1
        let y0 = floor + chin + bezel, y1 = ceil - bezel - 1
        let radius = 5
        func inside(_ x: Int, _ y: Int, inset: Int) -> Bool {
            let ax0 = x0 + inset, ax1 = x1 - inset, ay0 = y0 + inset, ay1 = y1 - inset
            guard x >= ax0, x <= ax1, y >= ay0, y <= ay1 else { return false }
            let r = max(radius - inset, 0)
            let dx = max(ax0 + r - x, 0, x - (ax1 - r)), dy = max(ay0 + r - y, 0, y - (ay1 - r))
            return dx * dx + dy * dy <= r * r
        }
        let cream = { (alpha: CGFloat) in CGColor(srgbRed: 0.93, green: 0.91, blue: 0.82, alpha: alpha) }

        for y in 0..<h {
            let t = CGFloat(y) / CGFloat(h - 1)
            for x in 0..<w where solid(x, y) {
                if y < floor + chin {
                    plot(x, y, cream(0.9))                                   // 下巴：浅白色
                } else if touchesEmpty(x, y) {
                    plot(x, y, cream(0.5 + 0.4 * t))                         // 机身外缘：上亮下暗
                } else if !inside(x, y, inset: 0) {
                    plot(x, y, cream(0.28 + 0.2 * t))                        // 屏幕周围的边框：淡淡的奶白
                } else if !inside(x, y, inset: 1) {
                    plot(x, y, CGColor(gray: 0.04, alpha: 0.85))             // 玻璃边：四边一样的暗色细框
                } else if !inside(x, y, inset: 2) {
                    plot(x, y, CGColor(gray: 0, alpha: 0.38))                // 内阴影，由深到浅
                } else if !inside(x, y, inset: 3) {
                    plot(x, y, CGColor(gray: 0, alpha: 0.24))
                } else if !inside(x, y, inset: 5) {
                    plot(x, y, CGColor(gray: 0, alpha: 0.12))
                }
            }
        }
        // 左上角的弧形反光：沿着内阴影里面一圈，越靠近角越亮，往两边渐隐。
        let glareReach = 26
        for y in y0...y1 {
            for x in x0...x1 where inside(x, y, inset: 4) && !inside(x, y, inset: 5) {
                let distance = (x - x0) + (y1 - y)
                guard distance < glareReach else { continue }
                plot(x, y, CGColor(gray: 1, alpha: 0.7 * (1 - CGFloat(distance) / CGFloat(glareReach))))
            }
        }
        // 反光的亮点：角里一小段斜线。
        for i in 0..<3 { plot(x0 + 9 + i, y1 - 9 - i, CGColor(gray: 1, alpha: 0.55)) }

        // 下巴上的软驱槽：右边一条 1 像素的线。
        let ink = CGColor(gray: 0.1, alpha: 0.75)
        let span = right - left
        let row = floor + chin / 2
        for x in (left + span * 11 / 20)...(left + span * 17 / 20) { plot(x, row, ink) }

        guard let image = output.makeImage() else { return nil }
        let screen = CGRect(x: CGFloat(x0 + 2) / 2, y: CGFloat(y0 + 2) / 2,
                            width: CGFloat(x1 - x0 - 3) / 2, height: CGFloat(y1 - y0 - 3) / 2)
        return (image, screen)
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
