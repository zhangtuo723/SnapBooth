import Foundation
import ImageIO
import UIKit
#if targetEnvironment(macCatalyst)
import Darwin
#endif

/// Mac-only Canon USB remote control backed by the locally installed gphoto2.
/// The camera stays in “照片导入/遥控”; real shutter capture therefore fires a
/// hot-shoe flash, unlike an AVFoundation/UVC frame grab.
final class CanonRemoteBridge {
    static let cameraID = "canon-usb-remote"
    static let displayName = "佳能 EOS R50 V · 遥控/闪光"

    enum BridgeError: LocalizedError {
        case toolMissing
        case cameraMissing
        case commandFailed(String)
        case commandTimedOut
        case noNewPhoto
        case invalidPhoto(String)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "未找到佳能遥控组件 gphoto2"
            case .cameraMissing:
                return "未发现处于“照片导入/遥控”模式的佳能相机"
            case .commandFailed(let detail):
                return detail.isEmpty ? "佳能相机命令失败" : "佳能相机命令失败：\(detail)"
            case .commandTimedOut:
                return "相机响应超时，请确认相机和闪光灯已就绪"
            case .noNewPhoto:
                return "快门已触发，但没有在 SD 卡中找到新照片"
            case .invalidPhoto(let detail):
                return detail.isEmpty ? "已下载照片，但无法读取图像数据" : "照片解码失败：\(detail)"
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private struct CameraFile: Equatable {
        let index: Int
        let name: String
    }

    private struct CommandResult {
        let output: String
        let status: Int32
        let timedOut: Bool
    }

    private let fileManager = FileManager.default
    private var helperPID: pid_t = 0
    private var helperInput: Int32 = -1
    private var helperOutput: Int32 = -1

    deinit {
        stopSession()
    }

    func isAvailable() -> Bool {
        if helperPID > 0 { return true }
        guard gphotoURL != nil else { return false }
        do {
            let result = try runGPhoto(["--auto-detect"], timeout: 5)
            return result.status == 0 && result.output.localizedCaseInsensitiveContains("Canon EOS R50 V")
        } catch {
            return false
        }
    }

    func preview() throws -> UIImage {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("SnapBooth-CanonPreview-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let destination = folder.appendingPathComponent("preview.jpg")
        do {
            try ensureSession()
            let response = try exchange("PREVIEW\t\(destination.path)", timeout: 4)
            guard response.hasPrefix("OK\tPREVIEW") else {
                throw BridgeError.commandFailed(response)
            }
        } catch {
            stopSession()
            throw error
        }
        return try loadImage(at: destination)
    }

    func capturePhoto() throws -> UIImage {
        stopSession()
        let before = try latestCameraFile()

        // R50 V 1.2.0 sometimes keeps the capture command open after the real
        // shutter has fired. A timeout here is acceptable: we subsequently poll
        // the SD card and fetch the newly-created file as a separate operation.
        _ = try? runGPhoto([
            "--set-config", "/main/settings/capturetarget=1",
            "--capture-image"
        ], timeout: 12)

        var newest: CameraFile?
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let candidate = try? latestCameraFile(), candidate != before,
               before == nil || candidate.index > before!.index || candidate.name != before!.name {
                newest = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.45)
        } while Date() < deadline

        guard newest != nil else { throw BridgeError.noNewPhoto }
        return try downloadLatestThroughHelper()
    }

    func latestPhoto() throws -> UIImage {
        stopSession()
        return try downloadLatestThroughHelper()
    }

    private func downloadLatestThroughHelper() throws -> UIImage {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("SnapBooth-CanonCapture-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let destination = folder.appendingPathComponent("latest-camera-photo.jpg")
        try ensureSession()
        let response = try exchange("LATEST\t\(destination.path)", timeout: 30)
        guard response.hasPrefix("OK\tLATEST\t") else {
            throw BridgeError.commandFailed(response)
        }
        guard fileManager.fileExists(atPath: destination.path) else {
            let actualFiles = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent)
                .joined(separator: ", ")
            throw BridgeError.invalidPhoto(
                "原生助手未生成目标文件；目录内容 [\(actualFiles)]；返回：\(response)"
            )
        }
        return try loadImage(at: destination)
    }

