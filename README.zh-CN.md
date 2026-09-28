<p align="center">
  <img src="assets/icon-256.png" alt="DockTouchBar" width="128" height="128">
</p>

<h1 align="center">DockTouchBar</h1>

<p align="center">
  <strong>把 Dock 放到 Touch Bar 上。</strong>
  <br>
  <strong>简洁 · 优雅 · 高效</strong>
  <br>
  单击切换 · 双击隐藏 · 长按退出
  <br>
  <a href="README.md">English</a> ·
  <a href="https://github.com/hooosberg/DockTouchBar/releases/latest">下载</a> ·
  <a href="https://hooosberg.com/apps/docktouchbar">产品页</a> ·
  <a href="https://hooosberg.com/apps/docktouchbar/diary">开发日记</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-444.svg" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20芯片-已实测-2e7d32.svg" alt="Apple 芯片：已实测">
  <img src="https://img.shields.io/badge/Intel-未实测-f9a825.svg" alt="Intel：未实测">
  <img src="https://img.shields.io/badge/Swift-AppKit-F05138.svg" alt="Swift + AppKit">
  <img src="https://img.shields.io/badge/许可证-PolyForm%20Noncommercial-1e88e5.svg" alt="PolyForm Noncommercial">
</p>

![Touch Bar 上的 DockTouchBar](assets/touchbar-idle.gif)
*平时工作状态：图标底部贴边、右上角运行状态标点（前台红色、运行中灰色微描边），最右侧像素咖啡杯白烟动态飘动*

![长按退出：四季主题关闭效果](assets/touchbar-seasons.gif)
*长按退出演示：像素画四季长按倒计时动画（春·奔跑小狗 / 夏·帆船冲浪 / 秋·林间小狐 / 冬·雪橇滑雪），中途松手即取消，松手后还有收尾消散风暴*

### ⚡ 极致能耗与性能（实机实测）

DockTouchBar 为全天常驻设计，基于纯事件驱动模型（Event-Driven），拒绝轮询，绝不阻碍 CPU 深度睡眠：

| 指标维度 | 实测数据 | 说明 |
|---|---|---|
| **CPU 占用** | **0.0% ~ 0.8%** | 日常空闲 0.0%；仅在切换应用或窗口变动时有瞬间微小起伏 |
| **物理内存 (Footprint)** | **29 MB** | macOS 官方 `footprint` 工具实测，远低于传统跨平台工具 |
| **能耗影响 (Energy Impact)** | **0.0** | 活动监视器最低档能耗，对电池续航几无影响 |
| **常驻线程** | **4 线程（全部休眠等待事件）** | 零忙等待，无高频心跳唤醒 |
| **网络访问** | **零网络连接 (0 Sockets)** | 纯本地运行，不联网、无统计、无隐私泄露 |
| **渲染性能** | **单帧约 2.3 ms** | 原生 CoreAnimation / AppKit 渲染，触控灵敏跟手 |

**如果 DockTouchBar 对你有用，去 GitHub 点个 ⭐ Star，就是最好的支持。**

## 为什么做

Pock、PockV2 等都能把 Dock 放到 Touch Bar 上，但它们做的事情更多，日常用起来 Touch Bar 容易消失或点了没反应。DockTouchBar 只做一件事，并且把这件事做好。

**简洁**

- 只做一件事：Touch Bar 上的 Dock。没有小组件，没有插件。
- 菜单栏里只有几个开关，没有别的要配置。
- 大约 4200 行 Swift，15 个文件（其中不少是像素画的数据），没有第三方依赖。整个 App 只有 1.7 MB。

**优雅**

- 像 macOS 自带的一部分：图标顺序和运行小圆点都和你的 Dock 一致，用的是系统自己的 Touch Bar 滚动控件。
- 手势不打扰你：单击立刻生效，不会为了等你是不是要双击而延迟；长按时图标下方出现一条安静的进度条，Touch Bar 右边缘还会显示“正在关闭…”和倒计时（手指不会挡住），背景是一幅像素画的季节小场景，春夏秋冬可以在菜单里切换，中途松手就取消。
- 连点也很跟手：永远以最后一下为准，也不会和你争。切桌面被系统丢掉、或者焦点被别的 App 抢走，它会悄悄纠正回来；你一动键盘、鼠标或触控板，它立刻停手。
- 跟随你的语言（English / 简体中文），只需要一个可选的权限。

**高效**

