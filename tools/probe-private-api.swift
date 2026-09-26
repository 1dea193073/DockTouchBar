// 检查当前 macOS 上 DockTouchBar 用到的私有接口还在不在，以及相关的系统设置。只读，不改任何东西。
// 用法：swift tools/probe-private-api.swift
// 系统大版本更新后先跑一次：任何一项是 ✗，对应功能就会自动关闭（App 不会崩）。
import AppKit

func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

print("== 系统")
let version = ProcessInfo.processInfo.operatingSystemVersion
var model = [CChar](repeating: 0, count: 64)
var modelSize = model.count
sysctlbyname("hw.model", &model, &modelSize, nil, 0)
print("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)，机型 \(String(cString: model))")

print("\n== Touch Bar 常驻显示（TouchBarBridge.swift）")
let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
for name in ["DFRElementSetControlStripPresenceForIdentifier", "DFRSystemModalShowsCloseBoxWhenFrontMost"] {
    print(mark(dlsym(dfr, name) != nil), name)
}
let touchBar = NSTouchBar.self as AnyObject
for name in ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", "dismissSystemModalTouchBar:"] {
    print(mark(touchBar.responds(to: NSSelectorFromString(name))), "+[NSTouchBar \(name)]")
}
let touchBarItem = NSTouchBarItem.self as AnyObject
for name in ["addSystemTrayItem:", "removeSystemTrayItem:"] {
    print(mark(touchBarItem.responds(to: NSSelectorFromString(name))), "+[NSTouchBarItem \(name)]")
}

print("\n== 跨桌面切换（AppSwitcher.swift）")
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
for name in ["SLSMainConnectionID", "SLSCopySpacesForWindows", "_SLPSSetFrontProcessWithOptions", "SLPSPostEventRecordTo"] {
    print(mark(dlsym(skyLight, name) != nil), name)
}
for name in ["GetProcessForPID", "_AXUIElementGetWindow", "_AXUIElementCreateWithRemoteToken"] {
    print(mark(dlsym(defaultHandle, name) != nil), name)
}

print("\n== 相关设置")
func pref(_ key: String, _ domain: String) -> String {
    CFPreferencesAppSynchronize(domain as CFString)
    return CFPreferencesCopyAppValue(key as CFString, domain as CFString).map { "\($0)" } ?? "（未设置，用系统默认）"
}
print("Touch Bar 显示模式 PresentationModeGlobal:", pref("PresentationModeGlobal", "com.apple.touchbar.agent"))
print("台前调度 GloballyEnabled:", pref("GloballyEnabled", "com.apple.WindowManager"))
print("切到有该 App 窗口的桌面 workspaces-auto-swoosh:", pref("workspaces-auto-swoosh", "com.apple.dock"))
print("ControlStrip 进程在运行:",
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlstrip").isEmpty ? "✗" : "✓")
