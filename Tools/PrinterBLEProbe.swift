import Foundation
import CoreBluetooth
import Darwin

// Read-only discovery: no characteristic reads, writes, subscriptions or
// application pairing/authentication operations are performed by this tool.
private final class PrinterBLEProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let inspectName: String?
    private var central: CBCentralManager!
    private var scanStarted = false
    private var done = false
    private var scanTimer: DispatchWorkItem?
    private var inspectionTimer: DispatchWorkItem?
    private var emitted = Set<UUID>()
    private var emittedMetadata: [UUID: Data] = [:]
    private var matches: [UUID: CBPeripheral] = [:]
    private var currentNames: [UUID: String] = [:]
    private var selected: CBPeripheral?
    private var pendingCharacteristics = Set<ObjectIdentifier>()
    private var pendingDescriptors = Set<ObjectIdentifier>()
    private var serviceDiscoveryFinished = false
    private var inspectionFailed = false

    init(inspectName: String?) {
        self.inspectName = inspectName
        super.init()
    }

    func start() {
        emit("authorization", ["state": authorizationName(CBCentralManager.authorization)])
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit("bluetooth", ["state": stateName(central.state),
                           "authorization": authorizationName(CBCentralManager.authorization)])
        switch central.state {
        case .poweredOn:
            guard !scanStarted else { return }
            scanStarted = true
            emit("scan_started", ["seconds": 15, "mode": inspectName == nil ? "scan" : "inspect"])
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            let work = DispatchWorkItem { [weak self] in self?.scanFinished() }
            scanTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        case .unauthorized:
            finish(3, "蓝牙权限未获准；请在系统设置的隐私与安全性 → 蓝牙中允许此工具后重试。")
        case .unsupported:
            finish(4, "当前 Mac 不支持 CoreBluetooth BLE。")
        case .poweredOff:
            finish(5, "Mac 蓝牙已关闭；请先打开蓝牙。")
        case .resetting:
            if scanStarted { finish(6, "蓝牙服务正在重置；本次检测已停止。") }
        case .unknown: break
        @unknown default: finish(6, "无法识别当前蓝牙状态。")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !done else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        if let inspectName, name != inspectName {
            // A targeted inspection must not disclose unrelated FE95 devices.
            matches.removeValue(forKey: peripheral.identifier)
            currentNames[peripheral.identifier] = name
            return
        }
        var services = Set<CBUUID>()
        for key in [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey,
                    CBAdvertisementDataSolicitedServiceUUIDsKey] {
            (advertisementData[key] as? [CBUUID] ?? []).forEach { services.insert($0) }
        }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        serviceData.keys.forEach { services.insert($0) }
        let keywords = ["mijia", "mi photo", "print", "照片", "hannto", "liene"]
        let candidate = inspectName != nil || keywords.contains(where: name.lowercased().contains)
            || services.contains(CBUUID(string: "FF00"))
        guard candidate else { return }
        currentNames[peripheral.identifier] = name
        // Keep identity only internally to avoid treating duplicate advertisements
        // as separate devices. No peripheral identifiers or raw payloads are output.
        if let inspectName {
            if name == inspectName { matches[peripheral.identifier] = peripheral }
            else { matches.removeValue(forKey: peripheral.identifier) }
        }
        emitted.insert(peripheral.identifier)
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var fields: [String: Any] = [
            "name": name.isEmpty ? "（未广播名称）" : name,
            "serviceUUIDs": services.map(\.uuidString).sorted(),
            "manufacturerDataLength": manufacturer?.count ?? 0
        ]
        if let manufacturer, manufacturer.count >= 2 {
            let octets = Array(manufacturer.prefix(2))
            fields["manufacturerID"] = String(format: "0x%04X", UInt16(octets[0]) | UInt16(octets[1]) << 8)
        } else { fields["manufacturerID"] = NSNull() }
        // NSNumber? must be represented as JSON null when absent.
        fields["isConnectable"] = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)
            .map { $0.boolValue as Any } ?? NSNull()
        // CoreBluetooth serviceData excludes its 16-bit service UUID. MiBeacon
        // starts with little-endian frame control and product ID, followed by a
        // counter. Parse only those four public header bytes; never output the
        // counter, optional MAC/DID, payload, or the complete advertisement.
        if inspectName != nil, let beacon = serviceData[CBUUID(string: "FE95")], beacon.count >= 5 {
            let header = Array(beacon.prefix(4))
            let frameControl = UInt16(header[0]) | UInt16(header[1]) << 8
            let productID = UInt16(header[2]) | UInt16(header[3]) << 8
            fields["miBeaconFrameControl"] = String(format: "0x%04X", frameControl)
            fields["miBeaconProductID"] = Int(productID)
        }
        // Scan responses can add serviceData after the first advertisement;
        // print a fresh candidate only when permitted metadata actually changes.
        if let metadata = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            guard emittedMetadata[peripheral.identifier] != metadata else { return }
            emittedMetadata[peripheral.identifier] = metadata
        }
        emit("candidate", fields)
    }

    private func scanFinished() {
        guard !done else { return }
        central.stopScan()
        emit("scan_finished", ["candidateCount": emitted.count])
        guard let inspectName else { finish(0, "扫描完成；没有连接任何设备。"); return }
        guard matches.count == 1, let peripheral = matches.values.first else {
            finish(7, matches.isEmpty
                   ? "没有找到名称完全匹配的候选设备；未发起连接。"
                   : "发现多台同名候选设备，无法确定单一目标；未发起连接。")
            return
        }
        guard currentNames[peripheral.identifier] == inspectName else {
            finish(7, "目标名称在扫描期间发生变化；未发起连接。")
            return
        }
        selected = peripheral
        peripheral.delegate = self
        emit("inspection_started", ["name": inspectName, "seconds": 15])
        let work = DispatchWorkItem { [weak self] in
            self?.finish(8, "连接或服务枚举超过 15 秒，已停止并断开连接。")
        }
        inspectionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === selected, !done else { return }
        emit("connected", ["name": inspectName ?? ""])
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected else { return }
        reportOperationError("connect", error)
        finish(9, "未能连接目标设备。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === selected, !done else { return }
        reportOperationError("disconnect", error)
        finish(9, "服务枚举完成前连接已断开。")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === selected, !done else { return }
        guard error == nil else {
            reportOperationError("services", error)
            finish(10, "无法枚举目标服务。")
            return
        }
        let services = peripheral.services ?? []
        for service in services {
            emit("service", ["uuid": service.uuid.uuidString, "isPrimary": service.isPrimary])
            pendingCharacteristics.insert(ObjectIdentifier(service))
        }
        serviceDiscoveryFinished = true
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        finishIfEnumerated()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === selected, !done else { return }
        pendingCharacteristics.remove(ObjectIdentifier(service))
        if let error {
            inspectionFailed = true
            reportOperationError("characteristics", error)
        } else {
            for characteristic in service.characteristics ?? [] {
                emit("characteristic", ["serviceUUID": service.uuid.uuidString,
                                        "uuid": characteristic.uuid.uuidString,
                                        "properties": propertyNames(characteristic.properties)])
                pendingDescriptors.insert(ObjectIdentifier(characteristic))
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
        finishIfEnumerated()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === selected, !done else { return }
        pendingDescriptors.remove(ObjectIdentifier(characteristic))
        if let error {
            inspectionFailed = true
            reportOperationError("descriptors", error)
        } else {
            for descriptor in characteristic.descriptors ?? [] {
                emit("descriptor", ["serviceUUID": characteristic.service?.uuid.uuidString ?? "",
                                    "characteristicUUID": characteristic.uuid.uuidString,
                                    "uuid": descriptor.uuid.uuidString])
            }
        }
        finishIfEnumerated()
    }

    private func finishIfEnumerated() {
        if serviceDiscoveryFinished && pendingCharacteristics.isEmpty && pendingDescriptors.isEmpty {
            finish(inspectionFailed ? 10 : 0, inspectionFailed
                   ? "枚举结束，部分元数据无法读取；未读写特征值。"
                   : "服务、特征和描述符 UUID 枚举完成；未读写特征值。")
        }
    }

    private func reportOperationError(_ operation: String, _ error: Error?) {
        let nsError = error as NSError?
        // Do not print error descriptions/userInfo: they may embed device IDs.
        emit("operation_error", ["operation": operation,
                                 "code": nsError?.code as Any? ?? NSNull()])
    }

    private func finish(_ code: Int32, _ message: String) {
        guard !done else { return }
        done = true
        scanTimer?.cancel()
        inspectionTimer?.cancel()
        central?.stopScan()
        if let selected { central?.cancelPeripheralConnection(selected) }
        emit("finished", ["exitCode": code, "message": message])
        fflush(stdout)
        exit(code)
    }

    private func emit(_ event: String, _ fields: [String: Any]) {
        var value = fields
        value["event"] = event
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return }
        print(string)
        fflush(stdout)
    }

    private func authorizationName(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "unknown"
        }
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "futureState"
        }
    }

    private func propertyNames(_ value: CBCharacteristicProperties) -> [String] {
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ]
        return names.compactMap { value.contains($0.0) ? $0.1 : nil }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let targetName: String?
if arguments.isEmpty { targetName = nil }
else if arguments.count == 2, arguments[0] == "--inspect-name", !arguments[1].isEmpty {
    targetName = arguments[1]
} else {
    fputs("Usage: PrinterBLEProbe [--inspect-name 'exact advertised name']\n", stderr)
    exit(2)
}
private let probe = PrinterBLEProbe(inspectName: targetName)
probe.start()
RunLoop.main.run()
