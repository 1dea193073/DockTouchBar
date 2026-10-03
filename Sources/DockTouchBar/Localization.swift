import Foundation

/// 界面语言：跟随系统，或指定 12 种语言之一。raw value 同时是保存到偏好设置里的值（"zh"、"en"、"system" 沿用旧值）。
enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh"
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case russian = "ru"
    case italian = "it"
    case turkish = "tr"

    /// 语言自己的名字（选语言的菜单里每一种都用它自己的文字，换成什么界面语言都认得出来）。
    var nativeName: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .chinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .italian: return "Italiano"
        case .turkish: return "Türkçe"
        }
    }

    /// 系统首选语言列表里第一个我们支持的；都不支持就用英文。
    static func fromSystem(_ identifiers: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in identifiers {
            let id = identifier.lowercased()
            if id.hasPrefix("zh") {
                return ["hant", "tw", "hk", "mo"].contains { id.contains($0) } ? .traditionalChinese : .chinese
            }
            let code = String(id.prefix(2))
            if let match = allCases.first(where: { $0 != .system && $0 != .traditionalChinese && $0.rawValue == code }) {
                return match
            }
        }
        return .english
    }
}

/// 界面上的一段文字。字符串字面量里的 `\(值)` 会被记成占位符 `{0}`、`{1}`：模板（不含具体的值）
/// 是翻译表的键，翻译之后再把值填回去。所以调用处照常写 `L10n.tr("中文 \(x)", "English \(x)")`，不用改。
struct LText: ExpressibleByStringInterpolation {
    let template: String
    let args: [String]

    init(stringLiteral value: String) {
        template = value
        args = []
    }

    init(stringInterpolation: Interpolation) {
        template = stringInterpolation.template
        args = stringInterpolation.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var template = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { template += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            template += "{\(args.count)}"
            args.append("\(value)")
        }
    }

    /// 用 `text`（默认就是自己的模板）把占位符换成实际的值。
    func rendered(_ text: String? = nil) -> String {
        var result = text ?? template
        for (index, value) in args.enumerated() { result = result.replacingOccurrences(of: "{\(index)}", with: value) }
        return result
    }
}

/// 每次读取时才判断语言，所以在设置里切换后，下次打开菜单或窗口就生效，不用重启。
/// 中文、英文直接写在调用处；其他语言按英文模板查 `Translations`，查不到就退回英文。
enum L10n {
    static var preference: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: SettingsKey.language) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.language) }
    }

    /// 实际使用的语言（“跟随系统”已经换算成具体语言）。
    static var language: AppLanguage {
        preference == .system ? AppLanguage.fromSystem() : preference
    }

    static var isChinese: Bool { language == .chinese || language == .traditionalChinese }

    static func tr(_ chinese: LText, _ english: LText) -> String {
        switch language {
        case .chinese: return chinese.rendered()
        case .english, .system: return english.rendered()
        default:
            return english.rendered(Translations.table(for: language)[english.template])
        }
    }
}
