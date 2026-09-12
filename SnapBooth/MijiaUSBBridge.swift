import Foundation

#if targetEnvironment(macCatalyst)
import Darwin

enum MijiaUSBBridge {
    struct Status {
        let firmware: String
        let model: String
        let printerState: String
        let printerSubstate: String
        let alert: String

        var isReady: Bool { alert == "::0" }
    }

    static func status() throws -> Status {
        let object = try run(arguments: ["status"])
        guard
            let statusObject = object["status"] as? [String: Any],
            let statusValues = statusObject["result"] as? [String],
            statusValues.count >= 3,
            let infoObject = object["deviceInfo"] as? [String: Any],
            let infoValues = infoObject["result"] as? [[String: Any]],
            let info = infoValues.first
        else {
            throw BridgeError.invalidResponse("打印机返回了无法识别的状态")
        }
        return Status(
            firmware: info["fw_ver"] as? String ?? "未知",
            model: info["model"] as? String ?? "xiaomi.printer.syrup",
            printerState: statusValues[0],
            printerSubstate: statusValues[1],
            alert: statusValues[2]
        )
    }

    static func printSixInchJPEG(at url: URL) throws -> Int {
        // SnapBooth deliberately supports only the printer's standard
        // 6-inch photo path. Keeping these identifiers fixed prevents a UI
        // selection from creating a job for media that is not loaded.
        let object = try run(arguments: ["print", url.path, "5012", "2010"])
        guard let jobID = object["jobId"] as? NSNumber else {
            throw BridgeError.invalidResponse("打印机没有返回任务编号")
        }
        return jobID.intValue
    }

    private static func run(arguments: [String]) throws -> [String: Any] {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("MijiaUSBHelper", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw BridgeError.helperMissing
        }

        let command = [helperURL.path] + arguments
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw BridgeError.launchFailed(String(cString: strerror(errno)))
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])

        var cArguments = command.map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                if let argument { Darwin.free(UnsafeMutableRawPointer(argument)) }
            }
            posix_spawn_file_actions_destroy(&actions)
        }
        var processID: pid_t = 0
        let spawnResult = cArguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&processID, helperURL.path, &actions, nil, buffer.baseAddress, environ)
        }
        close(descriptors[1])
        guard spawnResult == 0 else {
            close(descriptors[0])
            throw BridgeError.launchFailed(String(cString: strerror(spawnResult)))
        }

        let output = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let data = output.readDataToEndOfFile()
        var waitStatus: Int32 = 0
        guard waitpid(processID, &waitStatus, 0) == processID else {
            throw BridgeError.launchFailed(String(cString: strerror(errno)))
        }
        let terminationStatus = (waitStatus >> 8) & 0xff
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let detail = String(data: data, encoding: .utf8) ?? "无返回内容"
            throw BridgeError.invalidResponse(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if terminationStatus != 0 || object["ok"] as? Bool != true {
            let detail = object["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "USB 辅助程序执行失败"
            throw BridgeError.helperFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return object
    }
}

private enum BridgeError: LocalizedError {
    case helperMissing
    case launchFailed(String)
    case helperFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "App 中缺少米家 USB 辅助程序，请重新构建 Mac 版"
        case .launchFailed(let detail):
            return "无法启动米家 USB 辅助程序：\(detail)"
        case .helperFailed(let detail), .invalidResponse(let detail):
            return detail
        }
    }
}
#endif
