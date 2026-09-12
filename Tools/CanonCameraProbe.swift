import Foundation
import ImageCaptureCore

final class CanonCameraProbe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var foundCamera = false
    private var camera: ICCameraDevice?

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
    }

    func start() {
        browser.start()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        foundCamera = true
        self.camera = camera
        print("name=\(camera.name ?? "Unknown")")
        print("transport=\(camera.transportType ?? "Unknown")")
        printCapabilities(camera, stage: "discovered")
        camera.delegate = self
        camera.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        print("sessionOpenError=\(error?.localizedDescription ?? "none")")
        guard let camera = device as? ICCameraDevice else { return }
        printCapabilities(camera, stage: "session-open")
        guard error == nil else { return }
        camera.requestSendPTPCommand(Self.ptpCommand(code: 0x1001, transactionID: 1), outData: nil) {
            commandData, responseData, commandError in
            print("getDeviceInfoError=\(commandError?.localizedDescription ?? "none")")
            print("getDeviceInfoData=\(commandData.map { String(format: "%02x", $0) }.joined())")
            print("getDeviceInfoResponse=\(responseData.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        printCapabilities(camera, stage: "ready")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        printCapabilities(device, stage: "catalog-ready")
        device.requestCloseSession()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        print("sessionCloseError=\(error?.localizedDescription ?? "none")")
    }

    func didRemove(_ device: ICDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        printCapabilities(camera, stage: "capability-changed")
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    private func printCapabilities(_ camera: ICCameraDevice, stage: String) {
        print("stage=\(stage)")
        print("tetheredCaptureEnabled=\(camera.tetheredCaptureEnabled)")
        print("capabilities=\(camera.capabilities)")
    }

    private static func ptpCommand(code: UInt16, transactionID: UInt32) -> Data {
        var bytes = Data()
        var length = UInt32(12).littleEndian
        var type = UInt16(1).littleEndian
        var operation = code.littleEndian
        var transaction = transactionID.littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &type) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &operation) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &transaction) { bytes.append(contentsOf: $0) }
        return bytes
    }
}

let probe = CanonCameraProbe()
probe.start()
RunLoop.current.run(until: Date().addingTimeInterval(20))
if !probe.foundCamera {
    fputs("No ImageCaptureCore camera found\n", stderr)
    exit(2)
}
