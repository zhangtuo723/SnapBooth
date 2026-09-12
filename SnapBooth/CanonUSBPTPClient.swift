import Foundation
@preconcurrency import ImageCaptureCore
import UIKit

/// iPad transport: public ImageCaptureCore PTP passthrough. EOS operation/property
/// numbers are documented by gphoto/libgphoto2 (camlibs/ptp2/ptp.h).
/// No libusb, private iOS API or Mac helper is used here.
// Public entry points and delegate callbacks are used on the main thread.
final class CanonUSBPTPClient: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, @unchecked Sendable {
    static let cameraID = "canon-ipad-usb-ptp"
    static let displayName = "佳能 USB · Type-C 遥控"
    var onState: ((CameraService.State) -> Void)?
    var onFrame: ((UIImage) -> Void)?
    var previewEnabled = true
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var worker: Task<Void, Never>?
    private var wanted = false
    private var browsing = false
    private var authorizing = false
    private var transaction: UInt32 = 0
    private var pending: CheckedContinuation<Data, Error>?
    private var pendingID = UUID()
    private var timeout: Task<Void, Never>?
    private var openCompletion: CheckedContinuation<Void, Error>?
    private var captureRequest: ((Result<UIImage, Error>) -> Void)?
    private var recovering = false
    private var ready = false
    private var transportValid = false
    private var deviceReady = false
    private var commandLogCount = 0
    private var properties: [UInt32: UInt32] = [:]
    private var originalProperties: [UInt32: UInt32] = [:]
    private var lastNewHandles = Set<UInt32>()
    private struct PhotoObject {
        let format: UInt16
        let size: UInt32
        let needsTransferComplete: Bool
    }
    private var photoObjects: [UInt32: PhotoObject] = [:]
    private var observedPhotoHandles = Set<UInt32>()
    private let diagnosticQueue = DispatchQueue(label: "snapbooth.usb.diagnostics")
    private var captureArmed = false
    private var catalogComplete = false
    private var captureBaseline = Set<UInt32>()
    private var previewFailureCount = 0

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct ResponseFailure: LocalizedError {
        let operation: UInt16
        let response: UInt16
        var errorDescription: String? {
            String(format: "佳能 USB 指令 %04X 返回 %04X；请检查照片模式、存储卡和相机提示", operation, response)
        }
    }

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    func start() {
        wanted = true
        guard !authorizing else { return }
        if browsing {
            if let camera { open(camera) }
            else { onState?(.unavailable("等待佳能 USB：请用数据线连接，并选择“照片导入/遥控”")) }
            return
        }
        #if !targetEnvironment(macCatalyst)
        authorizing = true
        onState?(.requestingPermission)
        browser.requestControlAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.authorizing = false
                    self.onState?(.unavailable("请允许访问 USB 相机：设置 → 隐私与安全性 → 文件与文件夹 → SnapBooth"))
                    return
                }
                self.browser.requestContentsAuthorization { [weak self] contents in
                    Task { @MainActor in
                        guard let self else { return }
                        self.authorizing = false
                        guard self.wanted else { return }
                        guard contents == .authorized else {
                            self.onState?(.unavailable("未获准读取相机照片，请在系统设置中允许 SnapBooth 访问相机内容"))
                            return
                        }
                        self.beginBrowsing()
                    }
                }
            }
        }
        #else
        beginBrowsing()
        #endif
    }

    private func beginBrowsing() {
        guard wanted else { return }
        browsing = true
        onState?(.unavailable("等待佳能 USB：照片模式 · 照片导入/遥控 · 关闭 Wi-Fi"))
        browser.start()
    }

    func stop() {
        wanted = false
        ready = false
        worker?.cancel()
        completeCapture(.failure(CancellationError()))
        // Keep the browser alive to receive unplug/replug events. The worker
        // serially restores settings and closes its session before another opens.
    }

    func capture(recover: Bool = false, completion: @escaping (Result<UIImage, Error>) -> Void) {
        guard wanted, ready, captureRequest == nil else {
            completion(.failure(Failure(message: "USB 相机尚未就绪或仍在处理上一张照片")))
            return
        }
        recovering = recover
        captureRequest = completion
    }

    private func completeCapture(_ result: Result<UIImage, Error>) {
        let completion = captureRequest
        captureRequest = nil
        completion?(result)
    }

    private func open(_ device: ICCameraDevice) {
        guard wanted, worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            do {
                self.log("opening session")
                self.onState?(.unavailable("正在连接佳能 USB…"))
                self.deviceReady = false
                if !device.hasOpenSession {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.openCompletion = continuation
                        device.requestOpenSession()
                        self.timeout = Task {
                            try? await Task.sleep(for: .seconds(15))
                            guard !Task.isCancelled, self.openCompletion != nil else { return }
                            let pending = self.openCompletion
                            self.openCompletion = nil
                            pending?.resume(throwing: Failure(message: "打开 USB 相机会话超时，请重插数据线"))
                        }
                    }
                }
                try Task.checkCancellation()
                try await self.waitUntilReady(device)
                self.transportValid = true
                _ = try await self.command(0x1001) // GetDeviceInfo: validate transport first.
                _ = try await self.command(0x9114, [1]) // EOS SetRemoteMode
                _ = try await self.command(0x9115, [1]) // EOS SetEventMode
                self.properties.removeAll()
                self.originalProperties.removeAll()
                try await self.events()
                self.originalProperties = self.properties
                // Store photographs on the camera card; never delete an object.
                try await self.setProperty(0xD11C, 1)
                try await self.events()
                self.ready = true
                self.onState?(.remoteReady(device.name ?? "佳能 USB"))
                self.previewFailureCount = 0
                while self.wanted && !Task.isCancelled {
                    if self.captureRequest != nil {
                        do {
                            self.onState?(.unavailable(self.recovering ? "正在读取本次未取回的 USB 照片…" : "正在触发佳能快门并读取照片…"))
                            let image = try await self.takePhoto(recover: self.recovering)
                            try Task.checkCancellation()
                            self.completeCapture(.success(image))
                            self.onState?(.remoteReady(device.name ?? "佳能 USB"))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            self.completeCapture(.failure(error))
                            guard self.transportValid, self.camera === device, device.hasOpenSession else { throw error }
                            self.onState?(.unavailable(error.localizedDescription))
                            // Explicitly reconnect after an uncertain shot; never
                            // automatically resend the shutter or report success.
                            throw error
                        }
                    } else if self.previewEnabled {
                        do {
                            if (self.properties[0xD1B0] ?? 0) & 2 == 0 {
                                try await self.setProperty(0xD1B1, 1)
                                try await self.setProperty(0xD1B0, (self.properties[0xD1B0] ?? 1) | 2)
                            }
                            let bytes = try await self.command(0x9153, [0x00200000, 0, 0])
                            guard let image = Self.previewImage(bytes) else {
                                throw Failure(message: "相机尚未输出 USB 取景图像")
                            }
                            if !Task.isCancelled && self.wanted { self.onFrame?(image) }
                            if self.previewFailureCount >= 5 { self.onState?(.remoteReady(device.name ?? "佳能 USB")) }
                            self.previewFailureCount = 0
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            guard self.transportValid, self.camera === device, device.hasOpenSession else { throw error }
                            self.previewFailureCount += 1
                            if self.previewFailureCount == 5 {
                                self.onState?(.remoteReady("USB 已连接，取景暂不可用"))
                            }
                        }
                    }
                    try await self.events()
                    try await Task.sleep(for: .milliseconds(self.previewFailureCount > 0 ? 650 : 180))
                }
            } catch {
                self.ready = false
                failed = !(error is CancellationError)
                self.completeCapture(.failure(error))
                if self.wanted && failed { self.onState?(.unavailable(error.localizedDescription)) }
            }
            self.ready = false
            // Only restore values learned from the camera, never guessed defaults.
            if self.camera === device && device.hasOpenSession {
                for property: UInt32 in [0xD1B0, 0xD1B1, 0xD11C] {
                    if let original = self.originalProperties[property] {
                        try? await self.setProperty(property, original)
                    }
                }
                try? await device.requestCloseSession()
            }
            self.deviceReady = false
            self.transportValid = false
            self.worker = nil
            // A new start received while a previous session was closing can resume.
            if self.wanted, let current = self.camera, !failed || current !== device { self.open(current) }
        }
    }

    private func waitUntilReady(_ device: ICCameraDevice) async throws {
        onState?(.unavailable("已识别佳能，正在等待系统准备相机…"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard camera === device, device.hasOpenSession else {
                throw Failure(message: "相机会话已断开，请重新连接 USB")
            }
            if deviceReady && device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) {
                log("ready; PTP supported")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        log("readiness timeout; ready=\(deviceReady); capabilities=\(device.capabilities)")
        throw Failure(message: deviceReady
            ? "系统未开放相机 PTP 控制，请检查“照片导入/遥控”模式并关闭其他相机 App"
            : "系统尚未完成相机初始化，请关闭其他相机 App 后重插 USB；存储卡照片较多时可能需要更久")
    }

    /// Bounded on-device diagnostics: protocol status only, no image data,
    /// camera serial number, filenames or credentials. Available in Files.
    private func log(_ message: String) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("USB-connection.log")
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        diagnosticQueue.sync {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 128_000 || !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private func takePhoto(recover: Bool) async throws -> UIImage {
        if recover {
            guard !lastNewHandles.isEmpty else {
                throw Failure(message: "没有本次拍摄的待取回照片；为避免误用旧照片，请重新连接后拍摄")
            }
            return try await downloadJPEG(from: lastNewHandles)
        }
        // Drain pre-existing events before arming, so old camera files cannot
        // be mistaken for this shutter's output. EOS remote mode can return an
        // empty standard GetObjectHandles list; events are the primary source.
        try await events()
        let before = try await handles()
        captureBaseline = before.union(photoObjects.keys).union(observedPhotoHandles)
        lastNewHandles.removeAll()
        captureArmed = true
        defer { captureArmed = false }
        log("capture armed; baselineCount=\(captureBaseline.count)")
        try Task.checkCancellation()
        // Half press (AF), full press, then release both positions. Flash is
        // controlled by the camera's photo/flash settings, not the iPad LED toggle.
        do {
            _ = try await command(0x9128, [1, 0])
            try Task.checkCancellation()
            _ = try await command(0x9128, [2, 0])
        } catch {
            _ = try? await command(0x9129, [2])
            _ = try? await command(0x9129, [1])
            throw error
        }
        _ = try await command(0x9129, [2])
        _ = try await command(0x9129, [1])
        onState?(.unavailable("快门已触发，等待相机写入 JPEG…"))
        let deadline = Date().addingTimeInterval(60)
        var nextListCheck = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            try await events()
            if lastNewHandles.isEmpty && Date() >= nextListCheck {
                lastNewHandles.formUnion(try await handles().subtracting(captureBaseline))
                nextListCheck = Date().addingTimeInterval(2)
            }
            if !lastNewHandles.isEmpty {
                do { return try await downloadJPEG(from: lastNewHandles) }
                catch let error as ResponseFailure where error.response == 0x2019 || error.response == 0x2009 {
                    // Camera still writing; reading may retry, shutter may not.
                } catch let error as Failure where error.message == "等待新增 JPEG" {}
            }
            try await Task.sleep(for: .milliseconds(450))
        }
        throw Failure(message: "相机未返回本次 JPEG。请检查写卡、JPEG 格式和曝光状态，不要连续重复拍摄")
    }

    private func handles() async throws -> Set<UInt32> {
        let data = try await command(0x1007, [0xFFFFFFFF, 0, 0])
        guard let count = data.usbU32(0), count <= 200_000, data.count >= 4 + Int(count) * 4 else {
            throw Failure(message: "USB 相机返回了无效的文件列表")
        }
        return Set((0..<Int(count)).compactMap { data.usbU32(4 + $0 * 4) })
    }

    private func downloadJPEG(from handles: Set<UInt32>) async throws -> UIImage {
        for handle in handles.sorted().reversed() {
            try Task.checkCancellation()
            let object: PhotoObject
            if let cached = photoObjects[handle] { object = cached }
            else {
                onState?(.unavailable("已发现新照片，正在读取照片信息…"))
                let info = try await command(0x1008, [handle])
                log("object info bytes=\(info.count) header=\(info.prefix(32).map { String(format: "%02X", $0) }.joined())")
                guard info.count >= 52, let format = info.usbU16(4), let size = info.usbU32(8) else {
                    throw Failure(message: "USB 照片信息不完整")
                }
                object = PhotoObject(format: format, size: size, needsTransferComplete: false)
                photoObjects[handle] = object
            }
            guard object.format == 0x3801 else { continue }
            let size = object.size
            guard size > 0, size <= 100_000_000 else { throw Failure(message: "照片大小异常，无法读取") }
            log("JPEG found; bytes=\(size); eventMetadata=\(photoObjects[handle] != nil)")
            var data = Data()
            data.reserveCapacity(Int(size))
            let downloadDeadline = ContinuousClock.now.advanced(by: .seconds(90))
            while data.count < Int(size) {
                try Task.checkCancellation()
                guard ContinuousClock.now < downloadDeadline else { throw Failure(message: "JPEG 下载超时，请重连后取回本次照片") }
                let count = min(UInt32(1024 * 1024), size - UInt32(data.count))
                onState?(.unavailable("正在下载照片 \(data.count * 100 / Int(size))%"))
                let chunk: Data
                do { chunk = try await command(0x9107, [handle, UInt32(data.count), count], seconds: 20) }
                catch let error as ResponseFailure where error.response == 0x2005 {
                    chunk = try await command(0x101B, [handle, UInt32(data.count), count], seconds: 20)
                }
                guard !chunk.isEmpty, chunk.count <= Int(count) else { throw Failure(message: "USB 照片分块长度异常，请重连后取回") }
                data.append(chunk)
            }
            guard data.count == Int(size), let image = UIImage(data: data) else {
                throw Failure(message: "USB JPEG 未完整下载或无法解码，请重连后取回照片")
            }
            if object.needsTransferComplete { _ = try await command(0x9117, [handle]) }
            log("JPEG download complete; bytes=\(data.count)")
            return image
        }
        throw Failure(message: "等待新增 JPEG")
    }

    private func setProperty(_ property: UInt32, _ value: UInt32) async throws {
        var bytes = Data()
        bytes.usbAppend(UInt32(12)); bytes.usbAppend(property); bytes.usbAppend(value)
        _ = try await command(0x9110, out: bytes)
        properties[property] = value
    }

    private func events() async throws {
        let bytes = try await command(0x9116)
        var offset = 0
        while let length = bytes.usbU32(offset), length >= 8, Int(length) <= bytes.count - offset {
            if bytes.usbU32(offset + 4) == 0xC189, length >= 16,
               let property = bytes.usbU32(offset + 8), let value = bytes.usbU32(offset + 12) {
                properties[property] = value
            }
            if let code = bytes.usbU32(offset + 4) {
                // R50 V emits ObjectAddedEx64LFN (C1B6), not the older C181.
                // Keep its handle and query ObjectInfo rather than treating the
                // variable-length record as one of the older fixed layouts.
                if code == 0xC1B6, length >= 12, let handle = bytes.usbU32(offset + 8) {
                    observedPhotoHandles.insert(handle)
                    if captureArmed && !captureBaseline.contains(handle) {
                        lastNewHandles.insert(handle)
                        log("C1B6 new object; metadata query queued")
                    }
                }
                let transfer = [UInt32(0xC186), 0xC1A9, 0xC1B8].contains(code)
                let added = [UInt32(0xC181), 0xC1A7].contains(code)
                if transfer || added {
                    let formatOffset = transfer ? 12 : 16
                    let sizeOffset = transfer ? 20 : 28
                    if length >= sizeOffset + 4,
                       let handle = bytes.usbU32(offset + 8),
                       let format = bytes.usbU16(offset + formatOffset),
                       let size = bytes.usbU32(offset + sizeOffset) {
                        recordPhoto(handle: handle, object: PhotoObject(format: format, size: size, needsTransferComplete: transfer))
                    }
                }
                if captureArmed && code != 0 && code != 0xC189 {
                    log(String(format: "capture event=%04X length=%u", code, length))
                }
            }
            offset += Int(length)
        }
    }

    private func recordPhoto(handle: UInt32, object: PhotoObject) {
        photoObjects[handle] = object
        observedPhotoHandles.insert(handle)
        if captureArmed && !captureBaseline.contains(handle) {
            lastNewHandles.insert(handle)
            log(String(format: "new photo event format=%04X size=%u", object.format, object.size))
        }
    }

    // All operations run in the one worker. Timeout invalidates the session so
    // a late response cannot interleave with another command or another capture.
    private func command(_ operation: UInt16, _ parameters: [UInt32] = [], out: Data? = nil, seconds: Double = 15) async throws -> Data {
        guard transportValid, let device = camera, device.hasOpenSession else { throw Failure(message: "USB 相机已断开，请重插数据线") }
        guard pending == nil else { throw Failure(message: "USB 相机正在处理其他指令") }
        transaction &+= 1
        let currentTransaction = transaction
        var packet = Data()
        packet.usbAppend(UInt32(12 + parameters.count * 4))
        packet.usbAppend(UInt16(1)); packet.usbAppend(operation); packet.usbAppend(transaction)
        parameters.forEach { packet.usbAppend($0) }
        let id = UUID()
        commandLogCount += 1
        let shouldLog = commandLogCount <= 20 || ![UInt16(0x9116), UInt16(0x9153)].contains(operation)
        if shouldLog { log(String(format: "send op=%04X transaction=%u bytes=%d", operation, currentTransaction, packet.count)) }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            pendingID = id
            timeout = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, self.pendingID == id, self.pending != nil else { return }
                self.log(String(format: "timeout op=%04X session=%@ ready=%@", operation, String(device.hasOpenSession), String(self.deviceReady)))
                self.transportValid = false
                self.finish(.failure(Failure(message: String(format: "USB 指令 %04X 超时。请重连相机；若已响快门，先检查存储卡，不要重复拍摄", operation))))
                try? await device.requestCloseSession()
            }
            device.requestSendPTPCommand(packet, outData: out) { [weak self] data, response, error in
                Task { @MainActor in
                    guard let self, self.pendingID == id, self.pending != nil else { return }
                    if let error { self.log("PTP callback error: \(error.localizedDescription)"); self.finish(.failure(error)); return }
                    if shouldLog { self.log("callback dataBytes=\(data.count) response=\(response.prefix(32).map { String(format: "%02X", $0) }.joined())") }
                    // ImageCaptureCore owns the underlying USB session and may
                    // assign its own wire transaction ID (observed on R50 V:
                    // local 1 -> wire 0x128E). Correlate with this callback's UUID
                    // and device identity, not with our submitted transaction ID.
                    guard self.camera === device, self.transportValid,
                          response.count >= 12,
                          let length = response.usbU32(0),
                          length == response.count, length <= 32, (length - 12) % 4 == 0,
                          response.usbU16(4) == 3,
                          let code = response.usbU16(6) else {
                        self.finish(.failure(Failure(message: "USB 相机返回了无效响应，请重连")))
                        self.transportValid = false
                        try? await device.requestCloseSession()
                        return
                    }
                    if code == 0x2001 { self.finish(.success(data)) }
                    else { self.finish(.failure(ResponseFailure(operation: operation, response: code))) }
                }
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }

    private static func previewImage(_ data: Data) -> UIImage? {
        // EOS returns a container of viewfinder records; JPEG markers delimit
        // the image inside it. Do not decode the metadata as an image.
        guard let start = data.range(of: Data([0xFF, 0xD8, 0xFF])),
              let end = data.range(of: Data([0xFF, 0xD9]), options: .backwards), end.upperBound > start.lowerBound else { return nil }
        return UIImage(data: data.subdata(in: start.lowerBound..<end.upperBound))
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let candidate = device as? ICCameraDevice,
              (candidate.name ?? "").localizedCaseInsensitiveContains("Canon"), camera == nil else { return }
        log("discovered Canon; transport=\(candidate.transportType ?? "unknown"); capabilities=\(candidate.capabilities)")
        commandLogCount = 0
        deviceReady = false
        photoObjects.removeAll()
        observedPhotoHandles.removeAll()
        catalogComplete = false
        captureArmed = false
        camera = candidate
        candidate.delegate = self
        if wanted { open(candidate) }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) { disconnected(device) }
    func didRemove(_ device: ICDevice) { disconnected(device) }
    private func disconnected(_ device: ICDevice) {
        guard camera === device else { return }
        log("disconnected")
        camera = nil
        catalogComplete = false
        captureArmed = false
        photoObjects.removeAll()
        observedPhotoHandles.removeAll()
        deviceReady = false
        transportValid = false
        ready = false
        lastNewHandles.removeAll()
        worker?.cancel()
        let error = Failure(message: "佳能 USB 已断开，请检查 Type-C 数据线")
        finish(.failure(error))
        let opening = openCompletion; openCompletion = nil
        opening?.resume(throwing: error)
        completeCapture(.failure(error))
        if wanted { onState?(.unavailable(error.message)) }
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard camera === device, openCompletion != nil else { return }
        timeout?.cancel(); timeout = nil
        let opening = openCompletion; openCompletion = nil
        log("session opened; error=\(error?.localizedDescription ?? "none")")
        if let error { opening?.resume(throwing: error) }
        else { opening?.resume() }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard camera === device else { return }
        deviceReady = false
        transportValid = false
        log("session closed; error=\(error?.localizedDescription ?? "none")")
    }
    func deviceDidBecomeReady(_ device: ICDevice) {
        guard camera === device else { return }
        deviceReady = true
        log("device ready callback; capabilities=\(device.capabilities)")
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard camera === device else { return }
        deviceReady = true
        catalogComplete = true
        log("content catalog ready; capabilities=\(device.capabilities)")
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard self.camera === camera else { return }
        for case let file as ICCameraFile in items {
            let name = (file.name ?? "").lowercased()
            guard name.hasSuffix(".jpg") || name.hasSuffix(".jpeg"), file.fileSize > 0, file.fileSize <= 100_000_000 else { continue }
            let object = PhotoObject(format: 0x3801, size: UInt32(file.fileSize), needsTransferComplete: false)
            // Enumeration callbacks before catalogue completion describe old
            // files. Store them as baseline metadata only, never as new shots.
            if catalogComplete { recordPhoto(handle: file.ptpObjectHandle, object: object) }
            else { photoObjects[file.ptpObjectHandle] = object }
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        guard self.camera === camera else { return }
        log("capabilities changed: \(camera.capabilities)")
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

private extension Data {
    mutating func usbAppend<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func usbU16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
    func usbU32(_ offset: Int) -> UInt32? {
        guard let low = usbU16(offset), let high = usbU16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }
}
