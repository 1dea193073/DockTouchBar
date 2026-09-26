import AppKit

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r, green: g, blue: b, alpha: a)
}

/// 长按退出提示的风格：像素画的四季，在菜单里切换，选择保存在 UserDefaults 的 `quitHintTheme`。
/// 文字、倒计时的排版四季都一样，换的是背景的像素场景、会动的角色、进度条的样子和飘落的粒子。
enum QuitHintTheme: String, CaseIterable {
    /// 草地上的小屋和烟囱里的炊烟；小狗沿着进度条跑，蝴蝶飞过，花瓣飘落。
    case spring
    /// 海面、棕榈岛、方块太阳；帆船沿着进度条开，海鸥飞过，浪一层层涌。
    case summer
    /// 落叶铺的地面、稻草人和南瓜；狐狸沿着进度条跑，候鸟飞过，红叶飘落。
    case autumn
    /// 结冰的地面、积雪的木屋和炊烟；雪橇沿着进度条滑，小鸟飞过，雪花飘落。
    case winter

    static let defaultsKey = "quitHintTheme"

    /// 读不到（或者是旧版本存的别的名字）就用春天。
    static var saved: QuitHintTheme {
        QuitHintTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .spring
    }

    var title: String {
        switch self {
        case .spring: return L10n.tr("春天", "Spring")
        case .summer: return L10n.tr("夏天", "Summer")
        case .autumn: return L10n.tr("秋天", "Autumn")
        case .winter: return L10n.tr("冬天", "Winter")
        }
    }
}

/// 一个季节的主色。
struct QuitHintLook {
    /// 铺在最底下的暗色（很深的季节色）。靠边缘几乎不透明，往中间渐渐透明，衬得住白字，也不会把 Dock 图标突然切断。
    var scrim: NSColor
    /// 靠边缘的一层辉光，随倒计时越来越亮。
    var glow: NSColor
    /// 倒计时走完时的闪光。
    var flash: NSColor
}

/// 一小幅像素画（一到几帧），每格 1pt。
struct QuitHintSprite {
    let frames: [CGImage]
    let size: CGSize
}

/// 原地动一动的小东西（太阳的光芒）。位置是离边缘多远、离底边多高。
struct QuitHintFixedActor {
    let sprite: QuitHintSprite
    let distance: CGFloat
    let y: CGFloat
    let frameDuration: TimeInterval
}

/// 场景里会动的角色。
struct QuitHintActors {
    /// 沿着进度条往前跑的角色。只有一帧的（帆船、雪橇）靠上下颠簸来动。
    var runner: QuitHintSprite
    var runnerFrameDuration: TimeInterval
    /// 跑的时候身后扬起来的东西（尘土、浪花、雪）的颜色。
    var trail: NSColor
    /// 在背景里飞过的小动物（蝴蝶、海鸥……）。
    var wanderer: QuitHintSprite
    var wandererY: CGFloat
    var wandererFrameDuration: TimeInterval
    var fixed: [QuitHintFixedActor] = []
    /// 烟囱口离边缘多远、离底边多高；没有烟囱就是 nil。
    var chimney: CGPoint?
    var smoke: NSColor
}

/// 在地面上一层层往里涌的东西（海浪），横向循环流动。
struct QuitHintFlow {
    let image: CGImage
    /// 图案的宽度（pt），流动一个周期刚好首尾相接。
    let period: CGFloat
    let y: CGFloat
    let height: CGFloat
    let duration: TimeInterval
}

extension QuitHintTheme {
    var look: QuitHintLook {
        switch self {
        case .spring:
            return QuitHintLook(scrim: rgb(0.03, 0.08, 0.05), glow: rgb(0.45, 0.95, 0.30), flash: rgb(0.85, 1, 0.70))
        case .summer:
            return QuitHintLook(scrim: rgb(0.02, 0.07, 0.13), glow: rgb(1, 0.85, 0.30), flash: rgb(1, 0.97, 0.75))
        case .autumn:
            return QuitHintLook(scrim: rgb(0.11, 0.05, 0.02), glow: rgb(1, 0.50, 0.12), flash: rgb(1, 0.85, 0.60))
        case .winter:
            return QuitHintLook(scrim: rgb(0.02, 0.06, 0.12), glow: rgb(0.55, 0.88, 1), flash: rgb(0.90, 0.97, 1))
        }
    }

    // MARK: - 美术

