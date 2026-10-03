import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 程序坞里有图标，装好后从程序坞或启动台点一下就能打开菜单；同时保留菜单栏图标。
app.setActivationPolicy(.regular)
app.run()
