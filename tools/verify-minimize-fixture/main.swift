import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 250, y: 230, width: 640, height: 360), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "DockTouchBar — minimize verification"
window.isReleasedWhenClosed = false
window.contentView = NSTextField(labelWithString: "Temporary test window")
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
func onScreen() -> Bool {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return infos.contains { $0[kCGWindowNumber as String] as? Int == window.windowNumber }
}
func frame() -> [String: CGFloat] {
    let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
    return infos.first { $0[kCGWindowNumber as String] as? Int == window.windowNumber }?[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let originalFrame = frame()
    window.miniaturize(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let nativeMinimized = window.isMiniaturized
        let nativeOnScreen = onScreen()
        let nativeFrame = frame()
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let data: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber, "nativeMinimized": nativeMinimized, "nativeOnScreen": nativeOnScreen, "nativeFrame": nativeFrame, "originalFrame": originalFrame]
            try! JSONSerialization.data(withJSONObject: data).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { app.terminate(nil) }
app.run()
