import Foundation
import AppKit

/// 新版本更新信息
struct UpdateReleaseInfo: Equatable {
    let version: String
    let title: String
    let notes: String
    let releaseURL: URL
    let assetName: String
    let downloadURL: URL
    let assetSize: Int64
}

/// 自动检测与安装更新管理器（遵循 macOS 安全与签名校验规范）
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(UpdateReleaseInfo)
        case downloading(progress: Double)
        case verifying
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var currentRelease: UpdateReleaseInfo?
    private var currentTempDir: URL?
    private var downloadObservation: NSKeyValueObservation?

    private let releasesAPI = URL(string: "https://api.github.com/repos/hooosberg/DockTouchBar/releases/latest")!

    override init() {
        super.init()
    }

    // MARK: - 检查更新

    /// 检查新版本。silent 为 true 时如果已是最新版本则不打扰用户（用于启动或后台静默检查）
    func checkForUpdates(silent: Bool = false) {
        guard state != .checking, case .downloading = state else {
            if state == .checking { return }
            executeCheck(silent: silent)
            return
        }
        executeCheck(silent: silent)
    }

    private func executeCheck(silent: Bool) {
        state = .checking

        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("DockTouchBar/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if !silent {
                        self.state = .failed(L10n.tr("检查更新失败：\(error.localizedDescription)", "Check failed: \(error.localizedDescription)"))
                    } else {
                        self.state = .idle
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if !silent {
                        self.state = .failed(L10n.tr("解析更新信息失败", "Failed to parse update info"))
                    } else {
                        self.state = .idle
                    }
                    return
                }

                self.parseReleaseResponse(json, silent: silent)
            }
        }.resume()
    }

    private func parseReleaseResponse(_ json: [String: Any], silent: Bool) {
        let tagName = (json["tag_name"] as? String) ?? ""
        let cleanVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))
        let currentVersion = AppInfo.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))

        guard !cleanVersion.isEmpty else {
            state = silent ? .idle : .failed(L10n.tr("未找到有效的版本标签", "No valid version tag found"))
            return
        }

        // 版本比对
        let hasNew = Self.isVersion(cleanVersion, greaterThan: currentVersion)
        if !hasNew {
            state = .upToDate(Date())
            return
        }

        // 寻找合适的更新包资产（优先找 .dmg，其次找 .zip）
        guard let assets = json["assets"] as? [[String: Any]] else {
            state = silent ? .idle : .failed(L10n.tr("新版本未包含可下载的安装包", "No downloadable package in the new release"))
            return
        }

        var matchedAsset: (name: String, url: URL, size: Int64)?
        for item in assets {
            guard let name = item["name"] as? String,
                  let downloadStr = item["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadStr) else { continue }
            let size = (item["size"] as? Int64) ?? 0

            if name.hasSuffix(".dmg") {
                matchedAsset = (name, downloadURL, size)
                break
            } else if name.hasSuffix(".zip") && matchedAsset == nil {
                matchedAsset = (name, downloadURL, size)
            }
        }

        guard let asset = matchedAsset else {
            state = silent ? .idle : .failed(L10n.tr("未找到适配的 macOS 安装包 (.dmg)", "No macOS installer (.dmg) found"))
            return
        }

        let title = (json["name"] as? String) ?? tagName
        let notes = (json["body"] as? String) ?? ""
        let releaseURLStr = (json["html_url"] as? String) ?? AppInfo.repositoryURL.absoluteString
        let releaseURL = URL(string: releaseURLStr) ?? AppInfo.repositoryURL

        let releaseInfo = UpdateReleaseInfo(
            version: cleanVersion,
            title: title,
            notes: notes,
            releaseURL: releaseURL,
            assetName: asset.name,
            downloadURL: asset.url,
            assetSize: asset.size
        )
        self.currentRelease = releaseInfo
        self.state = .available(releaseInfo)
    }

    // MARK: - 下载并安装

    /// 开始下载并按照苹果规范校验后替换安装
    func startInstall() {
        guard case .available(let info) = state, currentRelease != nil else { return }
        state = .downloading(progress: 0.0)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DockTouchBarUpdate-\(UUID().uuidString)")
        self.currentTempDir = tempDir
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.downloadSession = session

        var request = URLRequest(url: info.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("DockTouchBar/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        self.downloadTask = task
        task.resume()
    }

    /// 取消下载
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        if let dir = currentTempDir {
            try? FileManager.default.removeItem(at: dir)
            currentTempDir = nil
        }
        if let release = currentRelease {
            state = .available(release)
        } else {
            state = .idle
        }
    }

    // MARK: - 解包、安全校验与安装替换

    private func processDownloadedFile(at downloadedLocation: URL) {
        guard let tempDir = currentTempDir, let release = currentRelease else {
            DispatchQueue.main.async { self.state = .failed(L10n.tr("升级临时目录无效", "Invalid update directory")) }
            return
        }

        let localFile = tempDir.appendingPathComponent(release.assetName)
        do {
            try FileManager.default.moveItem(at: downloadedLocation, to: localFile)
        } catch {
            DispatchQueue.main.async {
                self.state = .failed(L10n.tr("保存安装文件失败：\(error.localizedDescription)", "Failed to save downloaded file"))
            }
            return
        }

        DispatchQueue.main.async { self.state = .verifying }

        // 在后台线程解包与校验
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let extractedAppURL = try self.extractApp(from: localFile, in: tempDir)
                // 苹果安全规范校验（代码签名、Team ID、Bundle ID 完整性）
                try self.verifyAppleCodeSignature(for: extractedAppURL)

                DispatchQueue.main.async {
                    self.state = .installing
                }

                // 执行替换并重启
                try self.replaceAndRestart(newAppURL: extractedAppURL, tempDir: tempDir)
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 解包 DMG 或 ZIP
    private func extractApp(from packageURL: URL, in workingDir: URL) throws -> URL {
        let isDMG = packageURL.pathExtension.lowercased() == "dmg"
        let isZIP = packageURL.pathExtension.lowercased() == "zip"

        if isDMG {
            return try extractFromDMG(dmgURL: packageURL, workingDir: workingDir)
        } else if isZIP {
            return try extractFromZIP(zipURL: packageURL, workingDir: workingDir)
        } else {
            throw UpdateError.unsupportedPackageFormat
        }
    }

    private func extractFromDMG(dmgURL: URL, workingDir: URL) throws -> URL {
        // 使用 hdiutil attach 挂载
        let attachProcess = Process()
        attachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProcess.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]

        let pipe = Pipe()
        attachProcess.standardOutput = pipe
        attachProcess.standardError = Pipe()
        try attachProcess.run()
        attachProcess.waitUntilExit()

        guard attachProcess.terminationStatus == 0 else {
            throw UpdateError.failedToMountDMG
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        var mountPoint: String?
        if let plist = try? PropertyListSerialization.propertyList(from: outputData, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let point = entity["mount-point"] as? String {
                    mountPoint = point
                    break
                }
            }
        }

        guard let mount = mountPoint else {
            throw UpdateError.failedToFindMountPoint
        }

        defer {
            // 确保卸载 DMG
            let detachProcess = Process()
            detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachProcess.arguments = ["detach", mount, "-force"]
            try? detachProcess.run()
            detachProcess.waitUntilExit()
        }

        let mountedAppURL = URL(fileURLWithPath: mount).appendingPathComponent("DockTouchBar.app")
        guard FileManager.default.fileExists(atPath: mountedAppURL.path) else {
            throw UpdateError.appNotFoundInPackage
        }

        let targetAppURL = workingDir.appendingPathComponent("DockTouchBar.app")
        if FileManager.default.fileExists(atPath: targetAppURL.path) {
            try? FileManager.default.removeItem(at: targetAppURL)
        }

        // 使用 ditto 或 cp 完整复制（保留所有权限和扩展属性）
        let copyProcess = Process()
        copyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copyProcess.arguments = [mountedAppURL.path, targetAppURL.path]
        try copyProcess.run()
        copyProcess.waitUntilExit()

        guard copyProcess.terminationStatus == 0, FileManager.default.fileExists(atPath: targetAppURL.path) else {
            throw UpdateError.failedToCopyApp
        }

        return targetAppURL
    }

    private func extractFromZIP(zipURL: URL, workingDir: URL) throws -> URL {
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-x", "-k", zipURL.path, workingDir.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        guard unzipProcess.terminationStatus == 0 else {
            throw UpdateError.failedToExtractZIP
        }

        let appURL = workingDir.appendingPathComponent("DockTouchBar.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw UpdateError.appNotFoundInPackage
        }
        return appURL
    }

    // MARK: - 苹果安全规范代码签名验证

    /// 严格验证新 App 的代码签名完整性和 Team ID
    private func verifyAppleCodeSignature(for appURL: URL) throws {
        // 1. 验证签名完整性（无篡改）
        let verifyProcess = Process()
        verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProcess.arguments = ["--verify", "--deep", "--strict", appURL.path]
        try verifyProcess.run()
        verifyProcess.waitUntilExit()

        guard verifyProcess.terminationStatus == 0 else {
            throw UpdateError.codeSignatureInvalid
        }

        // 2. 检查 Bundle Identifier
        let infoPlistPath = appURL.appendingPathComponent("Contents/Info.plist").path
        guard let infoData = try? Data(contentsOf: URL(fileURLWithPath: infoPlistPath)),
              let infoPlist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let bundleID = infoPlist["CFBundleIdentifier"] as? String,
              bundleID == "com.maohuhu.docktouchbar" else {
            throw UpdateError.bundleIDMismatch
        }

        // 3. 检查 Team ID 是否与当前 App 一致（防止冒名替换）
        let currentTeamID = Self.extractTeamID(for: Bundle.main.bundleURL)
        let newTeamID = Self.extractTeamID(for: appURL)

        if let currentTeamID, !currentTeamID.isEmpty {
            guard newTeamID == currentTeamID else {
                throw UpdateError.teamIDMismatch
            }
        }
    }

    private static func extractTeamID(for bundleURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", bundleURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("TeamIdentifier=") {
                return line.replacingOccurrences(of: "TeamIdentifier=", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - 替换并重启

    private func replaceAndRestart(newAppURL: URL, tempDir: URL) throws {
        let targetAppURL = Bundle.main.bundleURL
        let currentPID = ProcessInfo.processInfo.processIdentifier

        // 编写安全的外部替换重启脚本
        let scriptURL = tempDir.appendingPathComponent("update_and_restart.sh")
        let scriptContent = """
        #!/bin/bash
        set -e
        PID="\(currentPID)"
        SRC="\(newAppURL.path)"
        DEST="\(targetAppURL.path)"
        TEMP="\(tempDir.path)"

        # 等待旧进程安全退出（最多等待 10 秒）
        for i in {1..50}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done

        # 替换 App
        if [ -d "$SRC" ] && [ -n "$DEST" ]; then
            rm -rf "$DEST"
            cp -R "$SRC" "$DEST"
            # 移除 Gatekeeper 隔离属性，保证更新后无安全阻拦弹窗
            xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
            # 重新打开应用
            open -n "$DEST"
        fi

        # 清理临时文件
        rm -rf "$TEMP"
        exit 0
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 启动后台更新脚本
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptURL.path]
        try launcher.run()

        // 当前应用退出，把控制权交给脚本
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 版本比对算法

    static func isVersion(_ newVer: String, greaterThan currentVer: String) -> Bool {
        let cleanNew = newVer.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))
        let cleanCurrent = currentVer.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))
        let newParts = cleanNew.split(separator: ".").compactMap { Int($0) }
        let currentParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(newParts.count, currentParts.count)
        for i in 0..<maxCount {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            if case .downloading = self.state {
                self.state = .downloading(progress: progress)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        processDownloadedFile(at: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            DispatchQueue.main.async {
                self.state = .failed(L10n.tr("下载出错：\(error.localizedDescription)", "Download error: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - 错误定义

enum UpdateError: LocalizedError {
    case unsupportedPackageFormat
    case failedToMountDMG
    case failedToFindMountPoint
    case appNotFoundInPackage
    case failedToCopyApp
    case failedToExtractZIP
    case codeSignatureInvalid
    case bundleIDMismatch
    case teamIDMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedPackageFormat:
            return L10n.tr("不支持的安装包格式", "Unsupported package format")
        case .failedToMountDMG:
            return L10n.tr("无法挂载更新镜像 (DMG)", "Failed to mount DMG image")
        case .failedToFindMountPoint:
            return L10n.tr("找不到镜像挂载路径", "Failed to locate DMG mount point")
        case .appNotFoundInPackage:
            return L10n.tr("安装包中未找到应用实体", "DockTouchBar.app not found in package")
        case .failedToCopyApp:
            return L10n.tr("解压应用失败", "Failed to extract application")
        case .failedToExtractZIP:
            return L10n.tr("解压 ZIP 安装包失败", "Failed to unzip package")
        case .codeSignatureInvalid:
            return L10n.tr("安装包代码签名验证未通过，已被安全拦截", "Code signature verification failed (blocked for security)")
        case .bundleIDMismatch:
            return L10n.tr("安装包应用标识不匹配", "Bundle Identifier mismatch")
        case .teamIDMismatch:
            return L10n.tr("开发者签名证书不一致，已被安全拦截", "Developer Team ID mismatch (blocked for security)")
        }
    }
}