    /// 地面和贴边的主角（小屋、棕榈岛、稻草人、木屋），越往里越稀疏地“溶解”。
    func makeScene() -> CGImage? {
        var s = Canvas(columns: Scene.columns, rows: Scene.rows, seed: seed)
        switch self {
        case .spring: Scene.spring(&s)
        case .summer: Scene.summer(&s)
        case .autumn: Scene.autumn(&s)
        case .winter: Scene.winter(&s)
        }
        return s.image()
    }

    /// 背景远景：山丘、树、房子的剪影，宽度是 3 个周期，左右首尾相接，可以一直向后滚动。
    func makeFar() -> CGImage? {
        var s = Canvas(columns: Far.period * 3, rows: Scene.rows, seed: seed &+ 1)
        Far.draw(self, &s)
        return s.image()
    }

    /// 让远景和海浪只在靠边缘的一端可见、往里溶解的遮罩（透明度 0 或 1 的像素）。
    static func makeFadeMask() -> CGImage? {
        var s = Canvas(columns: Scene.columns, rows: Scene.rows, seed: 1)
        for x in 0..<Scene.columns {
            for y in 0..<Scene.rows where Scene.keeps(distance: Scene.columns - 1 - x, row: y) { s[x, y] = .white }
        }
        return s.image()
    }

    /// 进度条填充的花纹：上亮下暗的斜面，每隔几格一道缝，像像素游戏里的经验条、血条；每个季节的颜色和纹理不同。
    func makeBarPattern(width: Int) -> CGImage? {
        var s = Canvas(columns: width, rows: 3, seed: seed &+ 2)
        let segment = 6
        var base = rgb(0.42, 0.82, 0.22), high = rgb(0.66, 0.96, 0.42), low = rgb(0.22, 0.52, 0.12)
        for x in 0..<width {
            let inSegment = x % segment
            if inSegment == segment - 1 { continue }
            if inSegment == 0 {
                switch self {
                case .spring:
                    break
                case .summer:
                    base = rgb(0.25, 0.68, 0.95); high = rgb(0.55, 0.85, 1); low = rgb(0.12, 0.40, 0.75)
                case .autumn:
                    base = s.pick([rgb(0.95, 0.55, 0.15), rgb(0.82, 0.25, 0.12), rgb(0.95, 0.75, 0.25)])
                    high = base.blended(withFraction: 0.35, of: .white) ?? base
                    low = base.blended(withFraction: 0.4, of: .black) ?? base
                case .winter:
                    base = rgb(0.55, 0.85, 1); high = rgb(0.95, 1, 1); low = rgb(0.32, 0.62, 0.90)
                }
            }
            let sparkle = s.chance(0.1)
            s[x, 0] = low
            s[x, 1] = base
            s[x, 2] = high
            switch self {
            case .summer where inSegment == 1 || inSegment == 2: s[x, 2] = rgb(0.92, 0.98, 1)
            case .winter where sparkle: s[x, 1] = rgb(0.95, 1, 1)
            default: break
            }
        }
        return s.image()
    }

    /// 海面的浪：白色的浪尖，一层层往里涌。只有夏天有。
    func makeFlow() -> QuitHintFlow? {
        guard self == .summer else { return nil }
        var s = Canvas(columns: 24, rows: 1, seed: 7)
        for (x, alpha) in [(2, 0.9), (3, 1.0), (4, 0.9), (13, 0.8), (14, 0.95), (15, 0.95), (16, 0.8)] as [(Int, CGFloat)] {
            s[x, 0] = rgb(0.86, 0.96, 1, alpha)
        }
        guard let image = s.image() else { return nil }
        return QuitHintFlow(image: image, period: 24, y: 2, height: 1, duration: 2.4)
    }

    var actors: QuitHintActors {
        let colors = palette
        func sprite(_ frames: [[String]]) -> QuitHintSprite { Art.sprite(frames, colors) }
        switch self {
        case .spring:
            return QuitHintActors(
                runner: sprite([Art.dogA, Art.dogB]), runnerFrameDuration: 0.14, trail: rgb(0.78, 0.68, 0.48),
                wanderer: sprite([Art.butterflyA, Art.butterflyB]), wandererY: 20, wandererFrameDuration: 0.22,
                chimney: CGPoint(x: 4, y: 16), smoke: rgb(0.88, 0.88, 0.92))
        case .summer:
            return QuitHintActors(
                runner: sprite([Art.boat]), runnerFrameDuration: 0.4, trail: rgb(0.92, 0.98, 1),
                wanderer: sprite([Art.birdA, Art.birdB]), wandererY: 22, wandererFrameDuration: 0.25,
                fixed: [QuitHintFixedActor(sprite: sprite([Art.sunA, Art.sunB]), distance: 3, y: 20, frameDuration: 0.5)],
                chimney: nil, smoke: .white)
        case .autumn:
            return QuitHintActors(
                runner: sprite([Art.foxA, Art.foxB]), runnerFrameDuration: 0.14, trail: rgb(0.95, 0.55, 0.2),
                wanderer: sprite([Art.birdA, Art.birdB]), wandererY: 22, wandererFrameDuration: 0.25,
                chimney: nil, smoke: .white)
        case .winter:
            return QuitHintActors(
                runner: sprite([Art.sleigh]), runnerFrameDuration: 0.4, trail: rgb(0.95, 0.98, 1),
                wanderer: sprite([Art.birdA, Art.birdB]), wandererY: 22, wandererFrameDuration: 0.25,
                chimney: CGPoint(x: 5, y: 15), smoke: rgb(0.92, 0.95, 1))
        }
    }

