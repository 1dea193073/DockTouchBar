import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 只在菜单栏显示，不占 Dock 图标（Info.plist 里的 LSUIElement 也是同样作用，这里兜底 swift run 的情况）。
app.setActivationPolicy(.accessory)
app.run()