- 事件驱动，没有轮询。在 M1 MacBook Pro 上开着 Dock 空闲时实测：**CPU 0.0%**、**空闲唤醒 0 次**、内存约 **32 MB**。\*
- 适应你的电脑，而不是用固定的等待时间：切桌面时等系统自己发出的“切完了”信号并核对结果，动画慢、关掉动画、机器很忙时都不会出错。
- App 启动或退出时只更新变化的部分，滚动位置不会被打断；图标只栅格化一次并缓存。
- 能自己恢复：睡眠唤醒、屏幕解锁、控制条进程重启之后自动重新挂上，不用手动重开。
- 失败时安全：私有接口在运行时解析，系统删掉某个接口时，对应功能自动关闭，而不是崩溃。
- 隐私：不联网，没有统计，没有账号，只保存你的偏好设置。

<sub>\* Release 版本。CPU 是 `top` 连续 5 次采样（间隔 2 秒）都是 0.0%；唤醒次数是读内核的进程计数器、隔 20 秒读两次做差，1.10 上测了三次（每次空闲唤醒和中断唤醒都是 0 次；此前在 1.8 上有一次中断唤醒 0～7 次，来自系统事件）；内存是 `footprint` 的物理占用（32 MB）。咖啡杯上方的蒸汽是系统的渲染进程画的，不是 App 本身在动。</sub>

## 功能

| 操作 | 效果 |
|---|---|
| **单击**图标 | 切换到这个 App，没打开的就启动。App 的窗口在别的桌面时，自动切到那个桌面 |
| **双击** | 隐藏这个 App（等同 ⌘H），再点一下就回来 |
| **长按** | 关闭这个 App，并且每次都告诉你结果。按住时图标下方出现进度条，右边缘出现“正在关闭…”倒计时，背景是像素画的季节场景（菜单里选）；中途松手算单击。App 在最前面且有两个或更多窗口时只关当前窗口，否则退出（等同 ⌘Q）；访达退不了，所以隐藏它（在最前面时关当前窗口）。如果 App 关不掉，是因为在等你回答（“要保存吗”之类的确认框）或者压根没关，Touch Bar 会切到它那边（包括切桌面）并提示你 |
| **左右滑动** | 图标放不下时滚动 |
| **咖啡杯**（右端，杯口有蒸汽动画） | 歇一会儿：暂时隐藏 Dock、把 Touch Bar 还给系统（亮度、音量），10–60 秒后自动回来 |
| **窗口居中 / 最大化按钮**（最右边） | 把最前面 App 的窗口居中；再点一下最大化（铺满可用区域，不是原生全屏），再点回到居中。你自己拖过或换了 App，就先居中，图标会跟着窗口现在的样子变。需要辅助功能权限 |

菜单栏里的设置：

- 在 Touch Bar 上显示 Dock（开 / 关）
- 点咖啡杯后临时隐藏：10 / 20 / 30 / 60 秒
- 只显示正在运行的 App（默认不勾选：固定在 Dock 里的 App 也会显示）

- 显示“窗口居中 / 最大化”按钮，以及居中后窗口的大小（高度为屏幕高度的 60–100%；宽度与高度相同，或为屏幕宽度的 50–100%）

- 权限：显示辅助功能是否已开启、用来做什么（跨桌面切换、居中 / 最大化、只关当前窗口、发现确认框），点一下去系统设置里开启；除此之外不需要任何权限
- 双击图标：隐藏 App
- 长按图标：关闭 App（不启用 / 1 / 2 / 3 / 5 秒）
- 长按提示风格：春天 / 夏天 / 秋天 / 冬天（选中后 Touch Bar 上会演示一遍）

- 语言：跟随系统 / 简体中文 / English
- 登录时自动启动
- 关于：使用说明、产品页和开发日记链接、Star 按钮

App 已经在运行时，再从「应用程序」打开它，会直接弹出这个菜单。

## 使用环境和实测情况

| | |
|---|---|
| 硬件 | 带 Touch Bar 的 Mac（MacBook Pro 2016–2022） |
| **实测环境** | **MacBook Pro 13 英寸（M1，`MacBookPro17,1`），macOS 27.0，单显示器，3 个桌面，Touch Bar 设为“展开的控制条”，开着台前调度** |
| Apple 芯片（M1） | ✅ 这就是开发和日常使用的机器 |
| Intel | ⚠️ **未知。** 安装包是通用二进制，在 M1 上用 Rosetta 能启动 Intel 部分，但从没在真正的 Intel Touch Bar 机器上跑过。欢迎反馈 |
| macOS 版本 | 最低按 macOS 13 编译，但只在 macOS 27.0 上测过，更早的版本没测 |

