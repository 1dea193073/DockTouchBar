// 由 tools/stress-switch.sh 编译运行。参数：<A 的 bundle id> <B 的 bundle id> [间隔毫秒 ...]
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
typealias MainConn = @convention(c) () -> Int32
typealias ActiveSpace = @convention(c) (Int32) -> UInt64
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let connection = unsafeBitCast(dlsym(skyLight, "SLSMainConnectionID"), to: MainConn.self)()
let activeSpace = unsafeBitCast(dlsym(skyLight, "SLSGetActiveSpace"), to: ActiveSpace.self)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
/// 只看真实的键盘、鼠标、滚轮事件距今多少秒。程序自己激活 App、提前窗口不算（用系统的“键鼠空闲时间”会把它们误判成人在操作）。
func secondsSinceUserInput() -> Double {
    let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel]
    return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 999
}
/// 前台 App 是谁。不用“屏幕上最靠前的窗口”来判断：开着台前调度时，`WindowManager` 的窗口会排在前面，
/// 会把成功误判成失败（实测出现过）。
func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
func runningApp(_ id: String) -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: id).first }
func tile(_ id: String) -> DockTile { DockTile(kind: .app, url: runningApp(id)?.bundleURL, bundleID: id, isRunning: true) }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let appA = runningApp(args[0]), let appB = runningApp(args[1]) else {
    print("需要两个都在运行的 App：<A 的 bundle id> <B 的 bundle id>"); exit(1)
}
let idA = args[0], idB = args[1]
let delays = args.dropFirst(2).compactMap { Int($0) }.isEmpty ? [400, 250, 150] : args.dropFirst(2).compactMap { Int($0) }
let trials = Int(ProcessInfo.processInfo.environment["TRIALS"] ?? "") ?? 4, clicksPerTrial = 5
/// CHAOS=1：最后一次点击之后随机时刻捣乱（抢走焦点，或者把桌面切回 A），看程序能不能把结果纠正回目标。
let chaos = ProcessInfo.processInfo.environment["CHAOS"] == "1"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var startedAt = 0.0
var outcomes: [(delay: Int, ok: Bool)] = []

func abortOnInput() {
    if secondsSinceUserInput() < now() / 1000 - startedAt - 0.3 {
        print("⚠ 检测到你动了键盘或鼠标，中止（本轮作废）")
        summary(); exit(0)
    }
}
func summary() {
    print("\n===== 结果：最后一次点击之后，是否真的切到了目标 =====")
    for delay in Set(outcomes.map(\.delay)).sorted(by: >) {
        let rows = outcomes.filter { $0.delay == delay }
        print(String(format: "  点击间隔 %4d ms：%d/%d 次正确", delay, rows.filter(\.ok).count, rows.count))
    }
}

var waited = 0.0
func waitForIdle() {
    if secondsSinceUserInput() >= 8 { startedAt = now() / 1000; begin(); return }
    waited += 0.5
    if waited > 150 { print("等了 150 秒你一直在操作，放弃，没有改动任何东西"); exit(0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: waitForIdle)
}

func begin() {
    let homeSpace = activeSpace(connection)
    print("开始（等了 \(Int(waited)) 秒）。起点：桌面 \(homeSpace)")
    var plan: [(delay: Int, round: Int)] = []
    for delay in delays { for round in 1...trials { plan.append((delay, round)) } }

    func trial(_ index: Int) {
        guard index < plan.count else {
            summary()
            AppSwitcher.switchTo(tile(idA))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
            return
        }
        abortOnInput()
        let (delay, round) = plan[index]
        // 每一轮都先慢慢回到 A，作为统一的起点。
        AppSwitcher.switchTo(tile(idA))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            abortOnInput()
            func click(_ k: Int) {
                guard k < clicksPerTrial else {
                    var settle = 2.4
                    if chaos {
                        settle = 3.2
                        let wait = Double.random(in: 0.15...0.7)
                        let kind = Int.random(in: 0...1)
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                            if kind == 0 {
                                _ = appA.activate(options: [])          // 抢走焦点
                            } else if let window = AppSwitcher.windowsToRaise(of: appA.processIdentifier).first,   // 把桌面切回 A
                                      let element = AppSwitcher.axWindow(pid: appA.processIdentifier, window: window) {
                                _ = AppSwitcher.focus(pid: appA.processIdentifier, window: window, element: element)
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                        // 这一轮期间有过键鼠输入就作废，不记录（宁可少一轮，也不要混进被打扰的数据）。
                        abortOnInput()
                        let ok = frontmostPID() == appB.processIdentifier && activeSpace(connection) != homeSpace
                        print("  间隔 \(delay) ms 第 \(round) 轮 → \(ok ? "✓ 正确" : "✗ 错误（最终停在桌面 \(activeSpace(connection))，前台不是 B）")")
                        outcomes.append((delay, ok))
                        trial(index + 1)
                    }
                    return
                }
                AppSwitcher.switchTo(tile(k % 2 == 0 ? idB : idA))
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) { click(k + 1) }
            }
            click(0)
        }
    }
    trial(0)
}

_ = appA
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: waitForIdle)
app.run()