    /// 每个季节自己的一套颜色，字符对应下面各个小画里的字符。
    fileprivate var palette: [Character: NSColor] {
        switch self {
        case .spring:
            return ["B": rgb(0.80, 0.54, 0.30), "D": rgb(0.45, 0.28, 0.14), "T": rgb(0.62, 0.40, 0.22), "K": rgb(0.10, 0.08, 0.08),
                    "W": rgb(0.97, 0.93, 0.86), "P": rgb(1, 0.62, 0.78), "b": rgb(0.35, 0.30, 0.30),
                    "R": rgb(0.72, 0.27, 0.22), "r": rgb(0.88, 0.42, 0.32), "H": rgb(0.94, 0.86, 0.68), "h": rgb(0.78, 0.68, 0.50),
                    "G": rgb(0.55, 0.82, 0.96), "C": rgb(0.56, 0.50, 0.50), "c": rgb(0.38, 0.33, 0.33)]
        case .summer:
            return ["M": rgb(0.55, 0.38, 0.22), "W": rgb(0.97, 0.97, 0.95), "w": rgb(0.82, 0.88, 0.92), "R": rgb(0.95, 0.25, 0.25),
                    "H": rgb(0.62, 0.36, 0.18), "h": rgb(0.42, 0.24, 0.12),
                    "G": rgb(0.25, 0.62, 0.28), "g": rgb(0.16, 0.46, 0.22), "T": rgb(0.58, 0.40, 0.22), "S": rgb(0.92, 0.80, 0.50),
                    "Y": rgb(1, 0.86, 0.30), "O": rgb(1, 0.62, 0.14), "X": rgb(1, 0.97, 0.75),
                    "A": rgb(0.95, 0.95, 0.98), "a": rgb(0.70, 0.72, 0.78)]
        case .autumn:
            return ["O": rgb(0.92, 0.50, 0.16), "W": rgb(0.97, 0.93, 0.86), "K": rgb(0.12, 0.08, 0.06), "T": rgb(0.96, 0.96, 0.92),
                    "P": rgb(0.92, 0.50, 0.08), "p": rgb(0.68, 0.32, 0.05), "g": rgb(0.30, 0.62, 0.18),
                    "Y": rgb(0.92, 0.78, 0.32), "y": rgb(0.72, 0.56, 0.20), "B": rgb(0.55, 0.32, 0.16),
                    "R": rgb(0.75, 0.22, 0.16), "r": rgb(0.55, 0.14, 0.10), "L": rgb(0.50, 0.30, 0.14), "F": rgb(0.95, 0.62, 0.40),
                    "A": rgb(0.80, 0.84, 0.94), "a": rgb(0.60, 0.64, 0.76)]
        case .winter:
            return ["W": rgb(0.97, 0.98, 1), "w": rgb(0.78, 0.88, 0.96), "R": rgb(0.80, 0.16, 0.16), "r": rgb(0.58, 0.10, 0.12),
                    "G": rgb(0.28, 0.62, 0.36), "Y": rgb(0.96, 0.80, 0.32), "B": rgb(0.50, 0.32, 0.18), "b": rgb(0.36, 0.22, 0.12),
                    "F": rgb(0.96, 0.70, 0.55), "C": rgb(0.55, 0.55, 0.62), "c": rgb(0.38, 0.33, 0.33), "L": rgb(1, 0.86, 0.42),
                    "A": rgb(0.92, 0.27, 0.27), "a": rgb(0.70, 0.16, 0.16)]
        }
    }

    /// 远景滚动一个周期是多宽（pt）。
    static var farPeriod: CGFloat { CGFloat(Far.period) }

    fileprivate var seed: UInt64 {
        switch self {
        case .spring: return 11
        case .summer: return 23
        case .autumn: return 37
        case .winter: return 53
        }
    }

