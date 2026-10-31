#if !targetEnvironment(macCatalyst)
import UIKit
@preconcurrency import ImageCaptureCore
import ExternalAccessory

/// Observes only the device lists exposed by public frameworks. It never takes
/// ownership of an ICDevice, changes its delegate, or opens a device session.
final class PrinterUSBDiagnosticsController: UIViewController, ICDeviceBrowserDelegate {
    private struct CameraRecord {
        let name: String
        let kind: String
        let transport: String
        let vendorID: Int32
        let productID: Int32
        let capabilities: [String]
    }

    private struct AccessoryRecord {
        let connectionID: Int
        let name: String
        let manufacturer: String
        let model: String
        let protocols: [String]
    }

    private let authorizationBrowser = ICDeviceBrowser()
    private var browser: ICDeviceBrowser?
    private var cameras: [ObjectIdentifier: CameraRecord] = [:]
    private var accessories: [AccessoryRecord] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var accessoryObservers: [NSObjectProtocol] = []
    private var pageVisible = false
    private var monitoring = false
    private var authorizing = false
    private var phase = "等待页面进入前台"
    private var latestReport = ""
    private var lastObservation: Date?
    private var events: [String] = []
    private var scanNumber = 0
    private var scanStartedAt: Date?
    private var scanDeadline: Date?
    private var scanTimer: Timer?

