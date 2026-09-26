import Foundation

/// 界面语言：跟随系统 / 简体中文 / English。
enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh"
    case english = "en"
}

/// 界面文字只有中英两种，直接在调用处写成一对：`L10n.tr("中文", "English")`。
/// 每次读取时才判断语言，所以在菜单里切换后，下次打开菜单或窗口就生效，不用重启。
enum L10n {
    private static let preferenceKey = "language"

    static var preference: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    /// “跟随系统”时，系统首选语言是中文（简体、繁体都算）就用中文界面，其他都用英文。
    static var isChinese: Bool {
        switch preference {
        case .chinese: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    static func tr(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}