    // MARK: - 粒子（都是方形的小像素）

    /// 角色身后扬起来的粒子（跟着角色走）。
    func trailCells() -> [CAEmitterCell] {
        let color = actors.trail
        return [cell {
            $0.birthRate = 12
            $0.lifetime = 0.5; $0.lifetimeRange = 0.2
            $0.velocity = 10; $0.velocityRange = 5
            $0.emissionLongitude = .pi - 0.5; $0.emissionRange = 0.6
            $0.scale = 0.4; $0.scaleRange = 0.15
            $0.alphaSpeed = -1.8
            $0.color = color.cgColor
        }]
    }

    /// 飘在背景里的粒子：花瓣、落叶、雪；夏天没有。
    /// 在面板里面（地面上方）生成，先从很小长到正常大小，再一边漂一边淡出，不会落到地面上，也不是从顶上掉下来的。
    func ambientCells() -> [CAEmitterCell] {
        func drifting(_ color: NSColor, rate: Float, lifetime: Float, speed: CGFloat, direction: CGFloat) -> CAEmitterCell {
            cell {
                $0.birthRate = rate
                $0.lifetime = lifetime; $0.lifetimeRange = 0.5
                $0.velocity = speed; $0.velocityRange = speed / 3
                $0.emissionLongitude = direction; $0.emissionRange = 0.4
                $0.scale = 0.35; $0.scaleRange = 0.1; $0.scaleSpeed = 0.2
                $0.alphaSpeed = -0.95 / lifetime
                $0.color = color.cgColor
            }
        }
        switch self {
        case .spring:
            return [drifting(rgb(1, 0.72, 0.84), rate: 8, lifetime: 2.4, speed: 7, direction: -.pi / 2 - 0.6)]
        case .summer:
            return []
        case .autumn:
            return [rgb(0.95, 0.50, 0.10), rgb(0.85, 0.25, 0.12), rgb(0.95, 0.75, 0.20)].map {
                drifting($0, rate: 2.4, lifetime: 2.4, speed: 8, direction: -.pi / 2 - 0.8)
            }
        case .winter:
            return [drifting(rgb(0.95, 0.98, 1), rate: 10, lifetime: 2.6, speed: 6, direction: -.pi / 2)]
        }
    }

    /// 在地面上原地一闪一闪的光点（海面的波光、冰面的反光）；春秋没有。
    func glintCells() -> [CAEmitterCell] {
        switch self {
        case .summer, .winter:
            return [cell {
                $0.birthRate = 3
                $0.lifetime = 0.6; $0.lifetimeRange = 0.3
                $0.velocity = 0
                $0.scale = 0.4; $0.scaleRange = 0.1
                $0.alphaSpeed = -1.6
                $0.color = rgb(0.95, 0.99, 1).cgColor
            }]
        case .spring, .autumn:
            return []
        }
    }

    /// 烟囱里冒出来的烟：慢慢往上飘、变大、变淡。
    func smokeCells() -> [CAEmitterCell] {
        let actors = self.actors
        guard actors.chimney != nil else { return [] }
        return [cell {
            $0.birthRate = 3
            $0.lifetime = 2.2; $0.lifetimeRange = 0.4
            $0.velocity = 7; $0.velocityRange = 2
            $0.emissionLongitude = .pi / 2 - 0.15; $0.emissionRange = 0.3
            $0.scale = 0.3; $0.scaleSpeed = 0.14
            $0.alphaSpeed = -0.4
            $0.color = actors.smoke.withAlphaComponent(0.75).cgColor
        }]
    }

    private func cell(_ configure: (CAEmitterCell) -> Void) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = Art.square
        cell.contentsScale = 2
        configure(cell)
        return cell
    }
}

// MARK: - 画布

/// 一块像素画布：`x` 从左往右、`y` 从下往上，每格 1pt（导出成图片时占 2×2 像素，Retina 屏上刚好一格一个像素点）。
private struct Canvas {
    static let scale = 2

    let columns: Int
    let rows: Int
    private var pixels: [NSColor?]
    private var state: UInt64

    init(columns: Int, rows: Int, seed: UInt64) {
        self.columns = columns
        self.rows = rows
        pixels = [NSColor?](repeating: nil, count: columns * rows)
        state = seed &* 0x9E3779B97F4A7C15 | 1
    }

    subscript(x: Int, y: Int) -> NSColor? {
        get { inBounds(x, y) ? pixels[y * columns + x] : nil }
        set { if inBounds(x, y) { pixels[y * columns + x] = newValue } }
    }

    private func inBounds(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < columns && y >= 0 && y < rows }