需要知道的几件事：

- 后台 App 要让 Touch Bar 一直显示，只能用 **Apple 的私有 API**。所以它不能上架 Mac App Store，以后 macOS 更新也可能让它失效。私有接口都是在运行时解析的，缺了哪个，对应功能会自己关闭而不是崩溃；运行 `swift tools/probe-private-api.swift` 可以看到你的 macOS 里还有哪些。
- Dock 会占满**整条** Touch Bar，开着的时候系统控制条（亮度、音量）看不到。要用时，点 Touch Bar 右侧的咖啡杯，Dock 暂时隐藏、Touch Bar 还给系统（10–60 秒后自动回来，默认 20 秒；如果屏幕被调到全黑，则等亮度调回来就自动恢复）。也可以在菜单里取消勾选“在 Touch Bar 上显示 Dock”。
- 图标顺序和你的 Dock 一致：访达 → 固定的 App → 分隔线 → 其他正在运行的 App。
- 开着台前调度时，macOS 会给窗口切换加动画，窗口在屏幕上出现要约半秒。被点的 App 变成前台只要约 40 毫秒，剩下的时间是系统的动画。

## 安装

1. 到 [Releases](https://github.com/hooosberg/DockTouchBar/releases/latest) 下载 `DockTouchBar-<版本>.dmg`。
2. 打开后把 **DockTouchBar** 拖到 **Applications**，再启动它。菜单栏和 Touch Bar 上会出现图标。

> DMG 用 Developer ID 证书签名，并且**已通过 Apple 公证**，所以和普通 App 一样可以直接打开，第一次启动时系统只会让你确认一下。想自己编译的话，见[从源码编译](#从源码编译)。

### 辅助功能权限（可选）

切到别的桌面上的窗口需要辅助功能权限。不给也不影响其他功能，这时点 App 只会把它带到前台，不切桌面。

1. 菜单栏图标 → **权限** → **辅助功能：未开启，点一下去开启…**（授权后会变成打勾的“已开启”）
2. 在 系统设置 → 隐私与安全性 → 辅助功能 里打开 DockTouchBar。

如果打开后仍然提示授权，说明旧记录已失效（App 的签名变了就会这样）：在列表里选中 DockTouchBar，点 **−** 删掉，再重新添加。或者运行 `tccutil reset Accessibility com.maohuhu.docktouchbar` 后重做第 1 步。

### 点了没有切到桌面时

出问题之后马上在仓库目录里运行下面这条。它是只读的，会打印程序当时怎么判断这个 App 的窗口：有哪些窗口、各在哪个桌面、哪些是真实窗口、最后会提前哪一个：

```bash
tools/diagnose-switch.sh com.google.Chrome
```

## 从源码编译

需要 Xcode 命令行工具。

```bash
git clone https://github.com/hooosberg/DockTouchBar.git
cd DockTouchBar
scripts/install.sh      # 编译 → 装到 /Applications → 启动
scripts/make-dmg.sh     # 生成 build/DockTouchBar-<版本>.dmg
```

没有签名证书时会退回 ad-hoc 签名。能用，但 macOS 会把每次重新编译的 ad-hoc 版本当成新 App，辅助功能权限每次都要重新授权。设置 `SIGN_IDENTITY="Apple Development: …"`（或 Developer ID 证书）可以固定签名身份。

## 目录结构

```
Sources/DockTouchBar/   App 源码（15 个文件）
Resources/              Info.plist、App 图标
scripts/                build.sh、install.sh、make-dmg.sh、make-icon.sh
tools/                  诊断工具：私有接口检查、桌面与窗口查看、切换诊断、连点压力测试、离屏预览、render-seasons.sh（README 里的截图）
assets/                 README 里的图片
```

macOS 大版本更新后，运行 `swift tools/probe-private-api.swift` 可以看到哪些私有接口还在。

## 许可证

[PolyForm Noncommercial License 1.0.0](LICENSE)：**个人使用及其他非商业用途**可以免费使用、复制、修改和分享。**商业使用不在授权范围内**，需要向作者另行取得授权，请通过 [hooosberg.com](https://hooosberg.com/) 联系。

这是“源码可见”许可证，不是 OSI 认可的开源许可证。版权声明：Copyright © 2026 hooosberg。

## 作者

**hooosberg** — [hooosberg.com](https://hooosberg.com/) · [GitHub](https://github.com/hooosberg)。如果它帮你省了几次点击，欢迎 ⭐ Star 支持。
