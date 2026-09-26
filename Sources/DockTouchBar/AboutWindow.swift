import AppKit
import SwiftUI

/// “关于”窗口：介绍、使用说明、作者链接、求 Star。
/// 每次打开都重新创建内容，这样切换语言后再打开就是新语言。
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = L10n.tr("关于 \(AppInfo.name)", "About \(AppInfo.name)")
        window.contentViewController = NSHostingController(rootView: AboutView())
        window.center()
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct AboutView: View {
    private struct Usage: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private var usages: [Usage] {
        [
            Usage(symbol: "hand.tap", title: L10n.tr("单击", "Tap"),
                  detail: L10n.tr("切换到这个 App，没打开的会启动。窗口在别的桌面时自动切过去（需要辅助功能权限）。",
                                  "Switch to the app, or launch it if it isn't running. If its windows are on another desktop, jump there (needs Accessibility permission).")),
            Usage(symbol: "eye.slash", title: L10n.tr("双击", "Double-tap"),
                  detail: L10n.tr("隐藏这个 App（等同 ⌘H），再点一下就回来。",
                                  "Hide the app (same as ⌘H). Tap it again to bring it back.")),
            Usage(symbol: "power", title: L10n.tr("长按", "Long-press"),
                  detail: L10n.tr("退出这个 App（等同 ⌘Q）。按住时图标下方出现红色进度条，走满就退出；中途松手算单击。时长可在菜单里设置。",
                                  "Quit the app (same as ⌘Q). A red progress bar fills under the icon while you hold; release early to treat it as a tap. Duration is set in the menu.")),
            Usage(symbol: "arrow.left.and.right", title: L10n.tr("左右滑动", "Swipe"),
                  detail: L10n.tr("图标放不下时滚动。", "Scroll when the icons don't all fit.")),
            Usage(symbol: "slider.horizontal.3", title: L10n.tr("调亮度、音量", "Brightness & volume"),
                  detail: L10n.tr("点最右端的小眼睛，Dock 暂时隐藏、系统控制条回来，稍后自动恢复（时长在菜单里设置）；也可以在菜单里取消勾选“在 Touch Bar 上显示 Dock”。",
                                  "Tap the eye at the right end to hide the Dock for a moment and bring back the system controls; it returns on its own (set the time in the menu). Or untick “Show Dock on Touch Bar” in the menu.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name).font(.title2.weight(.bold))
                    Text(L10n.tr("版本 \(AppInfo.version)（\(AppInfo.build)）", "Version \(AppInfo.version) (\(AppInfo.build))"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Text(L10n.tr("简洁 · 优雅 · 高效", "Simple · Elegant · Efficient"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, -6)

            Text(L10n.tr("在 Touch Bar 上显示 Dock：单击切换，双击隐藏，长按退出。",
                         "Your Dock on the Touch Bar: tap to switch, double-tap to hide, long-press to quit."))
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("使用说明", "How to use")).font(.headline)
                ForEach(usages) { usage in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: usage.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(usage.title).font(.callout.weight(.semibold))
                            Text(usage.detail)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(L10n.tr("辅助功能里 DockTouchBar 的开关开着，但菜单里“跨桌面启动应用”没有打勾：在 系统设置 → 隐私与安全性 → 辅助功能 里删掉 DockTouchBar，再重新添加并打开。",
                             "If DockTouchBar is switched on in Accessibility but “Launch apps across desktops” isn't ticked in the menu: remove DockTouchBar there, then add it again and turn it on."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("作者：\(AppInfo.author)", "By \(AppInfo.author)")).font(.headline)
                HStack(spacing: 18) {
                    Link(destination: AppInfo.productPageURL) {
                        Label(L10n.tr("产品页", "Product page"), systemImage: "globe")
                    }
                    Link(destination: AppInfo.diaryURL) {
                        Label(L10n.tr("开发日记", "Build diary"), systemImage: "book")
                    }
                    Link(destination: AppInfo.githubProfileURL) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Text(L10n.tr("如果它对你有帮助，欢迎在 GitHub 上点一个 Star 支持一下。",
                             "If it helps you, a Star on GitHub would mean a lot."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: AppInfo.repositoryURL) {
                    Label(L10n.tr("在 GitHub 上点 Star", "Star on GitHub"), systemImage: "star.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            Text(L10n.tr("© 2026 \(AppInfo.author) · 个人使用免费，商业使用需另行授权",
                         "© 2026 \(AppInfo.author) · Free for personal use, commercial use requires a separate license"))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }
}