    mutating func random() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0x1000000)
    }

    mutating func chance(_ p: CGFloat) -> Bool { random() < p }

    mutating func pick(_ colors: [NSColor]) -> NSColor { colors[Int(random() * CGFloat(colors.count)) % colors.count] }

    /// 明暗各浮动一点点，让大片的同色格子有质感。
    mutating func shade(_ color: NSColor, _ amount: CGFloat = 0.1) -> NSColor {
        let k = 1 + (random() - 0.5) * 2 * amount
        return NSColor(red: min(color.redComponent * k, 1), green: min(color.greenComponent * k, 1),
                       blue: min(color.blueComponent * k, 1), alpha: 1)
    }

    /// 把一小幅字符画贴上去：`art` 第一行在最上面，`.` 是空的；`(x, y)` 是左下角。
    mutating func stamp(_ art: [String], x: Int, y: Int, palette: [Character: NSColor]) {
        for (i, line) in art.enumerated() {
            for (j, ch) in line.enumerated() {
                guard let color = palette[ch] else { continue }
                self[x + j, y + art.count - 1 - i] = color
            }
        }
    }

    func image() -> CGImage? {
        let s = Self.scale
        guard let context = CGContext(data: nil, width: columns * s, height: rows * s, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for x in 0..<columns {
            for y in 0..<rows {
                guard let color = self[x, y] else { continue }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x * s, y: y * s, width: s, height: s))
            }
        }
        return context.makeImage()
    }
}

// MARK: - 场景

/// 一幅贴边的像素画：最下面直接是地面（只有几格厚），贴着边缘一个主角，再往里越来越稀疏。
private enum Scene {
    static let columns = Int(QuitHintView.width)
    static let rows = Int(QuitHintView.height)
    /// 地面最上面一格往上的高度，进度条就坐在它上面。
    static let groundTop = 3

