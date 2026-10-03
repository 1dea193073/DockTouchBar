import AppKit

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
}

let entries = (try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: String]])
let keys = entries.map { $0["en"]! }
let languages = AppLanguage.allCases.filter { $0 != .system && $0 != .chinese && $0 != .english }
check(AppLanguage.allCases.count == 13, "12 languages + follow system")

func placeholders(_ s: String) -> Set<String> {
    var found = Set<String>()
    var i = s.startIndex
    while let open = s[i...].firstIndex(of: "{"), let close = s[open...].firstIndex(of: "}") {
        found.insert(String(s[open...close]))
        i = s.index(after: close)
    }
    return found
}

for language in languages {
    let table = Translations.table(for: language)
    let missing = keys.filter { table[$0] == nil || table[$0]!.trimmingCharacters(in: .whitespaces).isEmpty }
    check(missing.isEmpty, "\(language.rawValue): all \(keys.count) strings translated" + (missing.isEmpty ? "" : " — missing \(missing.count), e.g. \(missing[0])"))
    let badPlaceholders = keys.filter { key in table[key].map { placeholders(key) != placeholders($0) } ?? false }
    check(badPlaceholders.isEmpty, "\(language.rawValue): placeholders intact" + (badPlaceholders.isEmpty ? "" : " — e.g. \(badPlaceholders[0])"))
    let extra = table.keys.filter { !keys.contains($0) }
    check(extra.isEmpty, "\(language.rawValue): no stale keys" + (extra.isEmpty ? "" : " — e.g. \(extra[0])"))
    let untranslated = keys.filter { table[$0] == $0 && $0.count > 12 }.count
    check(untranslated < keys.count / 10, "\(language.rawValue): few strings left in English (\(untranslated))")
}

// 运行时：切到每种语言，文字真的变了，占位符被填上
let saved = L10n.preference
let sample = { (name: String) in L10n.tr("按住不放，关闭 \(name)", "Hold to close \(name)") }
L10n.preference = .chinese
check(sample("Safari") == "按住不放，关闭 Safari", "zh: call-site Chinese")
L10n.preference = .english
check(sample("Safari") == "Hold to close Safari", "en: call-site English")
for language in languages {
    L10n.preference = language
    let text = sample("Safari")
    check(text.contains("Safari") && !text.contains("{") && text != "Hold to close Safari", "\(language.rawValue): runtime '\(text)'")
}
L10n.preference = saved

// “跟随系统”的换算
check(AppLanguage.fromSystem(["zh-Hans-CN"]) == .chinese, "system zh-Hans-CN -> zh")
check(AppLanguage.fromSystem(["zh-Hant-TW"]) == .traditionalChinese, "system zh-Hant-TW -> zh-Hant")
check(AppLanguage.fromSystem(["zh-HK"]) == .traditionalChinese, "system zh-HK -> zh-Hant")
check(AppLanguage.fromSystem(["ja-JP", "en-US"]) == .japanese, "system ja-JP -> ja")
check(AppLanguage.fromSystem(["pt-BR"]) == .portuguese, "system pt-BR -> pt")
check(AppLanguage.fromSystem(["ar-SA", "fr-FR"]) == .french, "unsupported first language falls to the next supported one")
check(AppLanguage.fromSystem(["ar-SA"]) == .english, "no supported language -> English")
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
