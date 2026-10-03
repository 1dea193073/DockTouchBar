import Foundation

/// 作者和项目的链接、版本号。改链接只改这里。
enum AppInfo {
    /// 界面里显示的名字。
    static let name = "DockTouchBar Vibe"
    /// 打包文件名（.app、.dmg、进程名），不带空格。
    static let fileName = "DockTouchBarVibe"
    /// Vibecoding 版自己的包标识符：和纯净版分开，权限、设置、更新互不影响。
    static let bundleID = "com.maohuhu.docktouchbar.vibe"
    /// 本版本的发布标签前缀。更新只认这个前缀的发布，不会把纯净版的发布当成更新。
    static let releaseTagPrefix = "vibe-v"
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