    private static let bayer: [[CGFloat]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        .map { $0.map { ($0 + 0.5) / 16 } }

    /// 这一格要不要画：离边缘 `distance` 格。边缘处全画，到面板的 80% 处一格都不画，中间按 4×4 的抖动图案逐渐变稀。
    /// 按 2×2 一块来判断，溶解出来的是一块一块的方块。
    static func keeps(distance: Int, row: Int) -> Bool {
        let density = max(0, 1 - CGFloat(distance / 2) * 2 / (0.8 * QuitHintView.width))
        return density > bayer[(row / 2) % 4][(distance / 2) % 4]
    }

    /// 在 `rows` 这几行里铺色：每格从 `colors` 里随机挑一种，按 `probability` 的概率出现，越往里越稀疏。
    static func band(_ s: inout Canvas, _ rows: ClosedRange<Int>, _ colors: [NSColor], probability: CGFloat = 1) {
        for x in 0..<s.columns {
            for row in rows {
                guard keeps(distance: s.columns - 1 - x, row: row), probability >= 1 || s.chance(probability) else { continue }
                s[x, row] = s.shade(s.pick(colors))
            }
        }
    }

    /// 贴着边缘放一幅小画：`offset` 是它最靠边的一列离边缘多少格。
    static func hero(_ s: inout Canvas, _ art: [String], offset: Int, row: Int, palette: [Character: NSColor]) {
        s.stamp(art, x: s.columns - offset - (art.first?.count ?? 0), y: row, palette: palette)
    }

    /// 草地：泥土、青草、零星草叶和几朵小花（花头露在进度条上面）；贴边一间带烟囱的小屋。
    static func spring(_ s: inout Canvas) {
        let palette = QuitHintTheme.spring.palette
        band(&s, 0...0, [rgb(0.30, 0.20, 0.12), rgb(0.26, 0.17, 0.10)])
        band(&s, 1...1, [rgb(0.30, 0.20, 0.12), rgb(0.30, 0.62, 0.19)])
        band(&s, 2...2, [rgb(0.30, 0.64, 0.19), rgb(0.26, 0.58, 0.17)])
        band(&s, 3...3, [rgb(0.38, 0.74, 0.24)], probability: 0.3)
        let colors: [Character: NSColor] = ["P": rgb(1, 0.62, 0.78), "Y": rgb(1, 0.86, 0.3), "R": rgb(0.92, 0.25, 0.25),
                                            "f": rgb(1, 0.95, 0.6), "g": rgb(0.25, 0.55, 0.16)]
        for (distance, head) in [(46, "P"), (72, "Y"), (104, "R"), (140, "P")] {
            hero(&s, [".\(head).", "\(head)f\(head)", ".g.", ".g.", ".g.", ".g.", ".g."], offset: distance, row: groundTop, palette: colors)
        }
        hero(&s, Art.cottage, offset: 0, row: groundTop, palette: palette)
    }

    /// 海面：深浅蓝的水（浪尖由会流动的一层单独画）；贴边一座长着棕榈树的小沙岛。
    static func summer(_ s: inout Canvas) {
        let palette = QuitHintTheme.summer.palette
        band(&s, 0...0, [rgb(0.08, 0.30, 0.62), rgb(0.10, 0.34, 0.68)])
        band(&s, 1...1, [rgb(0.16, 0.46, 0.82)])
        band(&s, 2...2, [rgb(0.30, 0.62, 0.92), rgb(0.26, 0.58, 0.90)])
        hero(&s, Art.palm, offset: 0, row: 0, palette: palette)
    }

    /// 落叶：深色的泥土上铺着橙、红、金、褐的叶子；贴边一个稻草人和一个南瓜。
    static func autumn(_ s: inout Canvas) {
        let palette = QuitHintTheme.autumn.palette
        let leaves = [rgb(0.85, 0.42, 0.10), rgb(0.72, 0.20, 0.10), rgb(0.90, 0.65, 0.15), rgb(0.50, 0.30, 0.12)]
        band(&s, 0...0, [rgb(0.26, 0.15, 0.08), rgb(0.22, 0.13, 0.07)])
        band(&s, 1...2, leaves)
        band(&s, 3...3, leaves, probability: 0.35)
        hero(&s, Art.pumpkin, offset: 0, row: groundTop, palette: palette)
        hero(&s, Art.scarecrow, offset: 5, row: groundTop, palette: palette)
    }

    /// 冰面：深浅两层冰、反光，上面薄薄一层积雪；贴边一间落满雪的木屋。
    static func winter(_ s: inout Canvas) {
        let palette = QuitHintTheme.winter.palette
        band(&s, 0...0, [rgb(0.14, 0.32, 0.60), rgb(0.17, 0.37, 0.66)])
        band(&s, 1...1, [rgb(0.55, 0.82, 0.96), rgb(0.50, 0.78, 0.94)])
        for x in 0..<s.columns where keeps(distance: s.columns - 1 - x, row: 1) && s.chance(0.14) { s[x, 1] = rgb(0.93, 0.99, 1) }
        band(&s, 2...2, [rgb(0.93, 0.97, 1), rgb(0.85, 0.93, 1)], probability: 0.85)
        band(&s, 3...3, [rgb(0.93, 0.97, 1)], probability: 0.4)
        hero(&s, Art.cabin, offset: 0, row: groundTop, palette: palette)
    }
}

// MARK: - 远景

/// 背景远景：很暗的剪影，比正景暗得多，贴在文字后面只当个纵深。宽度是 3 个周期，任意错开一个周期都首尾相接。
private enum Far {
    static let period = 220

    /// 一条周期为 `period` 的起伏曲线：几个整数倍频率的正弦叠加，0…1。
    private static func wave(_ x: Int, _ terms: [(frequency: Int, phase: CGFloat)]) -> CGFloat {
        let sum = terms.reduce(CGFloat(0)) { $0 + 0.5 + 0.5 * sin(2 * .pi * CGFloat($1.frequency * x) / CGFloat(period) + $1.phase) }
        return sum / CGFloat(terms.count)
    }

    private static func hills(_ s: inout Canvas, color: NSColor, base: Int, amplitude: CGFloat, terms: [(frequency: Int, phase: CGFloat)]) -> [Int] {
        var tops = [Int]()
        for x in 0..<s.columns {
            let top = Scene.groundTop + base + Int((amplitude * wave(x, terms)).rounded())
            tops.append(top)
            for y in Scene.groundTop...top { s[x, y] = s.shade(color, 0.05) }
        }
        return tops
    }

    /// 在每个周期的 `positions` 处放一个剪影，脚踩在 `tops` 给的高度上（下沉一格，不悬空）。
    private static func place(_ s: inout Canvas, _ art: [String], at positions: [Int], on tops: [Int], palette: [Character: NSColor]) {
        for k in 0..<3 {
            for p in positions {
                let x = k * period + p
                guard x < s.columns else { continue }
                s.stamp(art, x: x, y: tops[x] - 1, palette: palette)
            }
        }
    }

