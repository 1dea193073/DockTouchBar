import AppKit
import ApplicationServices

/// 垃圾桶没有自己的进程：点它只是让访达打开一个显示 ~/.Trash 的窗口。
/// 想让它和别的图标一样能长按关闭、双击最小化，就得从访达的窗口里认出这一个。
/// 实测访达的废纸篓窗口 `AXDocument` 是空的，没有路径可比，只能认标题；标题随系统语言本地化。
/// 本进程的显示名只跟着本 App 支持的语言（中文、英文）走，用户用别的系统语言时会和访达对不上，
/// 所以再附上常见语言的叫法。需要辅助功能权限，没有权限时当作“不知道”。
enum TrashWindow {
    private static let finderID = "com.apple.finder"

    private static var titles: Set<String> {
        [FileManager.default.displayName(atPath: DockTile.trash.url?.path ?? ""),
         "Trash", "废纸篓", "垃圾桶", "ゴミ箱", "휴지통", "Corbeille", "Papierkorb", "Papelera", "Cestino",
         "Lixo", "Reciclagem", "Корзина", "Prullenmand", "Papirkurv", "Papperskorg", "Roskakori", "Kosz", "Sepet"]
    }

    static var finderApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first
    }

    /// 访达里正开着的废纸篓窗口（含最小化的、别的桌面看得到的那部分）。没有权限或读不到时是 nil。
    static func windows() -> [AXUIElement]? {
        guard AXIsProcessTrusted(), let finder = finderApp else { return nil }
        let element = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        let names = titles
        return list.filter { window in
            var role: CFTypeRef?
            var text: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == kAXWindowRole
                && AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &text) == .success
                && names.contains((text as? String) ?? "")
        }
    }

    static var isOpen: Bool {
        windows()?.isEmpty == false
    }

    /// 给图标亮暗用：没有辅助功能权限、看不到窗口时按“开着”算（图标保持亮，不误导成已关闭）。
    static var isOpenOrUnknown: Bool {
        windows().map { !$0.isEmpty } ?? true
    }
}
