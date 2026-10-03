import AppKit
import Darwin

/// AI 编程助手（Claude Code 等）在某个 App 里的工作状态，显示在对应 App 的图标上。
enum AgentState: Equatable {
    case idle
    case working
    /// 刚做完、用户还没点过。点一下对应图标就回到 idle。
    case done
}

/// 接收各个助手的 hook 事件（本地 Unix socket），按“所在的 App”汇总成状态。
///
/// 事件来自 `AgentHookInstaller` 写进各助手配置（~/.claude/settings.json、~/.codex/hooks.json）的 hook：每个事件一行
/// `事件名 \t hook 进程的父进程号 \t Claude 传来的 JSON`。父进程号一路往上找，找到第一个有 Dock 图标的 App，
/// 就是这次会话所在的 App（终端、VS Code、Claude 桌面版……）。
final class AgentMonitor {
    static let shared = AgentMonitor()

    /// 支持目录（socket、hook 脚本）。可以替换，测试时用。
    static var supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(AppInfo.fileName)", isDirectory: true)
    static var socketURL: URL { supportDirectory.appendingPathComponent("agent.sock") }

    /// 从 hook 进程号找到会话所在的 App。可以替换，测试时用。
    var ownerResolver: (pid_t) -> String? = AgentMonitor.owningApp(of:)
    /// 状态变了（主线程回调）。
    var onChange: (() -> Void)?
    /// 设置里的总开关；关掉后所有图标都按 idle 显示，事件仍然记录。
    var isEnabled = true {
        didSet { if isEnabled != oldValue { onChange?() } }
    }

    private struct Session {
        var state: AgentState
        var lastEvent: Date
    }

    /// App 的 bundleID → 会话 ID → 会话。只在主线程读写。
    private var sessions: [String: [String: Session]] = [:]
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSource?
    private var staleTimer: Timer?
    /// Stop 不会在用户按 Esc 打断时触发；工作中的会话超过这么久没有任何事件，就当没发生过，免得动画一直转。
    private static let staleAfter: TimeInterval = 600

    func state(for bundleID: String) -> AgentState {
        guard isEnabled, let group = sessions[bundleID], !group.isEmpty else { return .idle }
        if group.values.contains(where: { $0.state == .working }) { return .working }
        return .done
    }

    /// 用户点了图标：把这个 App 里“做完了”的会话清掉。
    func acknowledge(bundleID: String) {
        guard var group = sessions[bundleID] else { return }
        let before = group.count
        group = group.filter { $0.value.state != .done }
        sessions[bundleID] = group.isEmpty ? nil : group
        if group.count != before { onChange?() }
    }

    // MARK: - 服务

    func start() {
        guard listenFD < 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let path = Self.socketURL.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptConnection(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source as? DispatchSource

        staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.dropStaleSessions() }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        staleTimer?.invalidate()
        staleTimer = nil
        unlink(Self.socketURL.path)
    }

    private func acceptConnection(on fd: Int32) {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // hook 的 nc 发完就关；读到结束为止，最多等 1 秒，防止异常连接一直占着。
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        close(client)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let ppid = pid_t(parts[1]) else { continue }
            // 事件字段是 “事件名” 或 “事件名|智能体 id”（配对智能体的脚本会带上自己的 id，只用于日志和配对列表）。
            let eventParts = parts[0].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let event = String(eventParts[0])
            let agent = eventParts.count == 2 ? String(eventParts[1]) : nil
            var sessionID: String?
            if parts.count == 3, let json = try? JSONSerialization.jsonObject(with: Data(parts[2].utf8)) as? [String: Any] {
                sessionID = json["session_id"] as? String
            }
            DispatchQueue.main.async { [weak self] in
                self?.handle(event: event, sessionID: sessionID ?? "pid-\(ppid)", from: ppid, agent: agent)
            }
        }
    }

    // MARK: - 状态机

    func handle(event: String, sessionID: String, from pid: pid_t, agent: String? = nil) {
        let owner = ownerResolver(pid)
        record("\(event) agent=\(agent ?? "-") session=\(sessionID.prefix(8)) pid=\(pid) app=\(owner ?? "-")")
        guard let bundleID = owner else { return }
        let before = state(for: bundleID)
        var group = sessions[bundleID] ?? [:]
        let now = Date()
        switch event {
        case "UserPromptSubmit":
            group[sessionID] = Session(state: .working, lastEvent: now)
        case "PostToolUse", "Notification":
            // 心跳。做完之后迟到的事件（子任务收尾等）不能把状态翻回去。
            if var session = group[sessionID] {
                session.lastEvent = now
                group[sessionID] = session
            } else {
                group[sessionID] = Session(state: .working, lastEvent: now)
            }
        case "Stop":
            group[sessionID] = Session(state: .done, lastEvent: now)
        case "SessionEnd", "Interrupt":
            // 会话结束，或用户按 Esc 打断（Codex 有 Interrupt 事件；Claude Code 没有，靠超时兜底）：直接回到空闲，不显示“做完”。
            group[sessionID] = nil
        default:
            return
        }
        sessions[bundleID] = group.isEmpty ? nil : group
        if state(for: bundleID) != before { onChange?() }
    }

    /// 诊断日志：最近收到的事件，排查“助手没反应”时看。超过 64KB 就从头来。
    private func record(_ line: String) {
        let url = Self.supportDirectory.appendingPathComponent("events.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 65536 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func dropStaleSessions() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        var changed = false
        for (bundleID, group) in sessions {
            let kept = group.filter { $0.value.state == .done || $0.value.lastEvent > cutoff }
            if kept.count != group.count {
                sessions[bundleID] = kept.isEmpty ? nil : kept
                changed = true
            }
        }
        if changed { onChange?() }
    }

    // MARK: - 进程

    /// 从 `pid` 一路往父进程找，第一个有 Dock 图标的 App 就是会话所在的 App。
    static func owningApp(of pid: pid_t) -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var current = pid
        for _ in 0..<32 where current > 1 {
            if current != ownPID, let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, let id = app.bundleIdentifier {
                return id
            }
            guard let parent = parentPID(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
