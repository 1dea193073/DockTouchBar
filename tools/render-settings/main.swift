// 离屏渲染设置窗口里的“配对智能体”页成 PNG，检查界面用（不打开真的窗口，不受 Stage Manager 影响）。
// 由 tools/render-settings.sh 编译运行。
import AppKit
import SwiftUI

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "settings.png"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = NSHostingView(rootView: PairingPage().frame(width: 500, height: 700).environment(\.colorScheme, .dark))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
window.contentView = host
window.setFrameOrigin(NSPoint(x: -2000, y: 0))
window.orderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
    print("Wrote \(output)")
    exit(0)
}
app.run()