    static func draw(_ theme: QuitHintTheme, _ s: inout Canvas) {
        switch theme {
        case .spring:
            _ = hills(&s, color: rgb(0.07, 0.20, 0.09), base: 3, amplitude: 5, terms: [(2, 0.5), (5, 1.7)])
            let tops = hills(&s, color: rgb(0.10, 0.27, 0.12), base: 1, amplitude: 4, terms: [(3, 2.1), (7, 0.3)])
            place(&s, Art.smallTree, at: [24, 71, 118, 176], on: tops, palette: ["S": rgb(0.07, 0.22, 0.10)])
        case .summer:
            let land = rgb(0.06, 0.22, 0.32)
            for (center, width, height) in [(44, 26, 4), (150, 34, 6)] {
                for x in (center - width / 2)...(center + width / 2) {
                    let t = CGFloat(x - center) / CGFloat(width / 2)
                    let h = Int(CGFloat(height) * (1 - t * t).squareRoot())
                    for k in 0..<3 where x + k * period < s.columns {
                        for y in Scene.groundTop..<(Scene.groundTop + h) { s[x + k * period, y] = land }
                    }
                }
            }
            let water = [Int](repeating: Scene.groundTop + 1, count: s.columns)
            place(&s, Art.smallPalm, at: [40, 146, 158], on: water.map { $0 + 3 }, palette: ["S": rgb(0.06, 0.26, 0.28)])
            place(&s, Art.smallBoat, at: [92, 198], on: water, palette: ["S": rgb(0.36, 0.50, 0.62)])
        case .autumn:
            _ = hills(&s, color: rgb(0.23, 0.11, 0.05), base: 3, amplitude: 5, terms: [(2, 1.1), (5, 0.4)])
            let tops = hills(&s, color: rgb(0.30, 0.14, 0.06), base: 1, amplitude: 4, terms: [(3, 0.2), (6, 2.4)])
            place(&s, Art.smallTree, at: [26, 78, 170, 204], on: tops, palette: ["S": rgb(0.42, 0.20, 0.06)])
            place(&s, Art.smallBarn, at: [118], on: tops, palette: ["S": rgb(0.36, 0.11, 0.08), "L": rgb(1, 0.75, 0.3)])
        case .winter:
            let tops = hills(&s, color: rgb(0.12, 0.22, 0.40), base: 2, amplitude: 9, terms: [(2, 0.9), (4, 2.6), (9, 0.4)])
            for x in 0..<s.columns where tops[x] > Scene.groundTop + 8 {
                for y in (tops[x] - 1)...tops[x] { s[x, y] = rgb(0.40, 0.55, 0.78) }
            }
            let ground = [Int](repeating: Scene.groundTop + 1, count: s.columns)
            place(&s, Art.smallPine, at: [16, 58, 138, 172], on: ground, palette: ["S": rgb(0.05, 0.20, 0.20)])
            place(&s, Art.smallHouse, at: [92, 200], on: ground, palette: ["S": rgb(0.20, 0.16, 0.30), "L": rgb(1, 0.8, 0.35)])
        }
    }
}

// MARK: - 像素小画

/// 每个小画是一组字符串，第一行在最上面，`.` 是空的；字符对应哪个颜色由各季节的 `palette` 决定。
private enum Art {
    static func sprite(_ frames: [[String]], _ palette: [Character: NSColor]) -> QuitHintSprite {
        let width = frames.map { $0.map(\.count).max() ?? 0 }.max() ?? 0
        let height = frames.map(\.count).max() ?? 0
        let images = frames.compactMap { frame -> CGImage? in
            var s = Canvas(columns: width, rows: height, seed: 1)
            s.stamp(frame, x: 0, y: height - frame.count, palette: palette)
            return s.image()
        }
        return QuitHintSprite(frames: images, size: CGSize(width: width, height: height))
    }

    /// 一块纯白的小方块，用粒子的颜色染色。
    static let square: CGImage? = {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()
    }()

    // 春
    static let dogA = [
        "........DD..",
        "T.......DBK.",
        "TTBBBBBBBBBK",
        ".TBBBBBBBBWW",
        "..BBBBBBBBW.",
        ".BB......BB.",
        "BB........BB",
    ]
    static let dogB = [
        "........DD..",
        "T.......DBK.",
        "TTBBBBBBBBBK",
        ".TBBBBBBBBWW",
        "..BBBBBBBBW.",
        "...BB...BB..",
        "...BB...BB..",
    ]
    static let butterflyA = ["PW.WP", "PWbWP", ".PbP.", "..b.."]
    static let butterflyB = [".....", "..W..", "..b..", "..b.."]
    static let cottage = [
        "...........cc...",
        "...........CC...",
        ".......rr..CC...",
        "......rRRr.CC...",
        ".....rRRRRrRR...",
        "....rRRRRRRRRr..",
        "...rRRRRRRRRRRr.",
        "..rRRRRRRRRRRRRr",
        "..HHHHHHHHHHHHH.",
        "..HGGHHHHHHDDH..",
        "..HGGHHHHHHDDH..",
        "..HHHHHHHHHDDH..",
        "..hhhhhhhhhhhh..",
    ]

