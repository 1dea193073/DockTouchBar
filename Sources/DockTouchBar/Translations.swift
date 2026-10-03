import Foundation

/// 其他语言的界面文字。键是英文模板（含 `{0}` 这样的占位符，见 `LText`），值是译文。
/// 中文、英文直接写在调用处，不在这里。译文在 `Translations+<语言>.swift`，由
/// `tools/l10n/generate.py` 从翻译好的 JSON 生成；新增或改了界面文字后，
/// 先跑 `tools/l10n/extract.py` 找出缺的，补译，再重新生成。
enum Translations {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .traditionalChinese: return zhHant
        case .japanese: return ja
        case .korean: return ko
        case .french: return fr
        case .german: return de
        case .spanish: return es
        case .portuguese: return pt
        case .russian: return ru
        case .italian: return it
        case .turkish: return tr
        case .system, .chinese, .english: return [:]
        }
    }
}