    private let statusLabel = UILabel()
    private let scanTimeLabel = UILabel()
    private let scanSpinner = UIActivityIndicatorView(style: .medium)
    private let devicesLabel = UILabel()
    private let authorizationLabel = UILabel()
    private let authorizationButton = UIButton(type: .system)
    private let reportButton = UIButton(type: .system)
    private let reportView = UITextView()
    private let feedbackLabel = UILabel()
    private lazy var refreshItem = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(refresh))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "USB 连接检测"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = refreshItem
        refreshItem.accessibilityLabel = "重新检测 USB 打印连接"
        configureLayout()
        // A newly opened page always produces a report, even with no accessory.
        updateReport()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pageVisible = true
        observeLifecycle()
        resumeIfActive()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pageVisible = false
        stopMonitoring(reason: "已暂停：检测页离开前台，保留最近一次观察结果")
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
    }

    deinit {
        scanTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        accessoryObservers.forEach(NotificationCenter.default.removeObserver)
        browser?.delegate = nil
        browser?.stop()
        if monitoring { EAAccessoryManager.shared().unregisterForLocalNotifications() }
    }

    private func configureLayout() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])

        let intro = UILabel()
        intro.text = "这是连接检测，不能打印。\n将打印机开机并用 USB 数据线连接 iPad，再点右上角刷新。每次等待 15 秒，结束后会显示结果。未连接打印机时，结果无法判断它能否 USB 直连。"
        intro.font = .preferredFont(forTextStyle: .body)
        intro.numberOfLines = 0
        intro.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(intro)

        for label in [statusLabel, scanTimeLabel, devicesLabel, authorizationLabel, feedbackLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.font = .preferredFont(forTextStyle: .subheadline)
        }
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        scanTimeLabel.textColor = .secondaryLabel
        authorizationLabel.textColor = .secondaryLabel
        feedbackLabel.textColor = .secondaryLabel
        let scanStatus = UIStackView(arrangedSubviews: [scanSpinner, statusLabel])
        scanStatus.alignment = .center
        scanStatus.spacing = 10
        scanSpinner.hidesWhenStopped = true
        stack.addArrangedSubview(scanStatus)
        stack.addArrangedSubview(scanTimeLabel)
        stack.addArrangedSubview(devicesLabel)
        stack.addArrangedSubview(authorizationLabel)
        authorizationButton.addTarget(self, action: #selector(requestAuthorization), for: .touchUpInside)
        stack.addArrangedSubview(authorizationButton)

        let caveat = UILabel()
        caveat.text = "发现设备不代表已能打印；没有发现，也不能据此认定 iPad 没有连接到它。"
        caveat.font = .preferredFont(forTextStyle: .footnote)
        caveat.textColor = .secondaryLabel
        caveat.numberOfLines = 0
        caveat.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(caveat)

        let copy = UIButton(type: .system)
        copy.setTitle("复制报告", for: .normal)
        copy.addTarget(self, action: #selector(copyReport), for: .touchUpInside)
        let share = UIButton(type: .system)
        share.setTitle("分享报告", for: .normal)
        share.addTarget(self, action: #selector(shareReport(_:)), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [copy, share])
        actions.distribution = .fillEqually
        actions.spacing = 16
        stack.addArrangedSubview(actions)
        reportButton.setTitle("查看检测报告", for: .normal)
        reportButton.addTarget(self, action: #selector(toggleReport), for: .touchUpInside)
        stack.addArrangedSubview(reportButton)
        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        reportView.backgroundColor = .secondarySystemGroupedBackground
        reportView.layer.cornerRadius = 12
        reportView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        reportView.heightAnchor.constraint(equalToConstant: 380).isActive = true
        reportView.isHidden = true
        stack.addArrangedSubview(reportView)
        stack.addArrangedSubview(feedbackLabel)
    }

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        for event in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] notification in
                guard let self, let scene = notification.object as? UIWindowScene,
                      scene === self.view.window?.windowScene else { return }
                if notification.name == UIScene.didActivateNotification {
                    self.resumeIfActive()
                } else {
                    self.stopMonitoring(reason: "已暂停：页面不在活动前台，保留最近一次观察结果")
                }
            })
        }
    }

    private func resumeIfActive() {
        guard pageVisible, view.window?.windowScene?.activationState == .foregroundActive,
              !monitoring else { return }
        monitoring = true
        cameras.removeAll()
        accessories.removeAll()
        phase = "正在观察设备连接"
        scanNumber += 1
        scanStartedAt = Date()
        scanDeadline = Date().addingTimeInterval(15)
        recordEvent("第 \(scanNumber) 次检测开始：等待系统设备列表，观察 15 秒")
        let currentBrowser = ICDeviceBrowser()
        currentBrowser.browsedDeviceTypeMask = .camera
        currentBrowser.delegate = self
        browser = currentBrowser

        let center = NotificationCenter.default
        for event in [NSNotification.Name.EAAccessoryDidConnect, NSNotification.Name.EAAccessoryDidDisconnect] {
            accessoryObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.monitoring else { return }
                self.readAccessories()
                self.updateReport()
            })
        }
        EAAccessoryManager.shared().registerForLocalNotifications()
        readAccessories(snapshot: true)
        updateReport()
        // Browsing is attempted without requesting camera control or opening a
        // session. Authorization is an explicit, separately explained action.
        currentBrowser.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickScan()
        }
        scanTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMonitoring(reason: String) {
        scanTimer?.invalidate()
        scanTimer = nil
        scanDeadline = nil
        guard monitoring else { return }
        monitoring = false
        let oldBrowser = browser
        browser = nil
        oldBrowser?.delegate = nil
        oldBrowser?.stop()
        accessoryObservers.forEach(NotificationCenter.default.removeObserver)
        accessoryObservers.removeAll()
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        phase = reason
        recordEvent(reason)
        updateReport(observed: false)
    }

    private func tickScan() {
        guard monitoring, let deadline = scanDeadline else { return }
        guard Date() >= deadline else {
            updateScanStatus()
            return
        }
        scanTimer?.invalidate()
        scanTimer = nil
        scanDeadline = nil
        // Only the initial observation window ends. Keep listening for plug /
        // unplug events so a newly attached device can still appear.
        phase = "本轮 15 秒观察结束，继续监听设备插拔"
        recordEvent("第 \(scanNumber) 次检测等待结束：相机设备 \(cameras.count)，配件 \(accessories.count)")
        updateReport()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    private func updateScanStatus() {
        refreshItem.isEnabled = monitoring && scanDeadline == nil && !authorizing
        if let startedAt = scanStartedAt {
            let time = DateFormatter.localizedString(from: startedAt, dateStyle: .none, timeStyle: .medium)
            scanTimeLabel.text = "本轮开始：\(time) · 相机设备 \(cameras.count) · 配件 \(accessories.count)"
        } else {
            scanTimeLabel.text = "尚未开始检测"
        }
        guard monitoring else {
            scanSpinner.stopAnimating()
            statusLabel.text = "检测已暂停"
            return
        }
        if let deadline = scanDeadline {
            scanSpinner.startAnimating()
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            statusLabel.text = "第 \(scanNumber) 次检测 · 剩余 \(remaining) 秒"
        } else {
            scanSpinner.stopAnimating()
            let count = cameras.count + accessories.count
            statusLabel.text = count == 0
                ? "第 \(scanNumber) 次检测 · 暂未发现设备"
                : "第 \(scanNumber) 次检测 · 发现 \(count) 个设备"
        }
    }

    private func readAccessories(snapshot: Bool = false) {
        let previous = accessories
        let current = EAAccessoryManager.shared().connectedAccessories.filter(\.isConnected).map {
            AccessoryRecord(connectionID: $0.connectionID, name: clean($0.name), manufacturer: clean($0.manufacturer),
                            model: clean($0.modelNumber), protocols: $0.protocolStrings.map(clean).sorted())
        }.sorted { $0.name < $1.name }
        for record in current where snapshot || !previous.contains(where: { $0.connectionID == record.connectionID }) {
            recordEvent("EA \(snapshot ? "当前可见" : "连接")：\(accessoryDescription(record))")
        }
        for record in previous where !current.contains(where: { $0.connectionID == record.connectionID }) {
            recordEvent("EA 移除：\(accessoryDescription(record))")
        }
        accessories = current
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard monitoring, browser === self.browser else { return }
        record(device, event: "IC 发现")
        updateReport()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard monitoring, browser === self.browser else { return }
        if let previous = cameras.removeValue(forKey: ObjectIdentifier(device)) {
            recordEvent("IC 移除：\(cameraDescription(previous))")
        }
        updateReport()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        guard monitoring, browser === self.browser else { return }
        record(device, event: "IC 名称更新")
        updateReport()
    }

    private func record(_ device: ICDevice, event: String) {
        let record = CameraRecord(
            name: clean(device.name), kind: clean(device.productKind), transport: clean(device.transportType),
            vendorID: device.usbVendorID, productID: device.usbProductID, capabilities: device.capabilities.map(clean).sorted()
        )
        cameras[ObjectIdentifier(device)] = record
        recordEvent("\(event)：\(cameraDescription(record))")
    }

    private func recordEvent(_ message: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date()))  \(message)")
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }

    private func cameraDescription(_ record: CameraRecord) -> String {
        "\(record.name)；类型=\(record.kind)；transport=\(record.transport)；VID=\(usbID(record.vendorID))；PID=\(usbID(record.productID))；capabilities=\(record.capabilities.joined(separator: ", "))"
    }

    private func accessoryDescription(_ record: AccessoryRecord) -> String {
        "\(record.name)；厂商=\(record.manufacturer)；型号=\(record.model)；protocolStrings=\(record.protocols.isEmpty ? "空（可能未完成认证）" : record.protocols.joined(separator: ", "))；传输类型未知"
    }

    @objc private func refresh() {
        guard scanDeadline == nil else { return }
        restartMonitoring()
    }

    private func restartMonitoring() {
        stopMonitoring(reason: "正在刷新")
        resumeIfActive()
    }

    @objc private func requestAuthorization() {
        let status = authorizationBrowser.contentsAuthorizationStatus
        if status == .denied || status == .restricted {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
            return
        }
        guard status == .notDetermined, !authorizing else { return }
        authorizing = true
        updateReport(observed: false)
        authorizationBrowser.requestContentsAuthorization { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizing = false
                self.updateReport(observed: false)
                if self.pageVisible { self.restartMonitoring() }
            }
        }
    }

    private func updateReport(observed: Bool = true) {
        if observed { lastObservation = Date() }
        let contents = authorizationBrowser.contentsAuthorizationStatus
        let control = authorizationBrowser.controlAuthorizationStatus
        updateScanStatus()
        let names = cameras.values.map(\.name).sorted() + accessories.map(\.name)
        if !names.isEmpty {
            devicesLabel.text = names.joined(separator: "\n")
        } else if scanDeadline != nil {
            devicesLabel.text = "正在等待系统返回设备，请稍候，无需重复刷新。"
        } else {
            let next = monitoring ? "页面会继续监听插拔。" : "返回检测页前台后会重新检测。"
            devicesLabel.text = "这两个系统接口暂未返回设备。若打印机已开机并连接，说明本轮未能通过这些接口识别它。\(next)"
        }
        authorizationLabel.text = contents == .authorized
            ? "系统相机内容访问已允许；本次检测仅查看设备列表。"
            : "系统相机内容访问：\(authorizationText(contents))。可授权后再检测；当前检测不读取照片。"
        authorizationButton.isHidden = contents == .authorized
        authorizationButton.isEnabled = !authorizing
        authorizationButton.setTitle(contents == .notDetermined ? "允许系统相机内容访问" : "打开权限设置", for: .normal)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let observedAt = lastObservation.map { ISO8601DateFormatter().string(from: $0) } ?? "尚无"
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "SnapBooth USB 连接检测报告", "报告时间：\(timestamp)", "最近观察时间：\(observedAt)",
            "App：\(info["CFBundleShortVersionString"] as? String ?? "未知") (\(info["CFBundleVersion"] as? String ?? "未知"))",
            "系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "状态：\(phase)", "检测轮次：\(scanNumber)",
            "本轮开始：\(scanStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "尚无")",
            "观察窗口：\(scanDeadline == nil ? "未在等待" : "等待系统枚举中，最长 15 秒")", "", "检测范围与限制：",
            "仅枚举 ImageCaptureCore 的相机设备和 ExternalAccessory 当前可见配件；不是全量 USB 总线扫描。",
            "本页不打开设备会话、不主动发送 PTP 或打印控制命令、不直接读写 USB 端点，不读取照片或设备序列号。",
            "系统框架可能为了枚举或认证与设备通信；本页不是 USB 抓包工具。",
            "未连接打印机时，本报告不能判断打印机是否可用。未枚举到设备不证明 USB 硬件不可见。",
            "枚举到设备、匹配 VID/PID 或获得 protocolStrings 均不代表已能传图或打印。",
            "ExternalAccessory 可包含蓝牙配件；其公开属性不提供 USB VID/PID 或可靠的连接传输类型。",
            "EA 协议列表为空可能是认证未完成或接口可见性限制，不能据此认定配件不支持协议。",
            "本检测使用独立浏览器，未设置任何 ICDevice.delegate，也不打开或关闭佳能设备会话。",
            "", "授权：", "相机内容访问：\(authorizationText(contents))",
            "相机控制：\(authorizationText(control))（本页不请求控制授权）",
            "内容授权请求进行中：\(authorizing ? "是" : "否")", "", "ImageCaptureCore：\(cameras.count) 个"
        ]
        for (index, device) in cameras.values.sorted(by: { $0.name < $1.name }).enumerated() {
            lines += ["[\(index + 1)] 名称：\(device.name)", "  类型：\(device.kind)",
                      "  transportType：\(device.transport)", "  USB VID：\(usbID(device.vendorID))",
                      "  USB PID：\(usbID(device.productID))",
                      "  capabilities：\(device.capabilities.isEmpty ? "空（未报告能力）" : device.capabilities.joined(separator: ", "))"]
            if device.vendorID == 0x302c && device.productID == 0x3008 {
                lines.append("  与现有 Mac 后端的 VID/PID 相同；仍需验证协议，当前未执行打印。")
            }
        }
        lines += ["", "ExternalAccessory：\(accessories.count) 个"]
        for (index, accessory) in accessories.enumerated() {
            lines += ["[\(index + 1)] 名称：\(accessory.name)", "  厂商：\(accessory.manufacturer)",
                      "  型号：\(accessory.model)", "  transport / USB VID / PID：此接口未提供，不能推断为 USB",
                      "  protocolStrings：\(accessory.protocols.isEmpty ? "空（可能未完成认证，不能判定无协议）" : accessory.protocols.joined(separator: ", "))"]
        }
        lines += ["", "本次检测页最近 30 条事件（刷新、后台暂停及设备移除后保留）："]
        lines += events.isEmpty ? ["尚无事件"] : events
        lines += ["", "请记录打印机是否已开机、所用数据线/扩展坞，以及连接前后的报告差异。",
                  "最新报告保存位置：App 文稿 / PrinterUSBDiagnostics.txt"]
        latestReport = lines.joined(separator: "\n") + "\n"
        reportView.text = latestReport
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try latestReport.write(to: documents.appendingPathComponent("PrinterUSBDiagnostics.txt"), atomically: true, encoding: .utf8)
            feedbackLabel.text = "最新报告已保存在 App 文稿中。"
        } catch {
            feedbackLabel.text = "报告未能保存，可复制或分享：\(error.localizedDescription)"
        }
    }

    private func authorizationText(_ status: ICAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .notDetermined: return "尚未询问"
        default: return "未知（\(status.rawValue)）"
        }
    }

    private func usbID(_ value: Int32) -> String {
        value > 0 ? String(format: "0x%04X", UInt32(value)) : "未报告（\(value)）"
    }

    private func clean(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "未报告" }
        return String(text.components(separatedBy: .newlines).joined(separator: " ").prefix(512))
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func copyReport() {
        UIPasteboard.general.string = latestReport
        feedbackLabel.text = "检测报告已复制。"
    }

    @objc private func shareReport(_ sender: UIButton) {
        let sheet = UIActivityViewController(activityItems: [latestReport], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = sender
        sheet.popoverPresentationController?.sourceRect = sender.bounds
        present(sheet, animated: true)
    }

    @objc private func toggleReport() {
        reportView.isHidden.toggle()
        reportButton.setTitle(reportView.isHidden ? "查看检测报告" : "收起检测报告", for: .normal)
    }
}
#endif
