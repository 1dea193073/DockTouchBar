// 由 tools/diagnose-switch.sh 编译运行。只读：只查询窗口和辅助功能属性，不切换任何东西。
import AppKit

typealias MainConn = @convention(c) () -> Int32
typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
guard let mainSym = dlsym(skyLight, "SLSMainConnectionID"), let spacesSym = dlsym(skyLight, "SLSCopySpacesForWindows"),
      let activeSym = dlsym(skyLight, "SLSGetActiveSpace") else { print("找不到 SkyLight 接口"); exit(1) }
let connection = unsafeBitCast(mainSym, to: MainConn.self)()
let copySpaces = unsafeBitCast(spacesSym, to: CopySpaces.self)
func spaces(of window: CGWindowID) -> [UInt64] {
    copySpaces(connection, 0x7, [window] as CFArray)?.takeRetainedValue() as? [UInt64] ?? []
}
func attribute(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value as? String ?? "-"
}

print("辅助功能权限: \(AXIsProcessTrusted() ? "有" : "没有（没有权限时程序不会跨桌面切换）")")
print("当前桌面 id: \(unsafeBitCast(activeSym, to: ActiveSpace.self)(connection))")
let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

for bundleID in CommandLine.arguments.dropFirst() {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        print("\n=== \(bundleID)：没有在运行"); continue
    }
    let pid = app.processIdentifier
    print("\n=== \(app.localizedName ?? bundleID)  pid \(pid)  \(app.isHidden ? "已隐藏" : "未隐藏")")
    print("  全部窗口（按前后顺序；“在屏”=当前桌面上看得见）：")
    for info in all where info[kCGWindowOwnerPID as String] as? pid_t == pid {
        let id = info[kCGWindowNumber as String] as! CGWindowID
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) == true
        print(String(format: "    #%-6d 层%-4d %@ %4.0f×%-4.0f 桌面 %@", id, info[kCGWindowLayer as String] as? Int ?? -1,
                     onscreen ? "在屏" : "不在", bounds["Width"] ?? 0, bounds["Height"] ?? 0, "\(spaces(of: id))"))
    }
    let space = AppSwitcher.effectiveSpace()
    let candidates = AppSwitcher.windowsToRaise(of: pid)
    if candidates.isEmpty {
        print("  ▶ 程序的判断：没有属于任何桌面的窗口（可能都最小化了），会走普通的打开/激活。")
        continue
    }
    print("  候选窗口（先是在当前桌面 \(space.map(String.init) ?? "?") 上的，再是别的桌面上的；最多试前 4 个）：")
    var chosen: CGWindowID?
    var fallback: CGWindowID?
    for window in candidates.prefix(4) {
        let onSpaces = spaces(of: window)
        let where_ = onSpaces.contains(space ?? 0) ? "当前桌面" : "别的桌面（要切过去）"
        guard let element = AppSwitcher.axWindow(pid: pid, window: window) else {
            print("    #\(window) 桌面\(onSpaces) \(where_)  辅助功能找不到它 → 跳过"); continue
        }
        let strict = AppSwitcher.isRealWindow(element, strict: true)
        let lenient = AppSwitcher.isRealWindow(element)
        let verdict = strict ? "真实窗口（标准类型，优先）" : lenient ? "窗口，但类型特殊（只在没有标准窗口时才用）" : "不是真实窗口，跳过"
        print("    #\(window) 桌面\(onSpaces) \(where_)  role=\(attribute(element, kAXRoleAttribute)) subrole=\(attribute(element, kAXSubroleAttribute)) → \(verdict)")
        if strict && chosen == nil { chosen = window }
        if lenient && !strict && fallback == nil { fallback = window }
    }
    print("  ▶ 程序会去提前：\((chosen ?? fallback).map { "#\($0)" } ?? "没有可用的真实窗口，退回普通激活（这时点击不会切桌面）")")
}