    // 夏
    static let boat = [
        ".....R.....",
        ".....MW....",
        ".....MWW...",
        ".....MWWW..",
        ".....MWWWw.",
        ".....MWWWww",
        "HHHHHHHHHHH",
        ".hHHHHHHHh.",
    ]
    static let birdA = ["A.....A", ".A...A.", "..AAA.."]
    static let birdB = ["..AAA..", ".A...A.", "A.....A"]
    static let palm = [
        "......GGGG......",
        "...GGGGggGGGG...",
        "..GGG.GGGG.GGG..",
        ".GG...GTTG...GG.",
        "GG....GTT.....GG",
        "g......TT......g",
        ".......TT.......",
        ".......TT.......",
        ".......T........",
        ".......T........",
        ".......TT.......",
        "......TT........",
        "......TT........",
        ".....SSSSSS.....",
        "..SSSSSSSSSSSS..",
        "SSSSSSSSSSSSSSSS",
    ]
    static let sunA = [
        "...O....",
        ".OOYYOO.",
        ".OYXXYO.",
        "OYXXXXYO",
        ".OYXXYO.",
        ".OOYYOO.",
        "...O....",
        "........",
    ]
    static let sunB = [
        "O..O..O.",
        ".OOYYOO.",
        ".OYXXYO.",
        "OYXXXXYO",
        ".OYXXYO.",
        ".OOYYOO.",
        "O..O..O.",
        "........",
    ]

    // 秋
    static let foxA = [
        "..........O.O",
        "..........OOO",
        "TTOOOOOOOOOOK",
        "TOOOOOOOOOWW.",
        ".OOOOOOOOOW..",
        ".OK.....KO...",
        "KK.......KK..",
    ]
    static let foxB = [
        "..........O.O",
        "..........OOO",
        "TTOOOOOOOOOOK",
        "TOOOOOOOOOWW.",
        ".OOOOOOOOOW..",
        "..OK...OK....",
        "..KK...KK....",
    ]
    static let pumpkin = ["..g..", ".pPp.", "pPPPp", "pPpPp", ".pPp."]
    static let scarecrow = [
        "....BBBB....",
        "...BBBBBB...",
        ".BBBBBBBBBB.",
        "....FFFF....",
        "....FKFK....",
        "....FFFF....",
        ".YYYYRRRYYYY",
        "Y..YRRRRY..Y",
        "y..yRrRRy..y",
        "...yRRRRy...",
        "....RrRR....",
        ".....LL.....",
        ".....LL.....",
        ".....LL.....",
        ".....LL.....",
    ]

    // 冬
    static let sleigh = [
        "......W.....",
        ".....RRR....",
        ".GG..FFR....",
        ".GG.RRRRRRR.",
        "RRRRRRRRRRRR",
        ".rrrrrrrrrrY",
        "YYYYYYYYYYYY",
    ]
    static let cabin = [
        "..........cC....",
        ".........CCC....",
        "......WWWCCWW...",
        ".....WWWWWWWWW..",
        "....WwWWWWWWWwW.",
        "...WWWWWWWWWWWWW",
        "..BBBBBBBBBBBBB.",
        "..bBBBBBBBBBBBb.",
        "..BBLLBBBBBDDBB.",
        "..bBLLBBBBBDDBb.",
        "..BBBBBBBBBDDBB.",
        "..bbbbbbbbbbbbb.",
    ]

    // 远景剪影（S 是本体，L 是亮着的窗）
    static let smallTree = [".SSS.", "SSSSS", "SSSSS", ".SSS.", "..S..", "..S..", "..S.."]
    static let smallPine = ["..S..", "..S..", ".SSS.", "..S..", ".SSS.", "SSSSS", "..S..", "..S.."]
    static let smallHouse = ["..SSS..", ".SSSSS.", "SSSSSSS", "SSLSSLS", "SSSSSSS", "SSSSSSS"]
    static let smallBarn = ["..SSSSSS..", ".SSSSSSSS.", "SSSSSSSSSS", "SSSLLSSSSS", "SSSSSSSSSS", "SSSSSSSSSS", "SSSSSSSSSS"]
    static let smallPalm = ["SS.SS", ".SSS.", "..S..", "..S..", "..S.."]
    static let smallBoat = ["..S..", "..SS.", "..SSS", "SSSSS", ".SSS."]
}
