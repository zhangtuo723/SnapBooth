import AVFoundation
import CoreImage
import SwiftUI
import UIKit

final class CameraService: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case ready
        case remoteReady(String)
        case denied
        case unavailable(String)

        var description: String {
            switch self {
            case .idle: return "尚未启动"
            case .requestingPermission: return "正在请求权限"
            case .ready: return "已连接"
            case .remoteReady(let name): return "\(name) · 真快门/闪光"
            case .denied: return "相机权限未开启"
            case .unavailable(let reason): return reason
            }
        }

        var isReady: Bool {
            switch self {
            case .ready, .remoteReady: return true
            default: return false
            }
        }
    }

    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
        let position: AVCaptureDevice.Position
        let isRemote: Bool
    }

    let session = AVCaptureSession()

    @Published private(set) var state: State = .idle
    @Published private(set) var cameras: [CameraOption] = []
    @Published var selectedCameraID: String?
    @Published private(set) var canonCCAPIAddress = CanonCCAPIClient.savedAddress
    @Published private(set) var canonCCAPIUsername = CanonCCAPIClient.savedUsername
    @Published var capturedImage: UIImage? {
        didSet {
            if selectedCameraID == CanonCCAPIClient.cameraID {
                if capturedImage == nil { startCCAPIPreview() } else { stopCCAPIPreview() }
            }
            #if targetEnvironment(macCatalyst)
            if capturedImage == nil, selectedCameraID == CanonRemoteBridge.cameraID {
                startRemotePreview()
            } else if capturedImage != nil {
                stopRemotePreview()
            }
            #endif
        }
    }
    @Published private(set) var latestFrame: UIImage?
    @Published var flashEnabled = false

    private let sessionQueue = DispatchQueue(label: "app.snapbooth.camera.session")
    private let remoteQueue = DispatchQueue(label: "app.snapbooth.camera.canon-remote", qos: .userInitiated)
    private let remoteBridge = CanonRemoteBridge()
    private let ccapiClient = CanonCCAPIClient()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "snapbooth.video.frames", qos: .userInitiated)
    private let frameContext = CIContext()
    private var lastFrameTime = CMTime.zero
    private var activeInput: AVCaptureDeviceInput?
    private var captureCompletion: ((Result<UIImage, Error>) -> Void)?
    private var remotePreviewTimer: DispatchSourceTimer?
    private var remoteCaptureInProgress = false
    private var ccapiActivationTask: Task<Void, Never>?
    private var ccapiPreviewTask: Task<Void, Never>?
    private var ccapiCaptureTask: Task<Void, Never>?
    private var ccapiCaptureInProgress = false
    private var cameraSelectionWasExplicit = false

    override init() {
        super.init()
        refreshCameras()
    }

    func start() {
        refreshCameras()
        if selectedCameraID == CanonCCAPIClient.cameraID {
            activateCCAPICamera()
            return
        }
        #if targetEnvironment(simulator)
        state = .unavailable("模拟器无相机，请使用示例图片")
        return
        #endif
        #if targetEnvironment(macCatalyst)
        if selectedCameraID == CanonRemoteBridge.cameraID {
            activateRemoteCamera()
            return
        }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.state = .denied
                    }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .unavailable("无法读取相机权限")
        }
    }

    func stop() {
        stopCCAPIPreview()
        ccapiActivationTask?.cancel()
        ccapiActivationTask = nil
        ccapiCaptureTask?.cancel()
        ccapiCaptureTask = nil
        Task { await ccapiClient.stopLiveView() }
        #if targetEnvironment(macCatalyst)
        stopRemotePreview()
        #endif
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func refreshCameras() {
        let devices = Self.discoverVideoDevices()
        var options = devices.map {
            CameraOption(id: $0.uniqueID, name: Self.displayName(for: $0), position: $0.position, isRemote: false)
        }
        #if !targetEnvironment(macCatalyst)
        options.append(CameraOption(
            id: CanonCCAPIClient.cameraID,
            name: CanonCCAPIClient.displayName,
            position: .unspecified,
            isRemote: true
        ))
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.cameras = options
            if self?.selectedCameraID == nil {
                #if targetEnvironment(macCatalyst)
                self?.selectedCameraID = options.first(where: { $0.position == .back })?.id ?? options.first?.id
                #else
                self?.selectedCameraID = CanonCCAPIClient.cameraID
                #endif
            }
        }
        #if targetEnvironment(macCatalyst)
        remoteQueue.async { [weak self] in
            guard let self else { return }
            let available = self.remoteBridge.isAvailable()
            DispatchQueue.main.async {
                var merged = options
                if available {
                    merged.append(CameraOption(
                        id: CanonRemoteBridge.cameraID,
                        name: CanonRemoteBridge.displayName,
                        position: .unspecified,
                        isRemote: true
                    ))
                }
                self.cameras = merged
                if available, !self.cameraSelectionWasExplicit {
                    self.selectedCameraID = CanonRemoteBridge.cameraID
                } else if self.selectedCameraID == nil || !merged.contains(where: { $0.id == self.selectedCameraID }) {
                    self.selectedCameraID = options.first(where: { $0.position == .back })?.id
                        ?? options.first?.id
                        ?? (available ? CanonRemoteBridge.cameraID : nil)
                }
                if self.selectedCameraID == CanonRemoteBridge.cameraID, available {
                    self.activateRemoteCamera()
                }
            }
        }
        #endif
    }

    func selectCamera(id: String) {
        cameraSelectionWasExplicit = true
        if selectedCameraID == id {
            if id == CanonCCAPIClient.cameraID { activateCCAPICamera() }
            return
        }
        selectedCameraID = id
        if id == CanonCCAPIClient.cameraID {
            activateCCAPICamera()
            return
        }
        stopCCAPIPreview()
        Task { await ccapiClient.stopLiveView() }
        #if targetEnvironment(macCatalyst)
        if id == CanonRemoteBridge.cameraID {
            activateRemoteCamera()
            return
        }
        #endif
        #if targetEnvironment(macCatalyst)
        stopRemotePreview()
        #endif
        configureAndStart()
    }

    func capture(completion: @escaping (Result<UIImage, Error>) -> Void) {
        guard state.isReady else {
            completion(.failure(CameraError.notReady))
            return
        }

        if selectedCameraID == CanonCCAPIClient.cameraID {
            captureCCAPI(completion: completion)
            return
        }

        #if targetEnvironment(macCatalyst)
        if selectedCameraID == CanonRemoteBridge.cameraID {
            captureRemote(completion: completion)
            return
        }
        #endif

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            if let device = self.activeInput?.device, device.hasFlash {
                settings.flashMode = self.flashEnabled ? .on : .off
            }
            self.captureCompletion = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func clearCapture() {
        capturedImage = nil
    }

    func recoverLatestRemotePhoto(completion: @escaping (Result<UIImage, Error>) -> Void) {
        if selectedCameraID == CanonCCAPIClient.cameraID {
            recoverLatestCCAPIPhoto(completion: completion)
            return
        }
        #if targetEnvironment(macCatalyst)
        guard selectedCameraID == CanonRemoteBridge.cameraID else {
            completion(.failure(CameraError.notReady))
            return
        }
        remoteQueue.async { [weak self] in
            guard let self else { return }
            self.remoteCaptureInProgress = true
            self.cancelRemotePreviewOnQueue()
            DispatchQueue.main.async {
                self.state = .unavailable("正在读取相机里的最近照片…")
            }
            let result: Result<UIImage, Error>
            do {
                result = .success(try self.remoteBridge.latestPhoto())
            } catch {
                result = .failure(error)
            }
            self.remoteCaptureInProgress = false
            DispatchQueue.main.async {
                if case .success(let image) = result {
                    self.capturedImage = image
                    self.state = .remoteReady("佳能 R50 V")
                } else if case .failure(let error) = result {
                    self.state = .remoteReady("读取失败：\(error.localizedDescription)")
                    self.startRemotePreview()
                }
                completion(result)
            }
        }
        #else
        completion(.failure(CameraError.notReady))
        #endif
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func configureCanonCCAPI(address: String, username: String, password: String) {
        canonCCAPIAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        canonCCAPIUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        ccapiActivationTask?.cancel()
        ccapiActivationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ccapiClient.configure(address: address, username: username, password: password)
                let normalized = await self.ccapiClient.configuredAddress()
                await MainActor.run {
                    self.canonCCAPIAddress = normalized
                    self.selectedCameraID = CanonCCAPIClient.cameraID
                    self.cameraSelectionWasExplicit = true
                }
                self.activateCCAPICamera()
            } catch {
                await MainActor.run { self.state = .unavailable(error.localizedDescription) }
            }
        }
    }

    private func configureAndStart() {
        if selectedCameraID == CanonCCAPIClient.cameraID {
            activateCCAPICamera()
            return
        }
        #if targetEnvironment(macCatalyst)
        if selectedCameraID == CanonRemoteBridge.cameraID {
            activateRemoteCamera()
            return
        }
        #endif
        #if targetEnvironment(macCatalyst)
        stopRemotePreview()
        #endif
        refreshCameras()
        let selectedID = selectedCameraID

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let devices = Self.discoverVideoDevices()
            guard let device = devices.first(where: { $0.uniqueID == selectedID })
                    ?? devices.first(where: { $0.position == .back })
                    ?? devices.first else {
                DispatchQueue.main.async { self.state = .unavailable("未发现可用相机") }
                return
            }

            do {
                if self.activeInput?.device.uniqueID == device.uniqueID {
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.state = .ready }
                    return
                }
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                if let activeInput = self.activeInput {
                    self.session.removeInput(activeInput)
                }
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw CameraError.cannotAddInput
                }
                self.session.addInput(input)
                self.activeInput = input

                if !self.session.outputs.contains(self.videoOutput), self.session.canAddOutput(self.videoOutput) {
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                    self.session.addOutput(self.videoOutput)
                }

                if !self.session.outputs.contains(self.photoOutput) {
                    guard self.session.canAddOutput(self.photoOutput) else {
                        self.session.commitConfiguration()
                        throw CameraError.cannotAddOutput
                    }
                    self.session.addOutput(self.photoOutput)
                }

                self.session.commitConfiguration()
                if !self.session.isRunning { self.session.startRunning() }

                DispatchQueue.main.async {
                    self.selectedCameraID = device.uniqueID
                    self.state = .ready
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .unavailable("相机连接失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static func discoverVideoDevices() -> [AVCaptureDevice] {
        #if targetEnvironment(macCatalyst)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        #else
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
            .external
        ]
        #endif
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func displayName(for device: AVCaptureDevice) -> String {
        if device.position == .front { return "前置相机 · \(device.localizedName)" }
        if device.position == .back { return "后置相机 · \(device.localizedName)" }
        return "外接相机 · \(device.localizedName)"
    }

    private func activateCCAPICamera() {
        ccapiActivationTask?.cancel()
        stopCCAPIPreview()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        state = .unavailable("正在通过 Wi-Fi 连接佳能 R50 V…")
        ccapiActivationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await self.ccapiClient.connect()
                try Task.checkCancellation()
                try await self.ccapiClient.startLiveView()
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.selectedCameraID == CanonCCAPIClient.cameraID else { return }
                    self.state = .remoteReady(connection.model)
                    self.startCCAPIPreview()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self.selectedCameraID == CanonCCAPIClient.cameraID else { return }
                    self.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private func startCCAPIPreview() {
        guard selectedCameraID == CanonCCAPIClient.cameraID,
              capturedImage == nil,
              !ccapiCaptureInProgress,
              ccapiPreviewTask == nil else { return }
        ccapiPreviewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let image = try await self.ccapiClient.liveViewFrame()
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard self.selectedCameraID == CanonCCAPIClient.cameraID,
                              self.capturedImage == nil else { return }
                        self.latestFrame = image
                    }
                    try await Task.sleep(for: .milliseconds(180))
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(for: .milliseconds(450))
                }
            }
        }
    }

    private func stopCCAPIPreview() {
        ccapiPreviewTask?.cancel()
        ccapiPreviewTask = nil
    }

    private func captureCCAPI(completion: @escaping (Result<UIImage, Error>) -> Void) {
        guard !ccapiCaptureInProgress else {
            completion(.failure(CameraError.captureInProgress))
            return
        }
        ccapiCaptureInProgress = true
        stopCCAPIPreview()
        state = .unavailable("正在曝光并等待相机写卡，长曝光完成后会自动读取…")
        ccapiCaptureTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<UIImage, Error>
            do {
                let image = try await self.ccapiClient.capturePhoto()
                try Task.checkCancellation()
                result = .success(image)
            } catch is CancellationError {
                await MainActor.run {
                    self.ccapiCaptureInProgress = false
                    self.ccapiCaptureTask = nil
                }
                return
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.ccapiCaptureInProgress = false
                self.ccapiCaptureTask = nil
                switch result {
                case .success(let image):
                    self.capturedImage = image
                    self.state = .remoteReady("佳能 EOS R50 V")
                case .failure(let error):
                    self.state = .unavailable("拍摄失败：\(error.localizedDescription)")
                    self.startCCAPIPreview()
                }
                completion(result)
            }
        }
    }

    private func recoverLatestCCAPIPhoto(completion: @escaping (Result<UIImage, Error>) -> Void) {
        guard !ccapiCaptureInProgress else {
            completion(.failure(CameraError.captureInProgress))
            return
        }
        ccapiCaptureInProgress = true
        stopCCAPIPreview()
        state = .unavailable("正在读取佳能相机里的最近照片…")
        Task { [weak self] in
            guard let self else { return }
            let result: Result<UIImage, Error>
            do { result = .success(try await self.ccapiClient.latestPhoto()) }
            catch { result = .failure(error) }
            await MainActor.run {
                self.ccapiCaptureInProgress = false
                switch result {
                case .success(let image):
                    self.capturedImage = image
                    self.state = .remoteReady("佳能 EOS R50 V")
                case .failure(let error):
                    self.state = .unavailable("读取失败：\(error.localizedDescription)")
                    self.startCCAPIPreview()
                }
                completion(result)
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private func activateRemoteCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        state = .remoteReady("佳能 R50 V")
        startRemotePreview()
    }

    private func captureRemote(completion: @escaping (Result<UIImage, Error>) -> Void) {
        remoteQueue.async { [weak self] in
            guard let self else { return }
            self.remoteCaptureInProgress = true
            self.cancelRemotePreviewOnQueue()
            DispatchQueue.main.async {
                self.state = .unavailable("正在触发佳能真快门与闪光灯…")
            }
            let result: Result<UIImage, Error>
            do {
                result = .success(try self.remoteBridge.capturePhoto())
            } catch {
                result = .failure(error)
            }
            self.remoteCaptureInProgress = false
            DispatchQueue.main.async {
                if case .success(let image) = result {
                    self.capturedImage = image
                    self.state = .remoteReady("佳能 R50 V")
                } else if case .failure(let error) = result {
                    self.state = .remoteReady("拍摄失败：\(error.localizedDescription)")
                    self.startRemotePreview()
                }
                completion(result)
            }
        }
    }

    private func startRemotePreview() {
        remoteQueue.async { [weak self] in
            guard let self,
                  self.remotePreviewTimer == nil,
                  !self.remoteCaptureInProgress else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.remoteQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in
                guard let self, !self.remoteCaptureInProgress else { return }
                do {
                    let image = try self.remoteBridge.preview()
                    DispatchQueue.main.async {
                        guard self.selectedCameraID == CanonRemoteBridge.cameraID,
                              self.capturedImage == nil else { return }
                        self.latestFrame = image
                    }
                } catch {
                    // A transient PTP claim during reconnect is expected. The
                    // next timer tick retries without interrupting the booth UI.
                }
            }
            self.remotePreviewTimer = timer
            timer.resume()
        }
    }

    private func stopRemotePreview() {
        remoteQueue.async { [weak self] in self?.cancelRemotePreviewOnQueue() }
    }

    private func cancelRemotePreviewOnQueue() {
        remotePreviewTimer?.setEventHandler {}
        remotePreviewTimer?.cancel()
        remotePreviewTimer = nil
        remoteBridge.stopSession()
    }
    #endif
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<UIImage, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            result = .success(image)
        } else {
            result = .failure(CameraError.invalidPhotoData)
        }

        DispatchQueue.main.async { [weak self] in
            if case .success(let image) = result { self?.capturedImage = image }
            self?.captureCompletion?(result)
            self?.captureCompletion = nil
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(timestamp - lastFrameTime) >= 0.1,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = timestamp
        let input = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 720 / max(input.extent.width, input.extent.height))
        let reduced = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = frameContext.createCGImage(reduced, from: reduced.extent) else { return }
        let frame = UIImage(cgImage: cg)
        DispatchQueue.main.async { [weak self] in self?.latestFrame = frame }
    }
}

private enum CameraError: LocalizedError {
    case notReady
    case cannotAddInput
    case cannotAddOutput
    case invalidPhotoData
    case captureInProgress

    var errorDescription: String? {
        switch self {
        case .notReady: return "相机尚未准备好"
        case .cannotAddInput: return "无法连接所选相机"
        case .cannotAddOutput: return "无法配置照片输出"
        case .invalidPhotoData: return "未能生成照片"
        case .captureInProgress: return "上一张照片仍在读取，请稍候"
        }
    }
}
