import AppKit
import SwiftUI

/// “关于”窗口，两页：关于（介绍、作者链接、求 Star）和使用说明。窗口高度按内容自动适应，取两页里较高的那页。
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct AboutView: View {
    private enum Page { case about, usage }

    /// 使用说明里的一项：左边是图标（系统符号或者像素画），右边是标题和说明。
    private struct Usage: Identifiable {
        enum Icon {
            case symbol(String)
            case pixels([CGImage?], scale: CGFloat)
        }
        let id = UUID()
        let icon: Icon
        let title: String
        let detail: String
    }

    @State private var page = Page.about

    private var gestures: [Usage] {
        [
            Usage(icon: .symbol("hand.tap"), title: L10n.tr("单击", "Tap"),
                  detail: L10n.tr("切换到这个 App，没打开的会启动。窗口在别的桌面时自动切过去（需要辅助功能权限）。",
                                  "Switch to the app, or launch it if it isn't running. If its windows are on another desktop, jump there (needs Accessibility permission).")),
            Usage(icon: .symbol("eye.slash"), title: L10n.tr("双击", "Double-tap"),
                  detail: L10n.tr("隐藏这个 App（等同 ⌘H），再点一下就回来。",
                                  "Hide the app (same as ⌘H). Tap it again to bring it back.")),
            Usage(icon: .symbol("power"), title: L10n.tr("长按", "Long-press"),
                  detail: L10n.tr("退出这个 App（等同 ⌘Q）。按住时右边缘出现像素画的倒计时，小角色沿进度条跑到头就退出；中途松手算单击。时长和提示的季节风格（春夏秋冬）可在菜单里设置。",
                                  "Quit the app (same as ⌘Q). A pixel-art countdown appears at the edge and a tiny character runs along the progress bar; when it gets to the end, the app quits. Release early to treat it as a tap. The duration and the season (spring, summer, autumn, winter) are set in the menu.")),
            Usage(icon: .symbol("arrow.left.and.right"), title: L10n.tr("左右滑动", "Swipe"),
                  detail: L10n.tr("图标放不下时滚动。", "Scroll when the icons don't all fit.")),
        ]
    }

    private var buttons: [Usage] {
        [
            Usage(icon: .pixels([PixelIcon.coffee.first], scale: 1.5), title: L10n.tr("咖啡杯", "Coffee cup"),
                  detail: L10n.tr("歇一会儿：Dock 暂时隐藏、系统控制条（亮度、音量）回来，稍后自动恢复，时长在菜单里设置。也可以在菜单里取消勾选“在 Touch Bar 上显示 Dock”。",
                                  "Take a break: the Dock hides for a moment and the system controls (brightness, volume) come back, then it returns on its own (set the time in the menu). Or untick “Show Dock on Touch Bar” in the menu.")),
            Usage(icon: .pixels([PixelIcon.center, PixelIcon.maximize], scale: 1), title: L10n.tr("窗口居中 / 最大化", "Center / maximize"),
                  detail: L10n.tr("把最前面 App 的窗口居中；已经居中时再点一下最大化（铺满可用区域，不是原生全屏），再点回到居中。你自己拖过或换了 App，就先居中。需要辅助功能权限。",
                                  "Center the frontmost app's window. When it is already centered, the next tap maximizes it (fills the usable area, not native full screen), and the next one centers it again. If you moved the window or switched apps, it centers first. Needs Accessibility permission.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text(L10n.tr("关于", "About")).tag(Page.about)
                Text(L10n.tr("使用说明", "How to use")).tag(Page.usage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.top, 14)

            // 两页叠在一起，窗口高度取较高的那一页，切换时窗口大小不变；看不见的那页不响应点击。
            ZStack {
                aboutPage
                    .opacity(page == .about ? 1 : 0)
                    .allowsHitTesting(page == .about)
                usagePage
                    .opacity(page == .usage ? 1 : 0)
                    .allowsHitTesting(page == .usage)
            }
        }
        .frame(width: 460)
    }

    // MARK: - 关于

    private var aboutPage: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(AppInfo.name).font(.title.weight(.bold)).padding(.top, 6)
            Text(L10n.tr("版本 \(AppInfo.version)（\(AppInfo.build)）", "Version \(AppInfo.version) (\(AppInfo.build))"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L10n.tr("简洁 · 优雅 · 高效", "Simple · Elegant · Efficient"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 10)
            Text(L10n.tr("把 Dock 放到 Touch Bar 上", "Your Dock on the Touch Bar"))
                .font(.callout).foregroundStyle(.secondary)

            Spacer(minLength: 24)
            Divider().padding(.horizontal, 40)
            Spacer(minLength: 18)

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
            .padding(.top, 4)
            Text(L10n.tr("如果它对你有帮助，欢迎在 GitHub 上点一个 Star 支持一下。",
                         "If it helps you, a Star on GitHub would mean a lot."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Link(destination: AppInfo.repositoryURL) {
                Label(L10n.tr("在 GitHub 上点 Star", "Star on GitHub"), systemImage: "star.fill")
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            .padding(.top, 4)

            Spacer(minLength: 18)
            Text(L10n.tr("© 2026 \(AppInfo.author) · 个人使用免费，商业使用需另行授权",
                         "© 2026 \(AppInfo.author) · Free for personal use, commercial use requires a separate license"))
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 使用说明

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(L10n.tr("在图标上", "On the icons"), gestures)
            section(L10n.tr("右侧的按钮", "The buttons on the right"), buttons)
            Text(L10n.tr("辅助功能里 DockTouchBar 的开关开着，但菜单里“跨桌面启动应用”没有打勾：在 系统设置 → 隐私与安全性 → 辅助功能 里删掉 DockTouchBar，再重新添加并打开。",
                         "If DockTouchBar is switched on in Accessibility but “Launch apps across desktops” isn't ticked in the menu: remove DockTouchBar there, then add it again and turn it on."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func section(_ title: String, _ items: [Usage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items) { usage in
                HStack(alignment: .top, spacing: 10) {
                    icon(usage.icon)
                        .frame(width: 34, alignment: .center)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(usage.title).font(.callout.weight(.semibold))
                        Text(usage.detail)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ icon: Usage.Icon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
        case .pixels(let images, let scale):
            // 像素画是白色的，按“模板”画：颜色跟着文字走，浅色、深色外观下都看得清。每格 4 个像素。
            VStack(spacing: 4) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    if let image {
                        Image(decorative: image, scale: 1)
                            .renderingMode(.template)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: CGFloat(image.width) / 4 * scale, height: CGFloat(image.height) / 4 * scale)
                    }
                }
            }
        }
    }
}
