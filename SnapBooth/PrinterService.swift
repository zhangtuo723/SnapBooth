import SwiftUI
import UIKit
import ImageIO
import OSLog

final class PrinterService: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case xiaomiUSB = "米家 USB"
        case mijiaShare = "米家 App"
        case mock = "模拟打印"
        case airPrint = "AirPrint"

        var id: String { rawValue }

        static var available: [Mode] {
            #if targetEnvironment(macCatalyst)
            return [.xiaomiUSB, .mock, .airPrint]
            #else
            return [.mijiaShare, .airPrint, .mock]
            #endif
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case ready
        case printing
        case success(String)
        case failed(String)

        var description: String {
            switch self {
            case .idle: return "尚未选择打印机"
            case .checking: return "正在检查打印机"
            case .ready: return "打印机在线"
            case .printing: return "正在发送打印任务"
            case .success(let message): return message
            case .failed(let message): return message
            }
        }
    }

    @Published var mode: Mode {
        didSet { updateStateForMode() }
    }
    @Published private(set) var selectedPrinter: UIPrinter?
    @Published private(set) var state: State = .ready
    @Published private(set) var lastMockPrintURL: URL?
    private var picker: UIPrinterPickerController?
    private var shareLifecycleObservers: [NSObjectProtocol] = []

    init() {
        if MijiaShareDiagnostics.enabled {
            for event in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
                shareLifecycleObservers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { _ in
                    MijiaShareDiagnostics.record("lifecycle=\(event.rawValue)")
                })
            }
        }
        #if targetEnvironment(macCatalyst)
        mode = .xiaomiUSB
        state = .checking
        DispatchQueue.main.async { [weak self] in self?.checkPrinter() }
        #else
        mode = .mijiaShare
        state = .success("点击“用米家打印”分享当前成片，再在米家中确认相纸与打印")
        #endif
    }

    deinit {
        shareLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func choosePrinter() {
        #if targetEnvironment(macCatalyst)
        state = .success("点击打印照片，在系统窗口中选择打印机")
        return
        #else
        let picker = UIPrinterPickerController(initiallySelectedPrinter: selectedPrinter)
        self.picker = picker
        picker.present(animated: true) { [weak self] controller, completed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.picker = nil
                if let error {
                    self.state = .failed(error.localizedDescription)
                } else if completed, let printer = controller.selectedPrinter {
                    self.selectedPrinter = printer
                    self.checkPrinter()
                }
            }
        }
        #endif
    }

    func checkPrinter() {
        if mode == .xiaomiUSB {
            checkXiaomiUSBPrinter()
            return
        }
        #if targetEnvironment(macCatalyst)
        state = mode == .mock ? .ready : .success("打印时在系统窗口选择打印机")
        return
        #else
        guard mode == .airPrint else {
            state = .ready
            return
        }
        guard let selectedPrinter else {
            state = .idle
            return
        }
        state = .checking
        selectedPrinter.contactPrinter { [weak self] available in
            DispatchQueue.main.async {
                self?.state = available ? .ready : .failed("打印机当前不可用")
            }
        }
        #endif
    }

    func print(image: UIImage, presenting presenter: UIViewController? = nil, sourceView: UIView? = nil) {
        guard state != .printing else { return }
        switch mode {
        case .xiaomiUSB:
            xiaomiUSBPrint(image: image)
        case .mijiaShare:
            shareToMijia(image: image, presenter: presenter, sourceView: sourceView)
        case .mock:
            mockPrint(image: image)
        case .airPrint:
            airPrint(image: image)
        }
    }

    /// Only hands an edited JPEG to a user-selected share extension. A completed
    /// share is not evidence that the printer accepted or printed the photo.
    private func shareToMijia(image: UIImage, presenter: UIViewController?, sourceView: UIView?) {
        let diagnosticID = String(UUID().uuidString.prefix(8))
        MijiaShareDiagnostics.record("share=\(diagnosticID) prepare image=\(Int(image.size.width))x\(Int(image.size.height))")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var host = presenter ?? scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = host?.presentedViewController { host = presented }
        guard let host, host.viewIfLoaded?.window != nil, !host.isBeingDismissed else {
            state = .failed("无法打开分享面板，请返回照片编辑页重试")
            return
        }
        state = .printing
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak host, weak sourceView] in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnapBooth-\(UUID().uuidString).jpg")
            do {
                guard let data = image.jpegData(compressionQuality: 0.95) else {
                    throw PrinterError.encodingFailed
                }
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    guard let self, let host, host.viewIfLoaded?.window != nil,
                          host.presentedViewController == nil else {
                        try? FileManager.default.removeItem(at: url)
                        self?.state = .failed("分享窗口已关闭，请重试")
                        return
                    }
                    let source = MijiaPhotoShareItem(url: url, diagnosticID: diagnosticID)
                    let sheet = UIActivityViewController(activityItems: [source], applicationActivities: nil)
                    sheet.excludedActivityTypes = [.print]
                    let anchor = sourceView ?? host.view!
                    sheet.popoverPresentationController?.sourceView = anchor
                    sheet.popoverPresentationController?.sourceRect = sourceView == nil
                        ? CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
                        : anchor.bounds
                    sheet.completionWithItemsHandler = { [weak self] activity, completed, returnedItems, error in
                        let failure = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "none"
                        MijiaShareDiagnostics.record("share=\(diagnosticID) completion activity=\(activity?.rawValue ?? "none") completed=\(completed) returnedCount=\(returnedItems?.count ?? 0) error=\(failure)")
                        try? FileManager.default.removeItem(at: url)
                        DispatchQueue.main.async {
                            if let error {
                                self?.state = .failed("照片分享失败：\(error.localizedDescription)")
                            } else {
                                self?.state = .success(completed
                                    ? "照片分享已完成；是否打印成功请在米家中查看"
                                    : "已取消分享，当前照片仍保留")
                            }
                        }
                    }
                    host.present(sheet, animated: true) {
                        MijiaShareDiagnostics.record("share=\(diagnosticID) sheet-presented")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self?.state = .failed("准备分享照片失败：\(error.localizedDescription)") }
            }
        }
    }

    private func mockPrint(image: UIImage) {
        state = .printing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let documents = try FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let folder = documents.appendingPathComponent("MockPrints", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = folder.appendingPathComponent("SnapBooth-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).jpg")
                let data = NSMutableData()
                guard let cgImage = image.cgImage,
                      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
                    throw PrinterError.encodingFailed
                }
                CGImageDestinationAddImage(destination, cgImage, [
                    kCGImageDestinationLossyCompressionQuality: 0.94,
                    kCGImagePropertyDPIWidth: 300,
                    kCGImagePropertyDPIHeight: 300
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw PrinterError.encodingFailed }
                try (data as Data).write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self?.lastMockPrintURL = url
                    self?.state = .success("模拟打印完成")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .failed("模拟打印失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func checkXiaomiUSBPrinter() {
        #if targetEnvironment(macCatalyst)
        guard state != .printing else { return }
        state = .checking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let status = try MijiaUSBBridge.status()
                DispatchQueue.main.async {
                    self?.state = status.isReady
                        ? .success("米家桌面照片打印机 2 · USB 在线 · 固件 \(status.firmware) · 无告警")
                        : .failed("打印机告警 \(status.alert)，请检查相纸、色带和舱门")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .failed("米家 USB 未就绪：\(error.localizedDescription)")
                }
            }
        }
        #else
        state = .failed("米家 USB 直连当前仅在 Mac 版可用")
        #endif
    }

    private func xiaomiUSBPrint(image: UIImage) {
        #if targetEnvironment(macCatalyst)
        state = .printing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SnapBooth-Mijia-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let data = try Self.mijiaJPEGData(image: image)
                try data.write(to: url, options: .atomic)
                let jobID = try MijiaUSBBridge.printSixInchJPEG(at: url)
                DispatchQueue.main.async {
                    self?.state = .success("米家打印完成 · 任务 #\(jobID)")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.state = .failed("米家 USB 打印失败：\(error.localizedDescription)")
                }
            }
        }
        #else
        state = .failed("米家 USB 直连当前仅在 Mac 版可用")
        #endif
    }

    private static func mijiaJPEGData(image: UIImage) throws -> Data {
        guard let cgImage = image.cgImage else { throw PrinterError.encodingFailed }
        for quality in [0.92, 0.86, 0.78, 0.70, 0.60] as [CGFloat] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
                throw PrinterError.encodingFailed
            }
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: 300,
                kCGImagePropertyDPIHeight: 300
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PrinterError.encodingFailed }
            if data.length < 1_000_000 { return data as Data }
        }
        throw PrinterError.encodingFailed
    }

    private func airPrint(image: UIImage) {
        #if !targetEnvironment(macCatalyst)
        guard let selectedPrinter else {
            state = .failed("请先选择 AirPrint 打印机")
            choosePrinter()
            return
        }
        #endif

        state = .printing
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "SnapBooth Photo"
        info.outputType = .photo
        info.orientation = image.size.width > image.size.height ? .landscape : .portrait
        controller.printInfo = info
        controller.showsPaperSelectionForLoadedPapers = true
        controller.printingItem = image
        let completion: UIPrintInteractionController.CompletionHandler = { [weak self] _, completed, error in
            DispatchQueue.main.async {
                if let error {
                    self?.state = .failed("打印失败：\(error.localizedDescription)")
                } else if completed {
                    self?.state = .success("照片已发送至打印机")
                } else {
                    self?.state = .failed("打印任务已取消")
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let view = scene.windows.first(where: \.isKeyWindow)?.rootViewController?.view else {
            state = .failed("未找到打印窗口，请返回 App 再试")
            return
        }
        if !controller.present(from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), in: view, animated: true, completionHandler: completion) {
            state = .failed("无法打开系统打印窗口")
        }
        #else
        if !controller.print(to: selectedPrinter, completionHandler: completion) {
            state = .failed("无法启动打印任务")
        }
        #endif
    }

    private func updateStateForMode() {
        switch mode {
        case .mijiaShare:
            state = .success("点击“用米家打印”分享当前成片，再在米家中确认相纸与打印")
        case .xiaomiUSB:
            checkXiaomiUSBPrinter()
        case .mock: state = .ready
        case .airPrint:
            #if targetEnvironment(macCatalyst)
            state = .success("打印时在系统窗口选择打印机")
            #else
            state = selectedPrinter == nil ? .idle : .ready
            #endif
        }
    }
}

/// Same JPEG file representation as before; does not inspect returned content,
/// photo bytes, account credentials, or another app's private storage.
private final class MijiaPhotoShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let diagnosticID: String

    init(url: URL, diagnosticID: String) {
        self.url = url
        self.diagnosticID = diagnosticID
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // iPadOS may request an item while evaluating candidates, so this is
        // not by itself proof that the user selected or opened that extension.
        MijiaShareDiagnostics.record("share=\(diagnosticID) item-request activity=\(activityType?.rawValue ?? "none")")
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        "public.jpeg"
    }
}

private enum MijiaShareDiagnostics {
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--mijia-share-diagnostics")
        #else
        return false
        #endif
    }

    static func record(_ message: String) {
        guard enabled else { return }
        Logger(subsystem: "app.snapbooth.ipad", category: "MijiaShare").notice("\(message, privacy: .public)")
        print("[MijiaShare] \(ISO8601DateFormatter().string(from: Date())) \(message)")
    }
}

private enum PrinterError: LocalizedError {
    case encodingFailed

    var errorDescription: String? { "无法编码打印图片" }
}