    private func loadImage(at url: URL) throws -> UIImage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw BridgeError.invalidPhoto("文件读取失败：\(error.localizedDescription)")
        }
        guard !data.isEmpty else { throw BridgeError.invalidPhoto("下载文件为空") }
        if let image = UIImage(data: data, scale: 1) { return image }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BridgeError.invalidPhoto("\(data.count) 字节 JPEG 无法创建图像源")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            let status = CGImageSourceGetStatus(source).rawValue
            throw BridgeError.invalidPhoto("\(data.count) 字节，ImageIO 状态 \(status)")
        }
        return UIImage(cgImage: image)
    }

    func stopSession() {
        guard helperPID > 0 else { return }
        _ = try? exchange("QUIT", timeout: 1)
        if helperInput >= 0 { close(helperInput) }
        if helperOutput >= 0 { close(helperOutput) }
        helperInput = -1
        helperOutput = -1

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if waitpid(helperPID, &status, WNOHANG) == helperPID {
                helperPID = 0
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(helperPID, SIGKILL)
        waitpid(helperPID, &status, 0)
        helperPID = 0
    }

    private func latestCameraFile() throws -> CameraFile? {
        let result = try runGPhoto(["--list-files"], timeout: 10)
        guard result.status == 0 else { throw commandError(result) }
        let expression = try NSRegularExpression(
            pattern: #"(?m)^#([0-9]+)\s+([^\s]+\.(?:JPG|JPEG|HEIF|HIF))\s"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(result.output.startIndex..<result.output.endIndex, in: result.output)
        return expression.matches(in: result.output, range: range).compactMap { match in
            guard let indexRange = Range(match.range(at: 1), in: result.output),
                  let nameRange = Range(match.range(at: 2), in: result.output),
                  let index = Int(result.output[indexRange]) else { return nil }
            return CameraFile(index: index, name: String(result.output[nameRange]))
        }.max { $0.index < $1.index }
    }

    private var gphotoURL: URL? {
        ["/opt/homebrew/bin/gphoto2", "/usr/local/bin/gphoto2"]
            .first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CanonRemoteHelper")
    }

    private func ensureSession() throws {
        guard helperPID == 0 else { return }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw BridgeError.commandFailed("佳能持续取景组件缺失")
        }
        releaseSystemCameraClaim()

        var inputPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0, pipe(&outputPipe) == 0 else {
            throw BridgeError.commandFailed("无法创建佳能取景通道")
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(inputPipe[0]); close(inputPipe[1]); close(outputPipe[0]); close(outputPipe[1])
            throw BridgeError.commandFailed("无法初始化佳能取景组件")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, inputPipe[0])
        posix_spawn_file_actions_addclose(&actions, inputPipe[1])
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        posix_spawn_file_actions_addclose(&actions, outputPipe[1])

        var arguments = [strdup(helperURL.path), nil]
        defer { free(arguments[0]) }
        var identifier: pid_t = 0
        let spawnStatus = helperURL.path.withCString { path in
            arguments.withUnsafeMutableBufferPointer { pointers in
                posix_spawn(&identifier, path, &actions, nil, pointers.baseAddress, environ)
            }
        }
        close(inputPipe[0])
        close(outputPipe[1])
        guard spawnStatus == 0 else {
            close(inputPipe[1]); close(outputPipe[0])
            throw BridgeError.commandFailed(String(cString: strerror(spawnStatus)))
        }

        helperPID = identifier
        helperInput = inputPipe[1]
        helperOutput = outputPipe[0]
        do {
            let response = try readHelperLine(timeout: 8)
            guard response.hasPrefix("READY\tCanon EOS R50 V") else {
                throw BridgeError.commandFailed(response)
            }
        } catch {
            stopSession()
            throw error
        }
    }

    private func exchange(_ command: String, timeout: TimeInterval) throws -> String {
        guard helperPID > 0, helperInput >= 0, helperOutput >= 0 else {
            throw BridgeError.cameraMissing
        }
        let payload = Data((command + "\n").utf8)
        let sent = payload.withUnsafeBytes { bytes in
            write(helperInput, bytes.baseAddress, bytes.count)
        }
        guard sent == payload.count else {
            throw BridgeError.commandFailed("佳能取景命令发送失败")
        }
        return try readHelperLine(timeout: timeout)
    }

    private func readHelperLine(timeout: TimeInterval) throws -> String {
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            var descriptor = pollfd(fd: helperOutput, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 { throw BridgeError.commandFailed("佳能取景通道读取失败") }
            if ready == 0 { break }
            var byte: UInt8 = 0
            let count = read(helperOutput, &byte, 1)
            if count <= 0 { break }
            if byte == 10 { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        throw BridgeError.commandTimedOut
    }

    private func commandError(_ result: CommandResult) -> Error {
        if result.timedOut { return BridgeError.commandTimedOut }
        let detail = result.output
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: " ")
        return BridgeError.commandFailed(detail)
    }

    private func runGPhoto(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard let executable = gphotoURL else { throw BridgeError.toolMissing }
        releaseSystemCameraClaim()
        return try runExecutable(executable, arguments: arguments, timeout: timeout)
    }

    private func releaseSystemCameraClaim() {
        for name in ["ptpcamerad", "mscamerad-xpc", "icdd"] {
            _ = try? runExecutable(
                URL(fileURLWithPath: "/usr/bin/pkill"),
                arguments: ["-9", "-x", name],
                timeout: 1
            )
        }
    }

    /// Foundation.Process is unavailable to Mac Catalyst. posix_spawn remains
    /// available and lets us launch one explicit, allow-listed executable while
    /// keeping stdout/stderr bounded in a temporary file.
    private func runExecutable(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("SnapBooth-Command-\(UUID().uuidString).log")
        let descriptor = outputURL.path.withCString {
            open($0, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw BridgeError.commandFailed("无法创建命令输出文件") }
        defer {
            close(descriptor)
            try? fileManager.removeItem(at: outputURL)
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw BridgeError.commandFailed("无法初始化相机命令")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptor, STDERR_FILENO)

        let values = [executable.path] + arguments
        var storage = values.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        storage.append(nil)

        var identifier: pid_t = 0
        let spawnStatus = executable.path.withCString { path in
            storage.withUnsafeMutableBufferPointer { pointers in
                posix_spawn(&identifier, path, &actions, nil, pointers.baseAddress, environ)
            }
        }
        guard spawnStatus == 0 else {
            throw BridgeError.commandFailed(String(cString: strerror(spawnStatus)))
        }

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var completed = false
        while Date() < deadline {
            if waitpid(identifier, &waitStatus, WNOHANG) == identifier {
                completed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let exceededDeadline = !completed
        if !completed {
            kill(identifier, SIGTERM)
            let terminationDeadline = Date().addingTimeInterval(1)
            while Date() < terminationDeadline {
                if waitpid(identifier, &waitStatus, WNOHANG) == identifier {
                    completed = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if !completed {
                kill(identifier, SIGKILL)
                waitpid(identifier, &waitStatus, 0)
            }
        }

        fsync(descriptor)
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let normalExit = (waitStatus & 0x7f) == 0
        let status = normalExit ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
        return CommandResult(
            output: String(decoding: data, as: UTF8.self),
            status: status,
            timedOut: exceededDeadline
        )
    }
    #else
    func isAvailable() -> Bool { false }
    func preview() throws -> UIImage { throw BridgeError.cameraMissing }
    func capturePhoto() throws -> UIImage { throw BridgeError.cameraMissing }
    func latestPhoto() throws -> UIImage { throw BridgeError.cameraMissing }
    func stopSession() {}
    #endif
}
