import Foundation

/// 作者和项目的链接、版本号。改链接只改这里。
enum AppInfo {
    static let name = "DockTouchBar"
    static let author = "hooosberg"
    static let productPageURL = URL(string: "https://hooosberg.com/apps/docktouchbar")!
    static let diaryURL = URL(string: "https://hooosberg.com/apps/docktouchbar/diary")!
    static let githubProfileURL = URL(string: "https://github.com/hooosberg")!
    static let repositoryURL = URL(string: "https://github.com/hooosberg/DockTouchBar")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
