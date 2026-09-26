// 列出每块屏幕的桌面，以及每个前台 App 的窗口在哪个桌面。只读，不会切换任何东西。
// 用法：swift tools/inspect-spaces.swift
// 排查“点了图标没切到对应桌面”时用：看目标 App 的窗口是否有桌面编号（最小化的窗口没有）。
import AppKit

typealias MainConnectionFn = @convention(c) () -> Int32
typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
guard let mainSym = dlsym(skyLight, "SLSMainConnectionID"), let activeSym = dlsym(skyLight, "SLSGetActiveSpace"),
      let displaysSym = dlsym(skyLight, "SLSCopyManagedDisplaySpaces"), let spacesSym = dlsym(skyLight, "SLSCopySpacesForWindows") else {
    print("找不到 SkyLight 接口"); exit(1)
}
let connection = unsafeBitCast(mainSym, to: MainConnectionFn.self)()
let activeSpace = unsafeBitCast(activeSym, to: ActiveSpaceFn.self)(connection)
let copySpaces = unsafeBitCast(spacesSym, to: CopySpacesFn.self)

print("== 桌面（当前桌面编号 \(activeSpace)）")
let displays = unsafeBitCast(displaysSym, to: CopyDisplaySpacesFn.self)(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
for display in displays {
    let spaces = (display["Spaces"] as? [[String: Any]] ?? []).enumerated()
        .map { "桌面\($0.offset + 1)=\($0.element["id64"] ?? "?")" }
    print("屏幕 \(display["Display Identifier"] ?? "?")：", spaces.joined(separator: "  "))
}

print("\n== 窗口（on = 在当前桌面可见；spaces 为空 = 最小化或辅助窗口）")
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let own = windows.compactMap { info -> String? in
        guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              info[kCGWindowLayer as String] as? Int == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              (bounds["Width"] ?? 0) > 50, (bounds["Height"] ?? 0) > 50,
              let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
        let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) == true
        let spaces = copySpaces(connection, 0x7, [id] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
        return "#\(id) \(onscreen ? "on" : "off") spaces=\(spaces)"
    }
    print("\(app.localizedName ?? "?")\(app.isHidden ? "（已隐藏）" : "")：", own.isEmpty ? "无窗口" : own.joined(separator: "  "))
}
